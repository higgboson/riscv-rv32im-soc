// matmul_accel.v - memory-mapped INT8 matrix-multiply accelerator (4x4 systolic array)
//
// Computes one 4x4 tile:  C[i][j] = sum over k of A[i][k] * B[k][j],  k = 0 .. K-1
// with INT8 inputs and INT32 results. Bigger matrices are split into 4x4 tiles by software
// (sw/common/accel.h).
//
// How the data moves: at step k, A[0..3][k] enters the left edge (one value per row) and
// B[k][0..3] enters the top edge (one value per column). Row i is delayed by i cycles and
// column j by j cycles ("skew"), so A[i][k] and B[k][j] meet in PE (i, j) in the same
// cycle. A 4x4 tile with K steps takes K + 6 cycles, doing 16 multiply-adds per cycle.
//
// Registers (base 0x2000_0000, word offsets):
//   0x000  CTRL   write: bits 6:0 = K (1..64), bit 8 = start, bit 9 = clear C first,
//                        bit 10 = gather A first, bit 11 = gather B first (see below)
//                 read : bit 0 = busy (gathering or running), bit 1 = Q ready
//   0x010  GA_BASE   gather descriptor for A: start address in data memory
//   0x014  GA_COUNT  bits 7:0 = n0, 15:8 = n1, 23:16 = n2, 26:24 = lanes (1..4)
//   0x018  GA_STRIDE01  bits 15:0 = s0, 31:16 = s1   (byte strides)
//   0x01C  GA_STRIDE2L  bits 15:0 = s2, 31:16 = lane stride
//   0x020 .. 0x02C   the same for B
//   0x100  A_COL[k]  (k = 0..63) one word = A[0..3][k], byte i = row i
//   0x200  B_ROW[k]  (k = 0..63) one word = B[k][0..3], byte j = column j
//   0x300  C[i][j]   (16 words, row by row) read only
//   0x340  Q[i]      (4 words) read only: row i of C converted back to INT8 by the output stage,
//                    byte j = clamp((C[i][j] + BIAS[j]) * MULT[j] + 2^23 >> 24, 0, 127)
//   0x380  BIAS[j]   (4 words) read / write, added to column j
//   0x3C0  MULT[j]   (4 words) read / write, 18-bit unsigned scale of column j
// Without "clear", a run adds onto the old C, so long sums can be
// split into pieces; Q is only meaningful after the last piece.
//
// The output stage does what a neural-network layer needs after the multiply-adds: add the
// bias, scale back to 8 bits, ReLU. It runs in the 6 cycles after busy drops (one row per
// cycle through a 3-stage pipeline), so busy and the K + 6 run length are unchanged.
//
// The gather engine fills the A or B buffer straight from data memory, through its own port
// (the CPU keeps running). Step k of the buffer, for k = 0 .. n0*n1*n2 - 1 counted as
// three nested loops (i0 innermost), gets for lane i = 0 .. lanes-1
//     byte i = mem[base + i2*s2 + i1*s1 + i0*s0 + i*lane_stride]
// and 0 in the other lanes. One byte is read per cycle, or a whole word when the 4 lanes are
// 4 neighbouring bytes on a word boundary. For a 3x3 convolution over a height x width x C
// image this is im2col in hardware: n = (C, 3, 3), s = (1, C, width*C), lane stride = C
// gives the 3x3xC patches of 4 neighbouring pixels. A command can gather A, then B, then
// start the run, all while busy stays high.

module matmul_accel #(parameter MAXK = 64) (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    output reg [31:0] rd_data,
    output     [31:0] mem_addr,               // gather engine -> data memory port B
    input      [31:0] mem_rdata               //   (word one cycle after the address)
);

localparam N  = 4;
localparam KW = $clog2(MAXK);

wire [1:0]    region = addr[9:8];          // 0 = control, 1 = A, 2 = B, 3 = C
wire [KW-1:0] widx   = addr[KW+1:2];

// Operand buffers (small, become LUT RAM on the FPGA)
reg [31:0] a_buf [0:MAXK-1];
reg [31:0] b_buf [0:MAXK-1];

// gather engine write port (declared here, driven further down)
reg           g_we, g_we_b;
reg  [KW-1:0] g_widx;
reg  [31:0]   g_wdata;

always @(posedge clk) begin
    if (g_we && !g_we_b)              a_buf[g_widx] <= g_wdata;
    else if (wr_en && region == 2'd1) a_buf[widx]   <= wr_data;
    if (g_we && g_we_b)               b_buf[g_widx] <= g_wdata;
    else if (wr_en && region == 2'd2) b_buf[widx]   <= wr_data;
end

// Commands. Writing CTRL with start and/or a gather bit is a command; it is ignored while
// the accelerator is busy.
reg         busy;                          // the array is running
reg         g_busy;                        // the gather engine is working
// one-cycle pulse after the gather engine has written its last word (a cycle after the last
// data arrives, so the run never reads a buffer entry that is still being written)
reg         g_done;
reg  [KW:0] k_len;
reg  [7:0]  t;                             // step counter while busy
wire [7:0]  k8   = {{(7-KW){1'b0}}, k_len};  // K widened to the counter's width
wire [7:0]  last = k8 + 8'd5;              // last step, see below

wire ctrl_wr = wr_en && region == 2'd0 && addr[7:2] == 6'd0;
wire cmd     = ctrl_wr && (wr_data[8] || wr_data[10] || wr_data[11]) && !busy && !g_busy && !g_done;
wire cmd_gather = cmd && (wr_data[10] || wr_data[11]);

// a run starts straight from the command, or when the gathering it asked for is done
reg         pend_run, pend_clear;
reg  [KW:0] pend_k;
wire start = (cmd && wr_data[8] && !cmd_gather) || (g_done && pend_run);
wire clear = start && (cmd ? wr_data[9] : pend_clear);

initial busy = 0;

always @(posedge clk) begin
    if (cmd_gather) begin
        pend_run   <= wr_data[8];
        pend_clear <= wr_data[9];
        pend_k     <= wr_data[KW:0];
    end
end

always @(posedge clk) begin
    if (reset) begin
        busy <= 1'b0;
    end else if (start) begin
        busy  <= 1'b1;
        k_len <= cmd ? wr_data[KW:0] : pend_k;
        t     <= 0;
    end else if (busy) begin
        // step K-1 is fed at t = K-1 and needs 3 skew + 3 hop cycles to reach PE (3,3),
        // so its product is added at the end of step K+5 (2 * (N-1) - 1 = 5): the run ends there
        if (t == last)
            busy <= 1'b0;
        t <= t + 1'b1;
    end
end

// Feed: one word of A and one of B per step, zeros once the K steps are done
wire        feeding = busy && (t < k8);
wire [31:0] a_word  = feeding ? a_buf[t[KW-1:0]] : 32'b0;
wire [31:0] b_word  = feeding ? b_buf[t[KW-1:0]] : 32'b0;

// Skew: lane i goes through i registers before entering the array
reg [7:0] a_d1 [1:3], a_d2 [2:3], a_d3;
reg [7:0] b_d1 [1:3], b_d2 [2:3], b_d3;

// start empty, so nothing unknown flows into the sums after power-up
integer n;
initial begin
    for (n = 1; n <= 3; n = n + 1) begin a_d1[n] = 0; b_d1[n] = 0; end
    for (n = 2; n <= 3; n = n + 1) begin a_d2[n] = 0; b_d2[n] = 0; end
    a_d3 = 0; b_d3 = 0;
end

always @(posedge clk) begin
    a_d1[1] <= a_word[15:8];  a_d1[2] <= a_word[23:16]; a_d1[3] <= a_word[31:24];
    a_d2[2] <= a_d1[2];       a_d2[3] <= a_d1[3];
    a_d3    <= a_d2[3];
    b_d1[1] <= b_word[15:8];  b_d1[2] <= b_word[23:16]; b_d1[3] <= b_word[31:24];
    b_d2[2] <= b_d1[2];       b_d2[3] <= b_d1[3];
    b_d3    <= b_d2[3];
end

wire [7:0] a_edge [0:N-1];
wire [7:0] b_edge [0:N-1];
assign a_edge[0] = a_word[7:0];  assign a_edge[1] = a_d1[1];
assign a_edge[2] = a_d2[2];      assign a_edge[3] = a_d3;
assign b_edge[0] = b_word[7:0];  assign b_edge[1] = b_d1[1];
assign b_edge[2] = b_d2[2];      assign b_edge[3] = b_d3;

// The 4x4 grid. a moves right along a row, b moves down a column.
wire [7:0]  a_link [0:N-1][0:N];
wire [7:0]  b_link [0:N][0:N-1];
wire [31:0] acc    [0:N-1][0:N-1];

genvar i, j;
generate
    for (i = 0; i < N; i = i + 1) begin : row
        assign a_link[i][0] = a_edge[i];
        for (j = 0; j < N; j = j + 1) begin : col
            if (i == 0) begin : top
                assign b_link[0][j] = b_edge[j];
            end
            systolic_pe pe (
                .clk(clk), .clear(clear),
                .a_in(a_link[i][j]),   .b_in(b_link[i][j]),
                .a_out(a_link[i][j+1]), .b_out(b_link[i+1][j]),
                .acc(acc[i][j])
            );
        end
    end
endgenerate

// Gather engine
reg  [31:0] gd_base [0:1];                 // descriptors: 0 = A, 1 = B
reg  [7:0]  gd_n0 [0:1], gd_n1 [0:1], gd_n2 [0:1];
reg  [2:0]  gd_lanes [0:1];
reg  [15:0] gd_s0 [0:1], gd_s1 [0:1], gd_s2 [0:1], gd_sl [0:1];

wire       desc_wr = wr_en && region == 2'd0 && (addr[7:4] == 4'h1 || addr[7:4] == 4'h2);
wire       desc_b  = addr[5];              // 0x01x -> A, 0x02x -> B
always @(posedge clk)
    if (desc_wr)
        case (addr[3:2])
            2'd0: gd_base[desc_b] <= wr_data;
            2'd1: begin gd_n0[desc_b] <= wr_data[7:0];  gd_n1[desc_b] <= wr_data[15:8];
                        gd_n2[desc_b] <= wr_data[23:16]; gd_lanes[desc_b] <= wr_data[26:24]; end
            2'd2: begin gd_s0[desc_b] <= wr_data[15:0]; gd_s1[desc_b] <= wr_data[31:16]; end
            default: begin gd_s2[desc_b] <= wr_data[15:0]; gd_sl[desc_b] <= wr_data[31:16]; end
        endcase

reg         g_sel;                         // which buffer is being filled: 0 = A, 1 = B
reg         g_then_b;                      // after A, also gather B
reg         g_issue;                       // still sending addresses
reg  [7:0]  c0, c1, c2;                    // loop counters
reg  [15:0] o0, o1, o2, ol;                // byte offsets of the three loops and of the lane
reg  [2:0]  lane;
reg  [KW:0] g_k;                           // buffer index of the step being read

wire [15:0] step_off  = o0 + o1 + o2;
wire [31:0] step_addr = gd_base[g_sel] + {16'b0, step_off};
wire [31:0] rd_addr   = step_addr + {16'b0, ol};
// 4 neighbouring bytes on a word boundary: one read for the whole step
wire        g_fast    = gd_sl[g_sel] == 16'd1 && gd_lanes[g_sel] == 3'd4 && step_addr[1:0] == 2'b00;
wire        last_lane = g_fast || (lane == gd_lanes[g_sel] - 3'd1);
wire        last_step = (c0 == gd_n0[g_sel] - 8'd1) && (c1 == gd_n1[g_sel] - 8'd1) &&
                        (c2 == gd_n2[g_sel] - 8'd1);
assign mem_addr = rd_addr;

// what is in flight: the word for this request arrives next cycle
reg         p_valid, p_fast, p_first, p_last, p_end;
reg  [1:0]  p_boff, p_lane;
reg  [KW:0] p_k;
reg  [31:0] g_word;                        // step word being assembled

initial begin g_busy = 0; g_issue = 0; p_valid = 0; g_we = 0; end

// next state of the assembled word when a byte (or a whole word) arrives
wire [31:0] in_shift = mem_rdata >> (8 * p_boff);
wire [7:0]  in_byte  = in_shift[7:0];
reg  [31:0] word_next;
always @(*) begin
    word_next = p_first ? 32'b0 : g_word;
    if (p_fast) word_next = mem_rdata;
    else        word_next[8 * p_lane +: 8] = in_byte;
end

initial g_done = 0;

always @(posedge clk) begin
    g_we   <= 1'b0;
    g_done <= 1'b0;
    if (reset) begin
        g_busy <= 1'b0;  g_issue <= 1'b0;  p_valid <= 1'b0;
    end else if (cmd_gather) begin
        g_busy   <= 1'b1;  g_issue <= 1'b1;
        g_sel    <= !wr_data[10];          // start with A unless only B was asked for
        g_then_b <= wr_data[10] && wr_data[11];
        c0 <= 0; c1 <= 0; c2 <= 0; o0 <= 0; o1 <= 0; o2 <= 0; ol <= 0; lane <= 0; g_k <= 0;
        p_valid <= 1'b0;
    end else if (g_busy) begin
        // 1. send the next address
        p_valid <= g_issue;
        if (g_issue) begin
            p_fast  <= g_fast;   p_boff <= rd_addr[1:0];   p_lane <= lane[1:0];
            p_first <= (lane == 3'd0);  p_last <= last_lane;  p_k <= g_k;
            p_end   <= last_lane && last_step;
            if (last_lane) begin
                lane <= 0;  ol <= 0;  g_k <= g_k + 1'b1;
                if (last_step) g_issue <= 1'b0;
                else if (c0 != gd_n0[g_sel] - 8'd1) begin c0 <= c0 + 1'b1; o0 <= o0 + gd_s0[g_sel]; end
                else begin
                    c0 <= 0;  o0 <= 0;
                    if (c1 != gd_n1[g_sel] - 8'd1) begin c1 <= c1 + 1'b1; o1 <= o1 + gd_s1[g_sel]; end
                    else begin c1 <= 0; o1 <= 0; c2 <= c2 + 1'b1; o2 <= o2 + gd_s2[g_sel]; end
                end
            end else begin
                lane <= lane + 1'b1;  ol <= ol + gd_sl[g_sel];
            end
        end
        // 2. take the data that arrived for last cycle's address
        if (p_valid) begin
            g_word <= word_next;
            if (p_last) begin
                g_we <= 1'b1;  g_we_b <= g_sel;  g_widx <= p_k[KW-1:0];  g_wdata <= word_next;
            end
            if (p_end) begin
                if (g_sel == 1'b0 && g_then_b) begin       // A done, now B
                    g_sel <= 1'b1;  g_then_b <= 1'b0;  g_issue <= 1'b1;  p_valid <= 1'b0;
                    c0 <= 0; c1 <= 0; c2 <= 0; o0 <= 0; o1 <= 0; o2 <= 0; ol <= 0; lane <= 0; g_k <= 0;
                end else begin
                    g_busy <= 1'b0;
                    g_done <= 1'b1;
                end
            end
        end
    end
end

// Output stage
wire [1:0] sub  = addr[7:6];                 // inside region 3: 0 C, 1 Q, 2 BIAS, 3 MULT
wire [1:0] sidx = addr[3:2];

reg signed [31:0] bias [0:N-1];
reg        [17:0] mult [0:N-1];
reg        [31:0] q    [0:N-1];
reg               q_ready;
initial begin
    for (n = 0; n < N; n = n + 1) begin bias[n] = 0; mult[n] = 0; q[n] = 0; end
    q_ready = 0;
end

always @(posedge clk)
    if (wr_en && region == 2'd3) begin
        if (sub == 2'd2) bias[sidx] <= wr_data;
        if (sub == 2'd3) mult[sidx] <= wr_data[17:0];
    end

// row counter: starts when a run ends; a new start stops it so a half-finished Q is never
// marked ready
wire       run_done = busy && (t == last);
reg  [2:0] prow;                             // 0..3 = row entering the pipeline, 4 = idle
reg  [1:0] row_s1, row_s2;
reg        v_s1, v_s2;
reg signed [32:0] sum_s1  [0:N-1];
reg signed [51:0] prod_s2 [0:N-1];
initial begin prow = 3'd4; v_s1 = 0; v_s2 = 0; end

always @(posedge clk) begin
    if (reset || start || cmd) begin
        prow <= 3'd4;  v_s1 <= 1'b0;  v_s2 <= 1'b0;  q_ready <= 1'b0;
    end else begin
        if (run_done)            prow <= 3'd0;
        else if (prow != 3'd4)    prow <= prow + 3'd1;
        v_s1 <= (prow != 3'd4);   row_s1 <= prow[1:0];
        v_s2 <= v_s1;            row_s2 <= row_s1;
        if (v_s2 && row_s2 == 2'd3) q_ready <= 1'b1;
    end
end

function [7:0] to_int8(input signed [51:0] p);
    reg signed [51:0] r;
    begin
        r = (p + 52'sd8388608) >>> 24;       // + 2^23, then / 2^24 rounded
        to_int8 = (r < 0) ? 8'd0 : (r > 127) ? 8'd127 : r[7:0];
    end
endfunction

generate
    for (j = 0; j < N; j = j + 1) begin : post
        always @(posedge clk) begin
            // stage 1: bias (both sign-extended to 33 bits, so the sum cannot overflow)
            sum_s1[j]  <= $signed({acc[prow[1:0]][j][31], acc[prow[1:0]][j]})
                        + $signed({bias[j][31], bias[j]});
            prod_s2[j] <= sum_s1[j] * $signed({1'b0, mult[j]});       // stage 2: scale
            if (v_s2) q[row_s2][8*j +: 8] <= to_int8(prod_s2[j]);     // stage 3: round, ReLU, clamp
        end
    end
endgenerate

// Reads
always @(*) begin
    case (region)
        2'd0:    rd_data = {30'b0, q_ready, busy | g_busy | g_done};
        2'd3:    case (sub)
                     2'd0:    rd_data = acc[addr[5:4]][addr[3:2]];
                     2'd1:    rd_data = q[sidx];
                     2'd2:    rd_data = bias[sidx];
                     default: rd_data = {14'b0, mult[sidx]};
                 endcase
        default: rd_data = 32'b0;             // A / B buffers are write-only
    endcase
end

endmodule
