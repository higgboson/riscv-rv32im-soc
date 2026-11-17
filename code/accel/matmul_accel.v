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
//   0x000  CTRL   write: bits 6:0 = K (1..64), bit 8 = start, bit 9 = clear C first
//                 read : bit 0 = busy
//   0x100  A_COL[k]  (k = 0..63) one word = A[0..3][k], byte i = row i
//   0x200  B_ROW[k]  (k = 0..63) one word = B[k][0..3], byte j = column j
//   0x300  C[i][j]   (16 words, row by row) read only
//   0x340  Q[i]      (4 words) read only: row i of C converted back to INT8 by the output stage,
//                    byte j = clamp((C[i][j] + BIAS[j]) * MULT[j] + 2^23 >> 24, 0, 127)
//   0x380  BIAS[j]   (4 words) read / write, added to column j
//   0x3C0  MULT[j]   (4 words) read / write, 18-bit unsigned scale of column j
// CTRL read bit 1 = Q ready. Without "clear", a run adds onto the old C, so long sums can be
// split into pieces; Q is only meaningful after the last piece.
//
// The output stage does what a neural-network layer needs after the multiply-adds: add the
// bias, scale back to 8 bits, ReLU. It runs in the 6 cycles after busy drops (one row per
// cycle through a 3-stage pipeline), so busy and the K + 6 run length are unchanged.

module matmul_accel #(parameter MAXK = 64) (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    output reg [31:0] rd_data
);

localparam N  = 4;
localparam KW = $clog2(MAXK);

wire [1:0]    region = addr[9:8];          // 0 = control, 1 = A, 2 = B, 3 = C
wire [KW-1:0] widx   = addr[KW+1:2];

// Operand buffers (small, become LUT RAM on the FPGA)
reg [31:0] a_buf [0:MAXK-1];
reg [31:0] b_buf [0:MAXK-1];

always @(posedge clk) begin
    if (wr_en && region == 2'd1) a_buf[widx] <= wr_data;
    if (wr_en && region == 2'd2) b_buf[widx] <= wr_data;
end

// Control
reg         busy;
reg  [KW:0] k_len;
reg  [7:0]  t;                             // step counter while busy
wire [7:0]  k8   = {{(7-KW){1'b0}}, k_len};  // K widened to the counter's width
wire [7:0]  last = k8 + 8'd5;              // last step, see below

wire start = wr_en && region == 2'd0 && wr_data[8] && !busy;
wire clear = start && wr_data[9];

initial busy = 0;

always @(posedge clk) begin
    if (reset) begin
        busy <= 1'b0;
    end else if (start) begin
        busy  <= 1'b1;
        k_len <= wr_data[KW:0];
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
    if (reset || start) begin
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
        2'd0:    rd_data = {30'b0, q_ready, busy};
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
