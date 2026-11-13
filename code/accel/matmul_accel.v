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
// Without "clear", a run adds onto the old C, so long sums can be split into pieces.

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

// Reads
always @(*) begin
    case (region)
        2'd0:    rd_data = {31'b0, busy};
        2'd3:    rd_data = acc[addr[5:4]][addr[3:2]];
        default: rd_data = 32'b0;             // A / B buffers are write-only
    endcase
end

endmodule
