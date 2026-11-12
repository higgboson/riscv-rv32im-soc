// pl_riscv_cpu.v - the original e-Yantra top level, kept so its testbench and the Quartus
// project work unchanged. It is just soc.v with the board inputs tied off.

module pl_riscv_cpu (
    input         clk, reset,
    input         Ext_MemWrite,
    input  [31:0] Ext_WriteData, Ext_DataAdr,
    output        MemWrite,
    output [31:0] WriteData, DataAdr, ReadData,
    output [31:0] PCW, Result, ALUResultW, WriteDataW
);

soc soc_i (
    .clk(clk), .reset(reset),
    .Ext_MemWrite(Ext_MemWrite), .Ext_WriteData(Ext_WriteData), .Ext_DataAdr(Ext_DataAdr),
    .MemWrite(MemWrite), .WriteData(WriteData), .DataAdr(DataAdr), .ReadData(ReadData),
    .PCW(PCW), .Result(Result), .ALUResultW(ALUResultW), .WriteDataW(WriteDataW),
    .leds(), .hex(), .switches(16'b0), .buttons(4'b0),
    .uart_rx(1'b1), .uart_tx(), .tohost(), .tohost_valid(), .loading()
);

endmodule
