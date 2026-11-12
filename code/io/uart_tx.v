// uart_tx.v - UART transmitter with a small FIFO (8 data bits, no parity, 1 stop bit)
//
// The CPU writes a byte in one cycle, but one byte on the wire takes about 4,300 cycles
// at 115200 baud and 50 MHz. The FIFO lets the CPU drop a whole short string at once and
// carry on. When it is full, `full` tells software to wait (see putchar_ in console.c).

module uart_tx #(
    parameter CLK_HZ     = 50_000_000,
    parameter BAUD       = 115_200,
    parameter FIFO_DEPTH = 16
) (
    input        clk, reset,
    input        wr_en,          // push one byte
    input  [7:0] wr_data,
    output       full,
    output       busy,           // something is still waiting or being sent
    output reg   tx              // serial line, idles high
);

localparam integer DIV_I = (CLK_HZ + BAUD / 2) / BAUD;  // clock cycles per bit
localparam [15:0]  DIV   = DIV_I[15:0];
localparam AW  = $clog2(FIFO_DEPTH);

// FIFO: one extra pointer bit tells full (same index, different lap) from empty
reg [7:0]  fifo [0:FIFO_DEPTH-1];
reg [AW:0] wr_ptr, rd_ptr;

wire empty = (wr_ptr == rd_ptr);
assign full = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);

always @(posedge clk) begin
    if (reset)
        wr_ptr <= 0;
    else if (wr_en && !full) begin
        fifo[wr_ptr[AW-1:0]] <= wr_data;
        wr_ptr <= wr_ptr + 1'b1;
    end
end

// Sender: shift out {stop, data[7:0], start}, lowest bit first
reg [9:0]  shift;
reg [3:0]  bits_left;
reg [15:0] baud_cnt;

assign busy = !empty || (bits_left != 0) || (baud_cnt != 0);

// baud_cnt holds each bit on the line for DIV cycles. The next byte is only taken once
// it reaches 0 again, so the stop bit also lasts a full bit time.
always @(posedge clk) begin
    if (reset) begin
        rd_ptr    <= 0;
        bits_left <= 0;
        baud_cnt  <= 0;
        tx        <= 1'b1;
    end else if (baud_cnt != 0) begin
        baud_cnt  <= baud_cnt - 1'b1;
    end else if (bits_left != 0) begin
        tx        <= shift[0];
        shift     <= {1'b1, shift[9:1]};
        bits_left <= bits_left - 1'b1;
        baud_cnt  <= DIV - 1'b1;
    end else if (!empty) begin
        shift     <= {1'b1, fifo[rd_ptr[AW-1:0]], 1'b0};
        rd_ptr    <= rd_ptr + 1'b1;
        bits_left <= 4'd10;
    end
end

endmodule
