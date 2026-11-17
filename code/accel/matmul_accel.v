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
//   0x030  L_IN    layer engine: input feature map (height x width x C, INT8)
//   0x034  L_OUT   pooled output (PH x PW x F, INT8), 4-byte aligned
//   0x038  L_WT    weights, K x F with K = 9*C in the order (ky, kx, channel)
//   0x03C  L_BIAS  F int32 biases          0x040  L_MULT  F int32 scales
//   0x044  L_SHAPE bits 7:0 width, 15:8 C, 23:16 F (multiple of 4, at most 16), 31:24 PH
//   0x048  L_SHAPE2 bits 7:0 PW (2*PW at most 32), 15:8 kernel rows per run (rows*3*C <= 64)
//   CTRL bit 12 = run a whole layer: 3x3 convolution, bias, scale, ReLU and 2x2 max pooling
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
//
// The layer engine runs a whole convolution layer by itself: for every pair of conv output
// rows, every 4 pixels and every 4 filters it loads that group's bias and scale from memory,
// gathers the patches and weights, runs the array (in pieces when the patch has more than 64
// steps) and keeps the INT8 results of the two rows in a small buffer. Then it writes the
// 2x2 max-pooled row back to data memory through the same port. The CPU only describes the
// layer and waits.

module matmul_accel #(parameter MAXK = 64) (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    output reg [31:0] rd_data,
    output     [31:0] mem_addr,               // data memory port B: gather reads, layer
    input      [31:0] mem_rdata,              //   engine reads (word one cycle after the
    output     [3:0]  mem_we,                 //   address) and pooled-result writes
    output     [31:0] mem_wdata
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

reg         l_busy;                        // the layer engine is working
reg         e_cmd;                         // a command from the layer engine
reg  [11:0] e_bits;

wire ctrl_wr = wr_en && region == 2'd0 && addr[7:2] == 6'd0;
wire idle_all = !busy && !g_busy && !g_done && !l_busy;
wire cmd_cpu = ctrl_wr && (wr_data[8] || wr_data[10] || wr_data[11]) && idle_all;
wire cmd     = cmd_cpu || e_cmd;
wire [11:0] cbits = cmd_cpu ? wr_data[11:0] : e_bits;
wire cmd_gather = cmd && (cbits[10] || cbits[11]);
wire l_start = ctrl_wr && wr_data[12] && idle_all;

// a run starts straight from the command, or when the gathering it asked for is done
reg         pend_run, pend_clear;
reg  [KW:0] pend_k;
wire start = (cmd && cbits[8] && !cmd_gather) || (g_done && pend_run);
wire clear = start && (cmd ? cbits[9] : pend_clear);

initial busy = 0;

always @(posedge clk) begin
    if (cmd_gather) begin
        pend_run   <= cbits[8];
        pend_clear <= cbits[9];
        pend_k     <= cbits[KW:0];
    end
end

always @(posedge clk) begin
    if (reset) begin
        busy <= 1'b0;
    end else if (start) begin
        busy  <= 1'b1;
        k_len <= cmd ? cbits[KW:0] : pend_k;
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
// the layer engine sets both descriptors in the same cycle as its command
reg         e_desc;
reg  [31:0] e_abase, e_bbase;
reg  [7:0]  e_an0, e_an2, e_bn0;
reg  [2:0]  e_lanes;
reg  [15:0] e_as1, e_as2, e_bs0;
always @(posedge clk)
    if (e_desc) begin
        gd_base[0] <= e_abase;  gd_n0[0] <= e_an0;  gd_n1[0] <= 8'd3;  gd_n2[0] <= e_an2;
        gd_lanes[0] <= e_lanes; gd_s0[0] <= 16'd1;  gd_s1[0] <= e_as1; gd_s2[0] <= e_as2;
        gd_sl[0] <= e_as1;
        gd_base[1] <= e_bbase;  gd_n0[1] <= e_bn0;  gd_n1[1] <= 8'd1;  gd_n2[1] <= 8'd1;
        gd_lanes[1] <= 3'd4;    gd_s0[1] <= e_bs0;  gd_s1[1] <= 16'd0; gd_s2[1] <= 16'd0;
        gd_sl[1] <= 16'd1;
    end else if (desc_wr)
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
reg         e_mem;                         // the layer engine owns port B
reg  [31:0] e_maddr;
assign mem_addr = e_mem ? e_maddr : rd_addr;

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
        g_sel    <= !cbits[10];            // start with A unless only B was asked for
        g_then_b <= cbits[10] && cbits[11];
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

// Layer engine
reg  [31:0] l_in, l_out, l_wt, l_bias, l_mult;
reg  [7:0]  l_w, l_c, l_f, l_ph, l_pw, l_rpr;
always @(posedge clk)
    if (wr_en && region == 2'd0)
        case (addr[7:2])
            6'd12: l_in   <= wr_data;
            6'd13: l_out  <= wr_data;
            6'd14: l_wt   <= wr_data;
            6'd15: l_bias <= wr_data;
            6'd16: l_mult <= wr_data;
            6'd17: begin l_w <= wr_data[7:0]; l_c <= wr_data[15:8]; l_f <= wr_data[23:16]; l_ph <= wr_data[31:24]; end
            6'd18: begin l_pw <= wr_data[7:0]; l_rpr <= wr_data[15:8]; end
            default: ;
        endcase

localparam E_IDLE = 3'd0, E_PARAM = 3'd1, E_SETUP = 3'd2, E_CMD = 3'd3,
           E_WAIT = 3'd4, E_STORE = 3'd5, E_POOL = 3'd6, E_TURN = 3'd7;
reg  [2:0]  e_st;
reg  [7:0]  e_py, e_x0, e_f0, e_px, e_fg;
reg         e_d, e_finish;
reg  [1:0]  e_ky0, e_nr;
reg  [3:0]  e_i;                           // PARAM: read 0..8, STORE: lane 0..3
reg         e_need_a, e_last_piece;

// two conv output rows of INT8 results; one word = 4 filters of one pixel: {row, x, filter/4}
reg  [31:0] rowbuf [0:255];
reg         rb_we;
reg  [7:0]  rb_widx;
reg  [31:0] rb_wdata;
always @(posedge clk) if (rb_we) rowbuf[rb_widx] <= rb_wdata;

wire [7:0]  ow        = {l_pw[6:0], 1'b0};
wire [7:0]  oy        = {e_py[6:0], 1'b0} + {7'b0, e_d};
wire [1:0]  rows_left = 2'd3 - e_ky0;
wire [1:0]  nr        = (l_rpr[1:0] < rows_left) ? l_rpr[1:0] : rows_left;
wire [7:0]  three_c   = {l_c[6:0], 1'b0} + l_c;
wire [7:0]  steps     = (nr == 2'd1) ? three_c :
                        (nr == 2'd2) ? {three_c[6:0], 1'b0} : three_c + {three_c[6:0], 1'b0};
wire [7:0]  k0        = (e_ky0 == 2'd0) ? 8'd0 : (e_ky0 == 2'd1) ? three_c : {three_c[6:0], 1'b0};
wire [7:0]  x_left    = ow - e_x0;
wire [2:0]  lanes     = (x_left < 8'd4) ? x_left[2:0] : 3'd4;
wire        more_f    = e_f0 + 8'd4 < l_f;
wire        more_x    = e_x0 + 8'd4 < ow;

// PARAM read r (0..7): bias of filter f0 + r, then mult of filter f0 + r - 4
function [31:0] param_addr(input [3:0] r);
    param_addr = (r[2] ? l_mult : l_bias) + {22'b0, e_f0, 2'b00} + {28'b0, r[1:0], 2'b00};
endfunction

// 2x2 max pooling of one word (4 filters) of the two rows
function [7:0] max2(input [7:0] a, input [7:0] b);
    max2 = ($signed(a) > $signed(b)) ? a : b;
endfunction
wire [4:0]  pxa = {e_px[3:0], 1'b0};
wire [31:0] p00 = rowbuf[{1'b0, pxa,        e_fg[1:0]}];
wire [31:0] p01 = rowbuf[{1'b0, pxa + 5'd1, e_fg[1:0]}];
wire [31:0] p10 = rowbuf[{1'b1, pxa,        e_fg[1:0]}];
wire [31:0] p11 = rowbuf[{1'b1, pxa + 5'd1, e_fg[1:0]}];
reg  [31:0] pooled;
integer pb;
always @(*)
    for (pb = 0; pb < 4; pb = pb + 1)
        pooled[8*pb +: 8] = max2(max2(p00[8*pb +: 8], p01[8*pb +: 8]), max2(p10[8*pb +: 8], p11[8*pb +: 8]));

reg  [3:0]  e_we;
reg  [31:0] e_wdata;
assign mem_we    = e_we;
assign mem_wdata = e_wdata;

initial begin l_busy = 0; e_st = E_IDLE; e_cmd = 0; e_desc = 0; e_mem = 0; e_we = 0; rb_we = 0; end

always @(posedge clk) begin
    e_cmd <= 1'b0;  e_desc <= 1'b0;  e_we <= 4'b0;  rb_we <= 1'b0;
    if (reset) begin
        l_busy <= 1'b0;  e_st <= E_IDLE;  e_mem <= 1'b0;
    end else case (e_st)
        E_IDLE: if (l_start) begin
            l_busy <= 1'b1;
            e_py <= 0;  e_d <= 1'b0;  e_x0 <= 0;  e_f0 <= 0;  e_ky0 <= 0;  e_i <= 0;
            e_mem <= 1'b1;  e_maddr <= l_bias;        // PARAM read 0 for filter 0
            e_st <= E_PARAM;
        end
        // the address of read e_i is on port B now; its word arrives next cycle and is
        // written into bias / mult by the block below
        E_PARAM: begin
            if (e_i == 4'd8) begin
                e_mem <= 1'b0;  e_st <= E_SETUP;
            end else begin
                e_i <= e_i + 1'b1;
                if (e_i != 4'd7) e_maddr <= param_addr(e_i + 1'b1);
            end
        end
        // descriptors for this piece: A = patches of pixels x0.. (kernel rows ky0..), B = weights
        E_SETUP: begin
            e_abase  <= l_in + (({24'b0, oy} + {30'b0, e_ky0}) * {24'b0, l_w} + {24'b0, e_x0}) * {24'b0, l_c};
            e_bbase  <= l_wt + {24'b0, k0} * {24'b0, l_f} + {24'b0, e_f0};
            e_an0    <= l_c;    e_an2 <= {6'b0, nr};    e_lanes <= lanes;
            e_as1    <= {8'b0, l_c};
            e_as2    <= {8'b0, l_w} * {8'b0, l_c};
            e_bn0    <= steps;  e_bs0 <= {8'b0, l_f};
            // A stays in the array between filter groups when the whole patch fits in one run
            e_need_a <= (l_rpr < 8'd3) || (e_f0 == 8'd0);
            e_last_piece <= (e_ky0 + nr == 2'd3);
            e_nr     <= nr;
            e_st     <= E_CMD;
        end
        E_CMD: begin                               // gather B, gather A if needed, run
            e_desc <= 1'b1;  e_cmd <= 1'b1;
            e_bits <= {1'b1, e_need_a, e_ky0 == 2'd0, 1'b1, 1'b0, e_bn0[6:0]};
            e_st   <= E_WAIT;
        end
        E_WAIT: if (!busy && !g_busy && !g_done && !e_cmd) begin
            if (!e_last_piece) begin
                e_ky0 <= e_ky0 + e_nr;  e_st <= E_SETUP;
            end else if (q_ready) begin
                e_i <= 0;  e_st <= E_STORE;
            end
        end
        // the result words of the 1..4 pixels into the row buffer, then the next tile
        E_STORE: begin
            rb_we    <= 1'b1;
            rb_widx  <= {e_d, e_x0[4:0] + {1'b0, e_i}, e_f0[3:2]};
            rb_wdata <= q[e_i[1:0]];
            if (e_i != {1'b0, lanes} - 4'd1)
                e_i <= e_i + 1'b1;
            else begin
                e_ky0 <= 0;  e_i <= 0;
                if (more_f) begin
                    e_f0 <= e_f0 + 8'd4;
                    e_mem <= 1'b1;  e_maddr <= l_bias + {22'b0, e_f0 + 8'd4, 2'b00};  e_st <= E_PARAM;
                end else begin
                    e_f0 <= 0;
                    if (more_x || !e_d) begin
                        if (more_x) e_x0 <= e_x0 + 8'd4;
                        else begin e_x0 <= 0;  e_d <= 1'b1; end
                        e_mem <= 1'b1;  e_maddr <= l_bias;  e_st <= E_PARAM;
                    end else begin                 // both rows done: pool them
                        e_x0 <= 0;  e_px <= 0;  e_fg <= 0;  e_st <= E_POOL;
                    end
                end
            end
        end
        // one pooled word (4 filters of one output pixel) per cycle; the write is on port B
        // in the following cycle
        E_POOL: begin
            e_mem   <= 1'b1;
            e_maddr <= l_out + ({24'b0, e_py} * {24'b0, l_pw} + {24'b0, e_px}) * {24'b0, l_f}
                             + {22'b0, e_fg, 2'b00};
            e_we    <= 4'b1111;
            e_wdata <= pooled;
            if ({e_fg[5:0], 2'b00} + 8'd4 < l_f) e_fg <= e_fg + 1'b1;
            else begin
                e_fg <= 0;
                if (e_px + 8'd1 < l_pw) e_px <= e_px + 1'b1;
                else begin
                    e_finish <= (e_py + 8'd1 >= l_ph);
                    e_st <= E_TURN;
                end
            end
        end
        // the last pooled write is on port B this cycle; then the next row pair, or done
        E_TURN: begin
            if (e_finish) begin
                e_mem <= 1'b0;  l_busy <= 1'b0;  e_st <= E_IDLE;
            end else begin
                e_py <= e_py + 1'b1;  e_d <= 1'b0;  e_i <= 0;
                e_maddr <= l_bias;  e_st <= E_PARAM;
            end
        end
        default: e_st <= E_IDLE;
    endcase
end

// bias / mult: written by the CPU, or loaded by the layer engine (PARAM read r arrives while
// e_i = r + 1)
wire       e_bm_we  = (e_st == E_PARAM) && (e_i != 4'd0);
wire [3:0] e_bm_r   = e_i - 4'd1;
always @(posedge clk)
    if (e_bm_we) begin
        if (e_bm_r[2]) mult[e_bm_r[1:0]] <= mem_rdata[17:0];
        else           bias[e_bm_r[1:0]] <= mem_rdata;
    end else if (wr_en && region == 2'd3) begin
        if (sub == 2'd2) bias[sidx] <= wr_data;
        if (sub == 2'd3) mult[sidx] <= wr_data[17:0];
    end

// Reads
always @(*) begin
    case (region)
        2'd0:    rd_data = {30'b0, q_ready, busy | g_busy | g_done | l_busy};
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
