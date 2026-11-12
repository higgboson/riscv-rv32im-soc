// riscv_cpu.v - 5-stage pipelined RV32IM CPU (controller + datapath)
// The controller decodes the instruction in Decode (InstrD). The datapath carries each
// control signal down the pipeline to the stage that uses it.

module riscv_cpu (
    input         clk, reset,
    output [31:0] PC,
    input  [31:0] Instr,
    output        MemWrite,
    output [31:0] Mem_WrAddr, Mem_WrData,
    input  [31:0] ReadData,
    output [31:0] Result,
    output [ 2:0] funct3,              // funct3 of the instruction in Memory (for data_mem)
    output [31:0] PCW, ALUResultW, WriteDataW
);

wire [31:0] InstrD;
wire        ALUSrcD, RegWriteD, BranchD, JumpD, JalrD, MemWriteD, MulDivD;
wire [ 1:0] ResultSrcD, ASelD;
wire [ 2:0] ImmSrcD;
wire [ 3:0] ALUControlD;

controller  c   (InstrD[6:0], InstrD[14:12], InstrD[30], InstrD[25],
                ResultSrcD, MemWriteD, ALUSrcD,
                RegWriteD, BranchD, JumpD, JalrD, ImmSrcD, ALUControlD, ASelD, MulDivD);

datapath    dp  (
    .clk(clk), .reset(reset),
    .ResultSrcD(ResultSrcD), .MemWriteD(MemWriteD), .ALUSrcD(ALUSrcD), .RegWriteD(RegWriteD),
    .BranchD(BranchD), .JumpD(JumpD), .JalrD(JalrD), .MulDivD(MulDivD),
    .ImmSrcD(ImmSrcD), .ALUControlD(ALUControlD), .ASelD(ASelD),
    .InstrD(InstrD),
    .PC(PC), .Instr(Instr),
    .MemWrite(MemWrite), .funct3(funct3),
    .Mem_WrAddr(Mem_WrAddr), .Mem_WrData(Mem_WrData), .ReadData(ReadData),
    .Result(Result), .PCW(PCW), .ALUResultW(ALUResultW), .WriteDataW(WriteDataW)
);

endmodule
