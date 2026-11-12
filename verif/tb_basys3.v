// tb_basys3.v - simulates the whole Basys 3 top level, the way the board is used:
// press reset, let the program run, and read what comes out of the UART pin.
//
// A small UART receiver here decodes the RsTx pin bit by bit (like the PC's USB-UART chip)
// and collects the text. That checks the real serial output, not just the simulator's
// shortcut print. At the end it reports the text, the LEDs and the 7-segment value.
//
// CLK_HZ is set low here so one UART bit is only 10 clock cycles (115200 baud x 10).
//
// +LOAD=<file> : after reset, send a program packet (from sw/load.py --dump) into the
//               RsRx pin, the way the PC would. This tests the UART loader end to end.
// +EXPECT_E    : the packet is damaged on purpose; pass if the loader answers 'E' and the
//               CPU never runs.

`timescale 1ns/1ns
module tb_basys3;

localparam CLK_HZ = 1_152_000;
localparam BIT    = CLK_HZ / 115_200;           // clock cycles per UART bit

reg         clk = 0, btnC = 1, rx_line = 1;
reg  [15:0] sw = 16'h1234;
wire [15:0] led;
wire [ 6:0] seg;
wire [ 3:0] an;
wire        dp, RsTx;

basys3_top #(.CLK_HZ(CLK_HZ)) dut (
    .clk(clk), .btnC(btnC), .btnU(1'b0), .btnL(1'b0), .btnR(1'b0), .btnD(1'b0),
    .sw(sw), .led(led), .seg(seg), .dp(dp), .an(an), .RsRx(rx_line), .RsTx(RsTx)
);

always #5 clk = ~clk;

// UART receiver model: wait for the start bit, then sample each bit in its middle
reg [8*4096-1:0] text = 0;
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
                text = {text[8*4095-1:0], ch};
                nchars = nchars + 1;
            end
        end
    end
end

// send one byte into RsRx: start bit, 8 data bits (lowest first), stop bit
task send_byte(input [7:0] b);
    integer k;
    begin
        rx_line = 0;
        repeat (BIT) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin
            rx_line = b[k];
            repeat (BIT) @(posedge clk);
        end
        rx_line = 1;
        repeat (BIT) @(posedge clk);
    end
endtask

reg [7:0] packet [0:65535];
reg [8*256-1:0] load_file;
integer n_packet, j, cycles, max_cycles;
reg expect_e;

initial begin
    if (!$value$plusargs("MAXCYC=%d", max_cycles)) max_cycles = 3000000;
    expect_e = $test$plusargs("EXPECT_E");
    repeat (20) @(posedge clk);
    btnC = 0;                                 // release the reset button
    cycles = 0;

    if ($value$plusargs("LOAD=%s", load_file)) begin
        // mark every slot unused, then load: the packet ends at the first unused slot
        for (n_packet = 0; n_packet < 65536; n_packet = n_packet + 1) packet[n_packet] = 8'hxx;
        $readmemh(load_file, packet);
        n_packet = 0;
        while (packet[n_packet] !== 8'hxx) n_packet = n_packet + 1;
        if (expect_e) packet[20] = packet[20] ^ 8'h01;    // flip one bit in the program
        repeat (200) @(posedge clk);          // the old program runs for a moment first
        $display("sending a %0d-byte program packet into RsRx", n_packet);
        for (j = 0; j < n_packet; j = j + 1)
            send_byte(packet[j]);
        if (expect_e) begin
            repeat (40 * BIT) @(posedge clk);
            $display("loader answer: %c, CPU held in reset: %b",
                     text[7:0], dut.soc_i.core_reset);
            if (text[7:0] == "E" && dut.soc_i.core_reset && !dut.soc_i.tohost_valid)
                $display("BOARD PASS (damaged program rejected)");
            else
                $display("BOARD FAIL (damaged program not rejected)");
            $finish;
        end
    end
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
