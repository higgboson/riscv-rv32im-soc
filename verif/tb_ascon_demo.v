// tb_ascon_demo.v - plays the Basys 3 Ascon demo the way a person would: types commands
// into the UART and presses the buttons, while the program's output is printed (mmio.v).
// verif/check_ascon_demo.py then checks every printed result against sw/ascon_ref.py.
//
// Build the program with the waits shortened, then run (from sw/):
//   make PROG=ascon_demo CFLAGS_EXTRA=-DCLK_MHZ=1
//   see verif/run_ascon_demo.sh

`timescale 1ns/1ns
module tb_ascon_demo;

localparam CLK_HZ = 50_000_000;
localparam BAUD   = 5_000_000;                 // 10 clock cycles per bit
localparam BIT    = CLK_HZ / BAUD;

reg        clk = 0, reset = 1, rx_line = 1;
reg  [3:0] buttons = 4'b0000;                  // {down, right, left, up}
wire [15:0] leds;
wire [19:0] hex;

soc #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uut (
    .clk(clk), .reset(reset),
    .Ext_MemWrite(1'b0), .Ext_WriteData(32'b0), .Ext_DataAdr(32'b0),
    .MemWrite(), .WriteData(), .DataAdr(), .ReadData(),
    .PCW(), .Result(), .ALUResultW(), .WriteDataW(),
    .leds(leds), .hex(hex), .switches(16'h0000), .buttons(buttons),
    .uart_rx(rx_line), .uart_tx(), .tohost(), .tohost_valid(), .loading()
);

always #5 clk = ~clk;

task send_byte(input [7:0] b);
    integer i;
    begin
        rx_line = 0;
        repeat (BIT) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            rx_line = b[i];
            repeat (BIT) @(posedge clk);
        end
        rx_line = 1;
        repeat (BIT * 4) @(posedge clk);       // gap so the program can echo each character
    end
endtask

// a command, sent one character at a time and finished with Enter
task type_line(input [8*64-1:0] s);
    integer i;
    reg [7:0] c;
    begin
        for (i = 63; i >= 0; i = i - 1) begin
            c = s[8*i +: 8];
            if (c != 0) send_byte(c);
        end
        send_byte(8'h0D);
        repeat (200_000) @(posedge clk);
    end
endtask

task press(input [3:0] which);
    begin
        buttons = which;
        repeat (2_000) @(posedge clk);
        buttons = 4'b0000;
        repeat (250_000) @(posedge clk);
    end
endtask

task show_board;
    $display("\n[board] 7-seg %h  LEDs %h", hex[15:0], leds);
endtask

initial begin
    repeat (3) @(negedge clk);
    reset = 0;
    repeat (100_000) @(posedge clk);
    type_line("e MEET AT 5PM");          show_board;
    type_line("d");                      show_board;
    type_line("t");                      show_board;
    type_line("e Ascon on a RISC-V SoC, verified with UVM. 37 bytes+");
    type_line("d");                      show_board;
    type_line("h hello");                show_board;
    type_line("h hellp");                show_board;
    type_line("h");
    type_line("x");
    press(4'b0010);                      show_board;     // btnL: lock the built-in message
    press(4'b0001);                      show_board;     // btnU: unlock
    press(4'b1000);                      show_board;     // btnD: tamper
    press(4'b0100);                      show_board;     // btnR: fingerprint
    $display("\n[tb] done");
    $finish;
end

endmodule
