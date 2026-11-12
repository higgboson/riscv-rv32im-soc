// mmio.v - memory-mapped I/O. Programs reach hardware with normal loads and stores.
//
// Any address with the top 4 bits = 0x1 comes here instead of data memory.
//   0x1000_0000  UART_TX      write: send a character (also printed by the simulator)
//   0x1000_0004  TOHOST       write: the program is done. 1 = pass, anything else = fail code.
//                             Same rule as the official riscv-tests, so they run unchanged.
//   0x1000_0008  LEDS         read / write: 16 board LEDs
//   0x1000_000C  UART_STATUS  read: bit 0 = TX FIFO full, bit 1 = TX busy, bit 2 = RX byte waiting
//   0x1000_0024  HEX          read / write: bits 15:0 shown in hex on the 7-segment display,
//                             bits 19:16 = decimal points
//   0x1000_0028  SWITCHES     read: 16 board switches
//   0x1000_002C  BUTTONS      read: {down, right, left, up} (the centre button is reset)
//   0x1000_0030  UART_RX      read: bit 8 = byte waiting, bits 7:0 = the byte.
//                             write anything: mark the byte as taken.
//
// Performance counters (read only, count from reset, 32 bits so they wrap after 2^32):
//   0x1000_0010  CYCLES       clock cycles
//   0x1000_0014  INSTRET      instructions retired (finished Writeback, bubbles not counted)
//   0x1000_0018  BRANCHES     conditional branches executed
//   0x1000_001C  JUMPS        jal / jalr executed
//   0x1000_0020  MISPREDICTS  branches / jumps whose next PC was guessed wrong (each costs 2 cycles)
// A program reads a counter before and after a piece of code and subtracts.
// CPI = cycles / instructions: 1.0 would be perfect for this pipeline.
//
// Reads never change anything (UART_RX is cleared by a write, not by the read). That keeps
// loads free of side effects, so the pipeline never has to worry about a read happening twice.

module mmio #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    input      [ 3:0] perf_events,      // {mispredict, jump, branch, retire} pulses from the CPU
    output reg [31:0] rd_data,
    // board
    output reg [15:0] leds,
    output reg [19:0] hex,              // {dots, value} for the 7-segment display
    input      [15:0] switches,
    input      [ 3:0] buttons,
    input             uart_rx,
    output            uart_tx,
    // end of program (testbench / LEDs)
    output reg [31:0] tohost,
    output reg        tohost_valid
);

wire [3:0] reg_sel = addr[5:2];   // word offset inside the I/O area

localparam R_UART_TX = 4'd0,  R_TOHOST = 4'd1,  R_LEDS = 4'd2,     R_STATUS = 4'd3,
           R_CYCLES  = 4'd4,  R_INSTRET = 4'd5, R_BRANCHES = 4'd6, R_JUMPS = 4'd7,
           R_MISPRED = 4'd8,  R_HEX = 4'd9,     R_SWITCHES = 4'd10, R_BUTTONS = 4'd11,
           R_UART_RX = 4'd12;

// UART
wire tx_full, tx_busy, rx_byte_valid;
wire [7:0] rx_byte;

uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) utx (
    .clk(clk), .reset(reset),
    .wr_en(wr_en && reg_sel == R_UART_TX), .wr_data(wr_data[7:0]),
    .full(tx_full), .busy(tx_busy), .tx(uart_tx)
);

uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) urx (
    .clk(clk), .reset(reset), .rx(uart_rx),
    .valid(rx_byte_valid), .data(rx_byte)
);

// keep the last received byte until software takes it
reg       rx_waiting;
reg [7:0] rx_data;

always @(posedge clk) begin
    if (reset)
        rx_waiting <= 1'b0;
    else if (rx_byte_valid) begin
        rx_waiting <= 1'b1;
        rx_data    <= rx_byte;
    end else if (wr_en && reg_sel == R_UART_RX)
        rx_waiting <= 1'b0;
end

// Switches and buttons change at any time, not in step with our clock: synchronise them
reg [19:0] in_s1, in_s2;
always @(posedge clk) begin
    in_s1 <= {buttons, switches};
    in_s2 <= in_s1;
end

// Performance counters
reg [31:0] cycles, instret, branches, jumps, mispredicts;

always @(posedge clk) begin
    if (reset) begin
        cycles <= 0; instret <= 0; branches <= 0; jumps <= 0; mispredicts <= 0;
    end else begin
        cycles      <= cycles      + 1'b1;
        instret     <= instret     + {31'b0, perf_events[0]};
        branches    <= branches    + {31'b0, perf_events[1]};
        jumps       <= jumps       + {31'b0, perf_events[2]};
        mispredicts <= mispredicts + {31'b0, perf_events[3]};
    end
end

// Writable registers
always @(posedge clk) begin
    if (reset) begin
        leds         <= 0;
        hex          <= 0;
        tohost       <= 0;
        tohost_valid <= 0;
    end else if (wr_en) begin
        case (reg_sel)
            R_TOHOST: begin tohost <= wr_data; tohost_valid <= 1; end
            R_LEDS:   leds <= wr_data[15:0];
            R_HEX:    hex  <= wr_data[19:0];
            default: ;
        endcase
    end
end

always @(*) begin
    case (reg_sel)
        R_LEDS:     rd_data = {16'b0, leds};
        R_STATUS:   rd_data = {29'b0, rx_waiting, tx_busy, tx_full};
        R_CYCLES:   rd_data = cycles;
        R_INSTRET:  rd_data = instret;
        R_BRANCHES: rd_data = branches;
        R_JUMPS:    rd_data = jumps;
        R_MISPRED:  rd_data = mispredicts;
        R_HEX:      rd_data = {12'b0, hex};
        R_SWITCHES: rd_data = {16'b0, in_s2[15:0]};
        R_BUTTONS:  rd_data = {28'b0, in_s2[19:16]};
        R_UART_RX:  rd_data = {23'b0, rx_waiting, rx_data};
        default:    rd_data = 32'b0;
    endcase
end

// Simulation only: print console characters straight away. Quartus / Vivado skip this block.
// synthesis translate_off
always @(posedge clk) begin
    if (!reset && wr_en && reg_sel == R_UART_TX)
        $write("%c", wr_data[7:0]);
end
// synthesis translate_on

endmodule
