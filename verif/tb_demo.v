// tb_demo.v - runs sw/programs/nn_demo with a model of the 2.4" TFT: the SPI stream is decoded
// the way the panel does it (column / row window, then RGB565 pixels) into a 240x320 picture
// (320x240 once the program turns the panel to landscape with MADCTL),
// written as a PPM file whenever the program asks the panel for a new window after a quiet
// spell, and at the end. It can also play the laptop: send a digit over the UART.
//
// +SW=<hex>       board switches (default 0: digit mode)
// +MOUSE          a PS/2 mouse: answers reset / enable like a real one, then draws a 7
// +KEYS=<text>    type these characters over the UART, one every +KEYGAP cycles (default
//                 300,000), starting at +KEYSTART (default 8,000,000); '_' types a space
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
// PS/2 lines: open drain, pulled up; low when the host or the mouse pulls
wire        h_clk_oe, h_dat_oe;
reg         m_clk_low = 0, m_dat_low = 0;
wire        ps2c = !(h_clk_oe | m_clk_low);
wire        ps2d = !(h_dat_oe | m_dat_low);

// 1 Mbaud: 50 clocks per bit
soc #(.CLK_HZ(50_000_000), .BAUD(1_000_000)) uut (
    .clk(clk), .reset(reset),
    .Ext_MemWrite(1'b0), .Ext_WriteData(32'b0), .Ext_DataAdr(32'b0),
    .MemWrite(), .WriteData(), .DataAdr(), .ReadData(),
    .PCW(), .Result(), .ALUResultW(), .WriteDataW(),
    .leds(), .hex(), .switches(sw), .buttons(4'b0000),
    .uart_rx(rx), .uart_tx(uart_tx), .tohost(), .tohost_valid(), .loading(),
    .tft_cs(cs), .tft_rst(rstn), .tft_dc(dc), .tft_mosi(mosi), .tft_sck(sck), .tft_led(bl),
    .ps2_clk_in(ps2c), .ps2_data_in(ps2d), .ps2_clk_oe(h_clk_oe), .ps2_data_oe(h_dat_oe)
);

// ---------------------------------------------------------------- PS/2 mouse model
// clock period 1000 cycles (50 kHz; real mice use 10..16.7 kHz, which only makes them slower)
localparam integer PH = 500;
reg mouse_on = 0;
task m_send(input [7:0] b);                       // device -> host: start, 8 bits, odd parity, stop
    reg [10:0] fr;
    integer j;
    begin
        fr = {1'b1, ~^b, b, 1'b0};
        wait (ps2c && !h_clk_oe);
        for (j = 0; j < 11; j = j + 1) begin
            m_dat_low = !fr[j];
            repeat (PH / 2) @(posedge clk);
            m_clk_low = 1;  repeat (PH) @(posedge clk);
            m_clk_low = 0;  repeat (PH / 2) @(posedge clk);
        end
        m_dat_low = 0;
        repeat (2 * PH) @(posedge clk);
    end
endtask
task m_receive(output [7:0] b, output ok);         // host -> device, after the host's request
    reg [9:0] bits;
    integer j;
    begin
        for (j = 0; j < 10; j = j + 1) begin
            m_clk_low = 1;  repeat (PH) @(posedge clk);
            m_clk_low = 0;  repeat (PH / 2) @(posedge clk);
            bits[j] = ps2d;                         // what the host set after this falling edge
            repeat (PH / 2) @(posedge clk);
        end
        m_dat_low = 1;                              // acknowledge
        m_clk_low = 1;  repeat (PH) @(posedge clk);
        m_clk_low = 0;  repeat (PH) @(posedge clk);
        m_dat_low = 0;
        b  = bits[7:0];
        ok = (^bits[8:0]) && bits[9];               // odd parity, stop bit
    end
endtask
reg [7:0] m_cmd;
reg       m_ok;
// answer the host's commands: request = clock held low, then data low with the clock released
always begin
    wait (h_clk_oe);
    wait (!h_clk_oe && h_dat_oe);
    repeat (PH) @(posedge clk);
    m_receive(m_cmd, m_ok);
    $display("[%0t] mouse got command %02h%s", $time, m_cmd, m_ok ? "" : " (BAD parity/stop)");
    m_send(8'hFA);
    if (m_cmd == 8'hFF) begin m_send(8'hAA); m_send(8'h00); end
    if (m_cmd == 8'hF4) mouse_on = 1;
end
// one movement packet: buttons, dx, dy (dy > 0 is up)
task m_move(input integer dx, input integer dy, input left);
    begin
        m_send({2'b00, dy < 0, dx < 0, 1'b1, 1'b0, 1'b0, left});
        m_send(dx[7:0]);
        m_send(dy[7:0]);
    end
endtask
integer mi;
initial if ($test$plusargs("MOUSE")) begin
    wait (mouse_on);
    $display("[%0t] mouse enabled, drawing a 7", $time);
    for (mi = 0; mi < 6; mi = mi + 1) m_move(-6, 8, 0);       // to the top left (cursor starts mid)
    for (mi = 0; mi < 10; mi = mi + 1) m_move(8, 0, 1);       // top bar, left button held
    for (mi = 0; mi < 14; mi = mi + 1) m_move(-3, -8, 1);     // down to the left
    m_move(0, 0, 0);                                          // let go
    $display("[%0t] mouse released the button", $time);
end

// ---------------------------------------------------------------- panel model
reg [15:0] fb [0:240*320-1];
reg [7:0]  cur, cmd;
integer    nb = 0, argn = 0, xs, xe, ys, ye, px, py, hi, pixbytes = 0, k;
reg [7:0]  hib;
reg        mv = 0;                              // MADCTL bit 5: rows and columns swapped (landscape)
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
                8'h36: if (argn == 0) mv = cur[5];
                8'h2C: begin
                    if (hi) hib = cur;
                    else begin
                        if (!mv && px < 240 && py < 320) fb[py * 240 + px] = {hib, cur};
                        if (mv && px < 320 && py < 240) fb[py * 320 + px] = {hib, cur};
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
        if (mv) $fwrite(f, "P3\n320 240\n255\n");
        else    $fwrite(f, "P3\n240 320\n255\n");
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
reg [8*64-1:0] keys;
integer key_gap, key_start, kn, kl;
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
    if ($value$plusargs("KEYS=%s", keys)) begin
        if (!$value$plusargs("KEYGAP=%d", key_gap)) key_gap = 300000;
        if (!$value$plusargs("KEYSTART=%d", key_start)) key_start = 8000000;
        kl = 0;
        for (kn = 0; kn < 64; kn = kn + 1) if (keys[8*kn +: 8] != 0) kl = kn + 1;
        repeat (key_start) @(posedge clk);
        for (kn = kl - 1; kn >= 0; kn = kn - 1) begin
            send_byte(keys[8*kn +: 8] == "_" ? " " : keys[8*kn +: 8]);
            repeat (key_gap) @(posedge clk);
        end
        $display("[%0t] all keys typed", $time);
    end
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
