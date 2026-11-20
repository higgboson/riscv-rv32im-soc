// tb_ps2.v - unit test of code/io/ps2.v against a PS/2 mouse model
//
// 1. host sends 0xFF: the mouse must receive it with good parity and acknowledge;
//    the host must then receive FA AA 00 (the mouse starts answering right after its
//    acknowledge, as some devices do)
// 2. host sends 0xF4: FA back
// 3. the mouse sends 60 random bytes in bursts; the host reads them all, in order
// 4. a frame with bad parity sets the receive-error flag and is dropped
// 5. 40 bytes while nobody reads: the FIFO keeps the first 32
//   iverilog -g2005 -o tb_ps2 verif/tb_ps2.v code/io/ps2.v && vvp -n tb_ps2

`timescale 1ns/1ns
module tb_ps2;

reg clk = 0, reset = 1;
always #10 clk = ~clk;                             // 50 MHz

reg         wr_en = 0;
reg  [31:0] addr = 0, wr_data = 0;
wire [31:0] rd_data;
wire        h_clk_oe, h_dat_oe;
reg         m_clk_low = 0, m_dat_low = 0;
wire        ps2c = !(h_clk_oe | m_clk_low);
wire        ps2d = !(h_dat_oe | m_dat_low);

ps2 dut (.clk(clk), .reset(reset), .wr_en(wr_en), .addr(addr), .wr_data(wr_data), .rd_data(rd_data),
         .ps2_clk_in(ps2c), .ps2_data_in(ps2d), .clk_oe(h_clk_oe), .data_oe(h_dat_oe));

integer errors = 0;

// ---------------------------------------------------------------- host side (register access)
task wr(input [31:0] a, input [31:0] d);
    begin @(negedge clk); addr = a; wr_data = d; wr_en = 1; @(negedge clk); wr_en = 0; end
endtask
task rd(input [31:0] a, output [31:0] d);
    begin @(negedge clk); addr = a; #1 d = rd_data; end
endtask
task host_get(output integer b);                   // -1 after 3 ms without a byte
    reg [31:0] v;
    integer t;
    begin
        b = -1;
        for (t = 0; t < 150000 && b < 0; t = t + 1) begin
            rd(32'h0, v);
            if (v[8]) begin b = v[7:0]; wr(32'h0, 0); end
        end
    end
endtask
task host_send(input [7:0] c);
    reg [31:0] v;
    integer t;
    begin
        wr(32'h4, c);
        v = 2;
        for (t = 0; t < 200000 && v[1]; t = t + 1) rd(32'h8, v);
        if (v[1]) begin $display("FAIL: send of %02h never finished", c); errors = errors + 1; end
        if (v[2]) begin $display("FAIL: send of %02h not acknowledged", c); errors = errors + 1; end
    end
endtask
task expect_byte(input [7:0] want);
    integer b;
    begin
        host_get(b);
        if (b != want) begin $display("FAIL: expected %02h, got %0d", want, b); errors = errors + 1; end
    end
endtask

// ---------------------------------------------------------------- mouse model
localparam integer PH = 1000;                      // half clock period: 20 us (25 kHz)
reg bad_parity = 0;
task m_send(input [7:0] b);
    reg [10:0] fr;
    integer j;
    begin
        fr = {1'b1, bad_parity ? ^b : ~^b, b, 1'b0};
        wait (ps2c && !h_clk_oe);
        for (j = 0; j < 11; j = j + 1) begin
            m_dat_low = !fr[j];
            repeat (PH / 2) @(posedge clk);
            m_clk_low = 1;  repeat (PH) @(posedge clk);
            m_clk_low = 0;  repeat (PH / 2) @(posedge clk);
        end
        m_dat_low = 0;
        repeat (PH) @(posedge clk);
    end
endtask
task m_receive(output [7:0] b, output ok);
    reg [9:0] bits;
    integer j;
    begin
        for (j = 0; j < 10; j = j + 1) begin
            m_clk_low = 1;  repeat (PH) @(posedge clk);
            m_clk_low = 0;  repeat (PH / 2) @(posedge clk);
            bits[j] = ps2d;
            repeat (PH / 2) @(posedge clk);
        end
        m_dat_low = 1;                              // acknowledge on the 11th clock
        m_clk_low = 1;  repeat (PH) @(posedge clk);
        m_clk_low = 0;  repeat (PH) @(posedge clk);
        m_dat_low = 0;
        b  = bits[7:0];
        ok = (^bits[8:0]) && bits[9];
    end
endtask
reg [7:0] m_cmd;
reg       m_ok;
always begin
    wait (h_clk_oe);
    wait (!h_clk_oe && h_dat_oe);
    repeat (PH) @(posedge clk);
    m_receive(m_cmd, m_ok);
    if (!m_ok) begin $display("FAIL: mouse got %02h with bad parity / stop", m_cmd); errors = errors + 1; end
    else $display("mouse got %02h", m_cmd);
    m_send(8'hFA);                                   // straight after the acknowledge
    if (m_cmd == 8'hFF) begin m_send(8'hAA); m_send(8'h00); end
end

// ---------------------------------------------------------------- the test
reg [7:0] sent [0:63];
integer i, b, got;
reg [31:0] st;
initial begin
    repeat (5) @(negedge clk);
    reset = 0;
    repeat (100) @(negedge clk);

    host_send(8'hFF);  expect_byte(8'hFA);  expect_byte(8'hAA);  expect_byte(8'h00);
    host_send(8'hF4);  expect_byte(8'hFA);
    repeat (4 * PH) @(posedge clk);                  // let the mouse model finish that byte

    // mouse traffic, read as it comes (a packet is 3 bytes)
    fork
        for (i = 0; i < 60; i = i + 1) begin sent[i] = $random; m_send(sent[i]); end
        for (got = 0; got < 60; got = got + 1) begin
            host_get(b);
            if (b != sent[got]) begin $display("FAIL: byte %0d: sent %02h, got %0d", got, sent[got], b); errors = errors + 1; end
        end
    join

    // bad parity: flagged, dropped
    bad_parity = 1;  m_send(8'h5A);  bad_parity = 0;
    rd(32'h8, st);
    if (!st[3] || st[0]) begin $display("FAIL: bad parity not flagged / not dropped (status %h)", st); errors = errors + 1; end
    wr(32'h8, 0);

    // 40 bytes, nobody reading: the first 32 stay
    for (i = 0; i < 40; i = i + 1) m_send(i);
    for (i = 0; i < 32; i = i + 1) expect_byte(i);
    host_get(b);
    if (b != -1) begin $display("FAIL: FIFO kept more than 32 bytes"); errors = errors + 1; end

    if (errors == 0) $display("ps2 test: PASS (commands, 60 bytes, parity error, full FIFO)");
    else             $display("ps2 test: FAIL (%0d errors)", errors);
    $finish;
end

initial begin #400000000; $display("ps2 test: FAIL (timeout)"); $finish; end
endmodule
