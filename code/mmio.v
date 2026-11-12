// mmio.v - memory-mapped I/O. Programs reach hardware with normal loads and stores.
//
// Any address with the top 4 bits = 0x1 comes here instead of data memory.
//   0x1000_0000  CONSOLE  write: sends the low byte as a character (printed by the simulator)
//   0x1000_0004  TOHOST   write: the program is done. 1 = pass, anything else = fail code.
//                         Same rule as the official riscv-tests, so they run unchanged.
//   0x1000_0008  LEDS     read / write: 8-bit LED register (wired to board LEDs on an FPGA)
//
// Performance counters (read only, count from reset, 32 bits so they wrap after 2^32):
//   0x1000_0010  CYCLES       clock cycles
//   0x1000_0014  INSTRET      instructions retired (finished Writeback, bubbles not counted)
//   0x1000_0018  BRANCHES     conditional branches executed
//   0x1000_001C  JUMPS        jal / jalr executed
//   0x1000_0020  MISPREDICTS  branches / jumps whose next PC was guessed wrong (each costs 2 cycles)
// A program reads a counter before and after a piece of code and subtracts.
// CPI = cycles / instructions: 1.0 would be perfect for this pipeline.

module mmio (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    input      [ 3:0] perf_events,      // {mispredict, jump, branch, retire} pulses from the CPU
    output reg [31:0] rd_data,
    output reg [ 7:0] leds,
    output reg [31:0] tohost,
    output reg        tohost_valid
);

wire [3:0] reg_sel = addr[5:2];   // word offset inside the I/O area

reg [31:0] cycles, instret, branches, jumps, mispredicts;

always @(posedge clk) begin
    if (reset) begin
        cycles <= 0; instret <= 0; branches <= 0; jumps <= 0; mispredicts <= 0;
    end else begin
        cycles      <= cycles      + 1'b1;
        instret     <= instret     + perf_events[0];
        branches    <= branches    + perf_events[1];
        jumps       <= jumps       + perf_events[2];
        mispredicts <= mispredicts + perf_events[3];
    end
end

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
        4'd4:    rd_data = cycles;
        4'd5:    rd_data = instret;
        4'd6:    rd_data = branches;
        4'd7:    rd_data = jumps;
        4'd8:    rd_data = mispredicts;
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
