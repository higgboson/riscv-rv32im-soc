// tb_random.v - runs a program from gen_random.py and records what the CPU did:
//   got_trace.txt : every register write (seen in Writeback) and every store (seen in Memory)
//   got.txt       : final registers and data memory
// run_random.sh compares these with the Python model's expect files.

`timescale 1ns/1ns
module tb_random;

reg clk, reset;
wire MemWrite;
wire [31:0] WriteData, DataAdr, ReadData, PCW, Result, ALUResultW, WriteDataW;

wire uart_tx;

// fast UART (10 clocks per bit) so printing does not slow the simulation down
soc #(.CLK_HZ(50_000_000), .BAUD(5_000_000)) uut (
    .clk(clk), .reset(reset),
    .Ext_MemWrite(1'b0), .Ext_WriteData(32'b0), .Ext_DataAdr(32'b0),
    .MemWrite(MemWrite), .WriteData(WriteData), .DataAdr(DataAdr), .ReadData(ReadData),
    .PCW(PCW), .Result(Result), .ALUResultW(ALUResultW), .WriteDataW(WriteDataW),
    .leds(), .hex(), .switches(16'h0000), .buttons(4'b0000),
    .uart_rx(1'b1), .uart_tx(uart_tx), .tohost(), .tohost_valid(), .loading(),
    .ps2_clk_in(1'b1), .ps2_data_in(1'b1)
);

initial begin clk = 0; reset = 1; end
always #5 clk = ~clk;

integer i, f, ft, cycles;

// Register writes are logged when they leave Writeback.
// Stores are logged with the whole word just after memory is written (falling edge),
// while the store is still in the Memory stage.
always @(posedge clk) begin
    if (!reset && uut.rvcpu.dp.RegWriteW && uut.rvcpu.dp.RdW != 0)
        $fwrite(ft, "R %02d %08x\n", uut.rvcpu.dp.RdW, Result);
end

always @(negedge clk) begin
    #1;
    if (!reset && MemWrite && (DataAdr[31:28] != 4'h1))
        $fwrite(ft, "S %08x %02x%02x%02x%02x\n", {DataAdr[31:2], 2'b00} & 32'hFF,
                uut.datamem.mem3[DataAdr[13:2]], uut.datamem.mem2[DataAdr[13:2]],
                uut.datamem.mem1[DataAdr[13:2]], uut.datamem.mem0[DataAdr[13:2]]);
end

initial begin
    ft = $fopen("got_trace.txt", "w");
    if (!$value$plusargs("CYC=%d", cycles)) cycles = 5000;
    // release reset on a falling edge so it never races the rising edge
    repeat (3) @(negedge clk);
    reset = 0;
    repeat (cycles) @(posedge clk);

    f = $fopen("got.txt", "w");
    for (i = 1; i < 31; i = i + 1)
        $fwrite(f, "%08x%s", uut.rvcpu.dp.rf.ram1[i], (i == 30) ? "\n" : " ");
    for (i = 0; i < 64; i = i + 1)
        $fwrite(f, "%02x%02x%02x%02x%s", uut.datamem.mem3[i], uut.datamem.mem2[i],
                uut.datamem.mem1[i], uut.datamem.mem0[i], (i == 63) ? "\n" : " ");
    $fclose(f);
    $fclose(ft);
    $finish;
end

endmodule
