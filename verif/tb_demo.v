// tb_demo.v - runs sw/programs/nn_demo with a model of the 2.4" TFT: the SPI stream is decoded
// the way the panel does it (column / row window, then RGB565 pixels) into a 240x320 picture,
// written as a PPM file whenever the program asks the panel for a new window after a quiet
// spell, and at the end. It can also play the laptop: send a digit over the UART.
//
// +SW=<hex>       board switches (default 0: digit mode)
// +DIGIT=<file>   after the program starts, send 'D', wait for ACK, send 784 bytes (hex file)
// +SNAP=<n>       write a snapshot every n cycles (default 4,000,000)
// +MAXCYC=<n>     stop after n cycles (default 20,000,000)
// Snapshots: screen_<k>.ppm in the directory the simulator runs in.

`timescale 1ns/1ns
module tb_demo;

reg clk = 0, reset = 1;
always #5 clk = ~clk;

reg  [15:0] sw;
reg         rx = 1'b1;
wire        uart_tx;
wire        cs, rstn, dc, mosi, sck, bl;

// 1 Mbaud: 50 clocks per bit
soc #(.CLK_HZ(50_000_000), .BAUD(1_000_000)) uut (
    .clk(clk), .reset(reset),
    .Ext_MemWrite(1'b0), .Ext_WriteData(32'b0), .Ext_DataAdr(32'b0),
    .MemWrite(), .WriteData(), .DataAdr(), .ReadData(),
    .PCW(), .Result(), .ALUResultW(), .WriteDataW(),
    .leds(), .hex(), .switches(sw), .buttons(4'b0000),
    .uart_rx(rx), .uart_tx(uart_tx), .tohost(), .tohost_valid(), .loading(),
    .tft_cs(cs), .tft_rst(rstn), .tft_dc(dc), .tft_mosi(mosi), .tft_sck(sck), .tft_led(bl)
);

// ---------------------------------------------------------------- panel model
reg [15:0] fb [0:240*320-1];
reg [7:0]  cur, cmd;
integer    nb = 0, argn = 0, xs, xe, ys, ye, px, py, hi, pixbytes = 0, k;
reg [7:0]  hib;
always @(posedge sck) if (!cs) begin
    cur = {cur[6:0], mosi};
    nb = nb + 1;
    if (nb == 8) begin
        nb = 0;
        if (!dc) begin cmd = cur; argn = 0; hi = 1; if (cur == 8'h2C) begin px = xs; py = ys; end end
        else begin
            case (cmd)
                8'h2A: begin case (argn) 0: xs = cur << 8; 1: xs = xs | cur; 2: xe = cur << 8; 3: xe = xe | cur; endcase end
                8'h2B: begin case (argn) 0: ys = cur << 8; 1: ys = ys | cur; 2: ye = cur << 8; 3: ye = ye | cur; endcase end
                8'h2C: begin
                    if (hi) hib = cur;
                    else begin
                        if (px < 240 && py < 320) fb[py * 240 + px] = {hib, cur};
                        if (px == xe) begin px = xs; py = py + 1; end else px = px + 1;
                        pixbytes = pixbytes + 2;
                    end
                    hi = !hi;
                end
                default: ;
            endcase
            argn = argn + 1;
        end
    end
end
always @(posedge cs) nb = 0;

integer snap_n = 0, f, i;
task snapshot;
    reg [15:0] p;
    reg [8*32-1:0] name;
    begin
        $sformat(name, "screen_%0d.ppm", snap_n);
        f = $fopen(name, "w");
        $fwrite(f, "P3\n240 320\n255\n");
        for (i = 0; i < 240 * 320; i = i + 1) begin
            p = fb[i];
            $fwrite(f, "%0d %0d %0d\n", {p[15:11], 3'b0}, {p[10:5], 2'b0}, {p[4:0], 3'b0});
        end
        $fclose(f);
        $display("[%0t] snapshot screen_%0d.ppm (%0d pixel bytes so far)", $time, snap_n, pixbytes);
        snap_n = snap_n + 1;
    end
endtask

// ---------------------------------------------------------------- UART
task send_byte(input [7:0] b);
    integer j;
    begin
        rx = 0; repeat (50) @(posedge clk);
        for (j = 0; j < 8; j = j + 1) begin rx = b[j]; repeat (50) @(posedge clk); end
        rx = 1; repeat (60) @(posedge clk);
    end
endtask

// bytes the program sends back
reg [7:0] rxb;
reg       got_ack = 0;
integer   bitn;
always @(negedge uart_tx) begin
    #250;                                          // middle of the start bit (25 clocks)
    for (bitn = 0; bitn < 8; bitn = bitn + 1) begin #500; rxb[bitn] = uart_tx; end
    if (rxb == 8'h06) got_ack = 1;
    // (other bytes are printed by mmio.v already)
end

reg [7:0] digit [0:783];
reg [8*256-1:0] digit_file;
integer snap_every, max_cycles, cycles = 0;

initial begin
    for (i = 0; i < 240 * 320; i = i + 1) fb[i] = 16'h0000;
    if (!$value$plusargs("SW=%h", sw)) sw = 16'h0000;
    if (!$value$plusargs("SNAP=%d", snap_every)) snap_every = 4000000;
    if (!$value$plusargs("MAXCYC=%d", max_cycles)) max_cycles = 20000000;
    repeat (3) @(negedge clk);
    reset = 0;
end

always @(posedge clk) begin
    cycles = cycles + 1;
    if (cycles % snap_every == 0) snapshot;
    if (cycles == max_cycles) begin snapshot; $finish; end
end

initial begin
    if ($value$plusargs("DIGIT=%s", digit_file)) begin
        $readmemh(digit_file, digit);
        repeat (300000) @(posedge clk);            // let the program set up the screen
        send_byte("D");
        wait (got_ack);
        $display("[%0t] ACK, sending the digit", $time);
        for (k = 0; k < 784; k = k + 1) send_byte(digit[k]);
    end
end

endmodule
