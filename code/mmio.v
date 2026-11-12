// mmio.v - memory-mapped I/O. Programs reach hardware with normal loads and stores.
//
// Any address with the top 4 bits = 0x1 comes here instead of data memory.
//   0x1000_0000  CONSOLE  write: sends the low byte as a character (printed by the simulator)
//   0x1000_0004  TOHOST   write: the program is done. 1 = pass, anything else = fail code.
//                         Same rule as the official riscv-tests, so they run unchanged.
//   0x1000_0008  LEDS     read / write: 8-bit LED register (wired to board LEDs on an FPGA)

module mmio (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    output reg [31:0] rd_data,
    output reg [ 7:0] leds,
    output reg [31:0] tohost,
    output reg        tohost_valid
);

wire [3:0] reg_sel = addr[5:2];   // word offset inside the I/O area

always @(posedge clk) begin
    if (reset) begin
        leds         <= 0;
        tohost       <= 0;
        tohost_valid <= 0;
    end else if (wr_en) begin
        case (reg_sel)
            4'd1: begin tohost <= wr_data; tohost_valid <= 1; end
            4'd2: leds <= wr_data[7:0];
            default: ;
        endcase
    end
end

always @(*) begin
    case (reg_sel)
        4'd2:    rd_data = {24'b0, leds};
        default: rd_data = 32'b0;
    endcase
end

// Simulation only: print console characters. Quartus skips this block.
// synthesis translate_off
always @(posedge clk) begin
    if (!reset && wr_en && reg_sel == 4'd0)
        $write("%c", wr_data[7:0]);
end
// synthesis translate_on

endmodule
