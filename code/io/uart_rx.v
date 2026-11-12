// uart_rx.v - UART receiver (8 data bits, no parity, 1 stop bit)
//
// The input comes from another clock domain (the PC's USB-UART chip), so it first goes
// through two flip-flops to avoid metastability. A falling edge starts a byte. Each bit is
// then sampled in the middle of its time slot, where the signal is most stable.
// `valid` pulses for one cycle with the received byte in `data`.

module uart_rx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input            clk, reset,
    input            rx,
    output reg       valid,
    output reg [7:0] data
);

localparam integer DIV_I = (CLK_HZ + BAUD / 2) / BAUD;  // clock cycles per bit
localparam [15:0]  DIV   = DIV_I[15:0];

reg rx_s1, rx_s2;                  // synchroniser
always @(posedge clk) begin
    rx_s1 <= rx;
    rx_s2 <= rx_s1;
end

reg        active;
reg [3:0]  bit_idx;                // 0 = start bit, 1..8 = data, 9 = stop
reg [15:0] baud_cnt;
reg [7:0]  shift;

always @(posedge clk) begin
    valid <= 1'b0;
    if (reset) begin
        active <= 1'b0;
    end else if (!active) begin
        if (!rx_s2) begin
            // start bit seen: wait half a bit to land in its middle
            active   <= 1'b1;
            bit_idx  <= 0;
            baud_cnt <= DIV >> 1;
        end
    end else if (baud_cnt != 0) begin
        baud_cnt <= baud_cnt - 1'b1;
    end else begin
        baud_cnt <= DIV - 1'b1;
        if (bit_idx == 0) begin
            // still low in the middle of the start bit? if not it was a glitch
            if (rx_s2) active <= 1'b0;
        end else if (bit_idx <= 8) begin
            shift <= {rx_s2, shift[7:1]};
        end else begin
            active <= 1'b0;
            if (rx_s2) begin             // good stop bit
                data  <= shift;
                valid <= 1'b1;
            end
        end
        bit_idx <= bit_idx + 1'b1;
    end
end

endmodule
