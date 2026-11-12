// basys3_top.v - runs the SoC on a Digilent Basys 3 (Xilinx Artix-7 XC7A35T)
//
//   clock    : 100 MHz board oscillator -> MMCM -> CPU clock (CLK_HZ)
//   btnC     : reset (hold to restart the program)
//   UART     : USB port, 115200 baud 8N1 (open the COM port in PuTTY / Tera Term)
//   LEDs     : LEDS register; LED 15 = program passed, LED 14 = program failed,
//              LED 13 = a program is being loaded over the UART (sw/load.py)
//   7-seg    : HEX register, in hexadecimal
//   switches : SWITCHES register
//   btnU/L/R/D : BUTTONS register

module basys3_top #(
    parameter CLK_HZ = 50_000_000      // must match CLKOUT_DIV below (1000 MHz / CLKOUT_DIV)
) (
    input         clk,                 // 100 MHz
    input         btnC, btnU, btnL, btnR, btnD,
    input  [15:0] sw,
    output [15:0] led,
    output [ 6:0] seg,
    output        dp,
    output [ 3:0] an,
    input         RsRx,
    output        RsTx
);

// Clock
// The MMCM turns 100 MHz into the CPU clock. It runs its oscillator (VCO) at 1000 MHz
// (100 MHz x 10) and divides it down. The CPU can't run at 100 MHz yet (see the README).
wire cpu_clk, mmcm_locked;

`ifdef SYNTHESIS
localparam real CLKOUT_DIV = 1000.0e6 / CLK_HZ;
wire clk_fb, clk_unbuf;

MMCME2_BASE #(
    .CLKIN1_PERIOD    (10.0),           // 100 MHz input
    .CLKFBOUT_MULT_F  (10.0),           // VCO = 1000 MHz
    .CLKOUT0_DIVIDE_F (CLKOUT_DIV),
    .DIVCLK_DIVIDE    (1)
) mmcm (
    .CLKIN1(clk), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
    .CLKOUT0(clk_unbuf), .LOCKED(mmcm_locked),
    .RST(1'b0), .PWRDWN(1'b0),
    .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(),
    .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB()
);

// BUFG: global clock network, so the clock reaches every flip-flop at nearly the same time
BUFG cpu_bufg (.I(clk_unbuf), .O(cpu_clk));
`else
// simulation: no MMCM model, just use the input clock
assign cpu_clk     = clk;
assign mmcm_locked = 1'b1;
`endif

// Reset
// Held while the clock is not stable yet or btnC is pressed. The button is synchronised
// to the CPU clock, and reset is stretched to 16 cycles so every part sees it.
reg [1:0] btn_sync;
reg [4:0] rst_cnt = 0;

always @(posedge cpu_clk) begin
    btn_sync <= {btn_sync[0], btnC};
    if (!mmcm_locked || btn_sync[1])
        rst_cnt <= 0;
    else if (!rst_cnt[4])
        rst_cnt <= rst_cnt + 1'b1;
end

wire reset = !rst_cnt[4];

// System
wire [15:0] leds;
wire [19:0] hex;
wire [31:0] tohost;
wire        tohost_valid, loading;

soc #(.CLK_HZ(CLK_HZ), .BAUD(115_200)) soc_i (
    .clk(cpu_clk), .reset(reset),
    .Ext_MemWrite(1'b0), .Ext_WriteData(32'b0), .Ext_DataAdr(32'b0),
    .MemWrite(), .WriteData(), .DataAdr(), .ReadData(),
    .PCW(), .Result(), .ALUResultW(), .WriteDataW(),
    .leds(leds), .hex(hex), .switches(sw), .buttons({btnD, btnR, btnL, btnU}),
    .uart_rx(RsRx), .uart_tx(RsTx),
    .tohost(tohost), .tohost_valid(tohost_valid), .loading(loading)
);

// LED 15 / 14 show the program's pass / fail result once it writes TOHOST
wire passed = tohost_valid && (tohost == 32'd1);
wire failed = tohost_valid && (tohost != 32'd1);
assign led = {passed, failed, loading, leds[12:0]};

seven_seg #(.CLK_HZ(CLK_HZ)) disp (
    .clk(cpu_clk), .value(hex[15:0]), .dots(hex[19:16]),
    .seg(seg), .dp(dp), .an(an)
);

endmodule
