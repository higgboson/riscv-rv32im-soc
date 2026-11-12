// tb_program.v - runs a compiled program until it writes TOHOST, then reports pass / fail.
// Console output from the program is printed as it runs (see mmio.v).
// The hex files (imem.hex, dmem0..3.hex) must be in the directory the simulator runs in.
//
// +MAXCYC=<n>  give up after n cycles (default 2,000,000)

`timescale 1ns/1ns
module tb_program;

reg clk, reset;
wire MemWrite;
wire [31:0] WriteData, DataAdr, ReadData, PCW, Result, ALUResultW, WriteDataW;

pl_riscv_cpu uut (clk, reset, 1'b0, 32'b0, 32'b0, MemWrite, WriteData, DataAdr, ReadData,
                  PCW, Result, ALUResultW, WriteDataW);

initial begin clk = 0; reset = 1; end
always #5 clk = ~clk;

integer cycles, max_cycles;

initial begin
    if (!$value$plusargs("MAXCYC=%d", max_cycles)) max_cycles = 2000000;
    repeat (3) @(negedge clk);
    reset = 0;
    cycles = 0;
    while (!uut.io.tohost_valid && cycles < max_cycles) begin
        @(posedge clk);
        cycles = cycles + 1;
    end

    if (!uut.io.tohost_valid)
        $display("\nTIMEOUT after %0d cycles", cycles);
    else if (uut.io.tohost == 1)
        $display("\nPASS (%0d cycles)", cycles);
    else
        $display("\nFAIL code %0d (%0d cycles)", uut.io.tohost >> 1, cycles);
    $finish;
end

endmodule
