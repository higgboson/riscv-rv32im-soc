// tb_basys3.v - simulates the whole Basys 3 top level, the way the board is used:
// press reset, let the program run, and read what comes out of the UART pin.
//
// A small UART receiver here decodes the RsTx pin bit by bit (like the PC's USB-UART chip)
// and collects the text. That checks the real serial output, not just the simulator's
// shortcut print. At the end it reports the text, the LEDs and the 7-segment value.
//
// CLK_HZ is set low here so one UART bit is only 10 clock cycles (115200 baud x 10).

`timescale 1ns/1ns
module tb_basys3;

localparam CLK_HZ = 1_152_000;
localparam BIT    = CLK_HZ / 115_200;           // clock cycles per UART bit

reg         clk = 0, btnC = 1;
reg  [15:0] sw = 16'h1234;
wire [15:0] led;
wire [ 6:0] seg;
wire [ 3:0] an;
wire        dp, RsTx;

basys3_top #(.CLK_HZ(CLK_HZ)) dut (
    .clk(clk), .btnC(btnC), .btnU(1'b0), .btnL(1'b0), .btnR(1'b0), .btnD(1'b0),
    .sw(sw), .led(led), .seg(seg), .dp(dp), .an(an), .RsRx(1'b1), .RsTx(RsTx)
);

always #5 clk = ~clk;

// UART receiver model: wait for the start bit, then sample each bit in its middle
reg [8*512-1:0] text = 0;
integer nchars = 0, i;
reg [7:0] ch;

initial begin
    forever begin
        @(negedge RsTx);
        repeat (BIT / 2) @(posedge clk);
        if (RsTx == 1'b0) begin
            for (i = 0; i < 8; i = i + 1) begin
                repeat (BIT) @(posedge clk);
                ch[i] = RsTx;
            end
            repeat (BIT) @(posedge clk);
            if (RsTx !== 1'b1) $display("UART framing error (no stop bit)");
            if (ch != 8'h0D) begin            // drop CR, keep LF
                text = {text[8*511-1:0], ch};
                nchars = nchars + 1;
            end
        end
    end
end

integer cycles, max_cycles;

initial begin
    if (!$value$plusargs("MAXCYC=%d", max_cycles)) max_cycles = 3000000;
    repeat (20) @(posedge clk);
    btnC = 0;                                 // release the reset button
    cycles = 0;
    while (!dut.soc_i.tohost_valid && cycles < max_cycles) begin
        @(posedge clk);
        cycles = cycles + 1;
    end
    // let the UART finish sending what is still in its FIFO
    while (dut.soc_i.io.tx_busy && cycles < max_cycles) begin
        @(posedge clk);
        cycles = cycles + 1;
    end
    repeat (4 * BIT) @(posedge clk);

    $display("---- UART output (%0d characters) ----", nchars);
    for (i = nchars - 1; i >= 0; i = i - 1)
        $write("%c", text[8*i +: 8]);
    $display("--------------------------------------");
    $display("LEDs = %b (LED15 pass, LED14 fail)", led);
    $display("7-seg value = %h", dut.soc_i.hex[15:0]);
    if (!dut.soc_i.tohost_valid)
        $display("BOARD TIMEOUT");
    else if (led[15] && !led[14])
        $display("BOARD PASS");
    else
        $display("BOARD FAIL");
    $finish;
end

endmodule
