// datapath.v - 5-stage pipelined datapath (Fetch | Decode | Execute | Memory | Writeback)
// Each signal's suffix tells the stage it belongs to: F, D, E, M, W.

module datapath (
    input         clk, reset,
    // control signals made in Decode by the controller (from InstrD)
    input [1:0]   ResultSrcD,
    input         MemWriteD, ALUSrcD, RegWriteD,
    input         BranchD, JumpD, JalrD, MulDivD,
    input [2:0]   ImmSrcD,
    input [3:0]   ALUControlD,
    input [1:0]   ASelD,
    output [31:0] InstrD,             // to the controller
    // instruction memory
    output [31:0] PC,
    input  [31:0] Instr,
    // data memory (used in the Memory stage)
    output        MemWrite,
    output [ 2:0] funct3,             // funct3 of the instruction in Memory (access size / sign)
    output [31:0] Mem_WrAddr, Mem_WrData,
    input  [31:0] ReadData,
    // Writeback-stage values the testbench watches
    output [31:0] Result,
    output [31:0] PCW, ALUResultW, WriteDataW
);

// Fetch
wire [31:0] PCNext, PCPlus4F;
// Decode
wire [31:0] PCD, RD1D, RD2D, ImmExtD;
// Execute
wire [31:0] RD1E, RD2E, ImmExtE, PCE;
wire [ 4:0] Rs1E, Rs2E, RdE;
wire [ 2:0] funct3E;
wire        RegWriteE, MemWriteE, JumpE, JalrE, BranchE, ALUSrcE, MulDivE;
wire [ 1:0] ResultSrcE, ASelE;
wire [ 3:0] ALUControlE;
wire [31:0] SrcAFwd, SrcA, WriteDataE, SrcB, ALUOutE, MulDivResultE, ALUResultE;
wire [31:0] PCBranchE, PCTargetE;
wire        Zero, LT, LTU, TakeBranch, PCSrcE, DivStallE;
// Memory
wire [31:0] ALUResultM, WriteDataM, PCM;
wire [ 4:0] RdM;
wire        RegWriteM, MemWriteM;
wire [ 1:0] ResultSrcM;
wire [ 2:0] funct3M;
// Writeback
wire [31:0] ReadDataW, PCPlus4W, ResultW;
wire [ 4:0] RdW;
wire        RegWriteW;
wire [ 1:0] ResultSrcW;

// Hazard unit
wire       StallF, StallD, StallE, FlushD, FlushE, FlushM;
wire [1:0] ForwardAE, ForwardBE;   // 00 = register file, 01 = ResultW, 10 = ALUResultM

hazard_unit hu (
    .Rs1D(InstrD[19:15]), .Rs2D(InstrD[24:20]),
    .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE),
    .RdM(RdM), .RdW(RdW),
    .RegWriteM(RegWriteM), .RegWriteW(RegWriteW),
    .ResultSrcE0(ResultSrcE[0]),
    .PCSrcE(PCSrcE),
    .DivStallE(DivStallE),
    .ForwardAE(ForwardAE), .ForwardBE(ForwardBE),
    .StallF(StallF), .StallD(StallD), .StallE(StallE),
    .FlushD(FlushD), .FlushE(FlushE), .FlushM(FlushM)
);

// FETCH
// A taken branch / jump in Execute (PCSrcE) sends the PC to the new target.
mux2 #(32)     pcmux   (PCPlus4F, PCTargetE, PCSrcE, PCNext);
reset_ff #(32) pcreg   (clk, reset, StallF, PCNext, PC);
adder          pcadd4  (PC, 32'd4, PCPlus4F);

// During reset only bubbles enter the pipeline. Without this, the first instruction is
// fetched again every reset cycle and those copies still finish after reset ends.
pl_reg_fd plfd (clk, StallD, FlushD | reset, Instr, PC,
                InstrD, PCD);

// DECODE
// The register file passes a Writeback value straight through when Decode reads the
// same register in the same cycle (see reg_file.v).
reg_file       rf  (clk, RegWriteW, InstrD[19:15], InstrD[24:20], RdW, ResultW, RD1D, RD2D);
imm_extend     ext (InstrD[31:7], ImmSrcD, ImmExtD);

pl_reg_de plde (
    .clk(clk), .clr(FlushE), .stall(StallE),
    .RD1D(RD1D), .RD2D(RD2D), .ImmExtD(ImmExtD), .PCD(PCD),
    .Rs1D(InstrD[19:15]), .Rs2D(InstrD[24:20]), .RdD(InstrD[11:7]), .funct3D(InstrD[14:12]),
    .RegWriteD(RegWriteD), .MemWriteD(MemWriteD), .JumpD(JumpD), .JalrD(JalrD),
    .BranchD(BranchD), .ALUSrcD(ALUSrcD), .MulDivD(MulDivD),
    .ResultSrcD(ResultSrcD), .ASelD(ASelD), .ALUControlD(ALUControlD),
    .RD1E(RD1E), .RD2E(RD2E), .ImmExtE(ImmExtE), .PCE(PCE),
    .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE), .funct3E(funct3E),
    .RegWriteE(RegWriteE), .MemWriteE(MemWriteE), .JumpE(JumpE), .JalrE(JalrE),
    .BranchE(BranchE), .ALUSrcE(ALUSrcE), .MulDivE(MulDivE),
    .ResultSrcE(ResultSrcE), .ASelE(ASelE), .ALUControlE(ALUControlE)
);

// EXECUTE
// forwarding muxes (selects come from the hazard unit)
mux3 #(32)     fwdamux (RD1E, ResultW, ALUResultM, ForwardAE, SrcAFwd);
mux3 #(32)     fwdbmux (RD2E, ResultW, ALUResultM, ForwardBE, WriteDataE);   // also the store data

// ALU operand A: rs1 / PC (auipc) / 0 (lui)
mux3 #(32)     srcamux (SrcAFwd, PCE, 32'd0, ASelE, SrcA);
mux2 #(32)     srcbmux (WriteDataE, ImmExtE, ALUSrcE, SrcB);
alu            alu     (SrcA, SrcB, ALUControlE, ALUOutE, Zero, LT, LTU);

// M instructions use the forwarded register values directly, never PC or an immediate
muldiv_unit    mdu     (clk, reset, MulDivE, funct3E, SrcAFwd, WriteDataE,
                        MulDivResultE, DivStallE);
assign ALUResultE = MulDivE ? MulDivResultE : ALUOutE;

// branch / jump resolution
branching_unit bu      (funct3E, Zero, LT, LTU, TakeBranch);
adder          pcaddbranch (PCE, ImmExtE, PCBranchE);
// jalr jumps to (rs1 + imm) with bit 0 cleared; branches and jal jump to PC + imm
mux2 #(32)     jalrmux (PCBranchE, {ALUOutE[31:1], 1'b0}, JalrE, PCTargetE);
assign PCSrcE = (BranchE & TakeBranch) | JumpE;

pl_reg_em plem (
    .clk(clk), .clr(FlushM),
    .ALUResultE(ALUResultE), .WriteDataE(WriteDataE), .PCE(PCE),
    .RdE(RdE), .funct3E(funct3E),
    .RegWriteE(RegWriteE), .MemWriteE(MemWriteE), .ResultSrcE(ResultSrcE),
    .ALUResultM(ALUResultM), .WriteDataM(WriteDataM), .PCM(PCM),
    .RdM(RdM), .funct3M(funct3M),
    .RegWriteM(RegWriteM), .MemWriteM(MemWriteM), .ResultSrcM(ResultSrcM)
);

// MEMORY (data memory sits outside the CPU, ReadData comes back from it)
assign Mem_WrAddr = ALUResultM;
assign Mem_WrData = WriteDataM;
assign MemWrite   = MemWriteM;
assign funct3     = funct3M;

pl_reg_mw plmw (
    .clk(clk),
    .ALUResultM(ALUResultM), .ReadDataM(ReadData), .PCM(PCM),
    .WriteDataM(WriteDataM), .RdM(RdM), .RegWriteM(RegWriteM), .ResultSrcM(ResultSrcM),
    .ALUResultW(ALUResultW), .ReadDataW(ReadDataW), .PCW(PCW),
    .WriteDataW(WriteDataW), .RdW(RdW), .RegWriteW(RegWriteW), .ResultSrcW(ResultSrcW)
);

// WRITEBACK
// 00 = ALU result, 01 = load data, 10 = PC + 4 (jal / jalr)
// PC + 4 is rebuilt from PCW here instead of being carried through every stage,
// which saves 4 x 32 flip-flops.
adder          pcadd4w (PCW, 32'd4, PCPlus4W);
mux3 #(32)     resultmux (ALUResultW, ReadDataW, PCPlus4W, ResultSrcW, ResultW);
assign Result = ResultW;

endmodule
