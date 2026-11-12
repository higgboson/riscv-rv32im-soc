// datapath.v - 5-stage pipelined datapath (IF | ID | EX | MEM | WB)
// Signal suffix = stage the value lives in: F, D, E, M, W.
module datapath (
    input         clk, reset,
    // control signals generated in DECODE (controller, fed from InstrD)
    input [1:0]   ResultSrcD,
    input         MemWriteD, ALUSrcD, RegWriteD,
    input         BranchD, JumpD, JalrD,
    input [2:0]   ImmSrcD,
    input [3:0]   ALUControlD,
    input [1:0]   ASelD,
    output [31:0] InstrD,             // to the controller
    // instruction memory
    output [31:0] PC,
    input  [31:0] Instr,
    // data memory (MEMORY stage)
    output        MemWrite,
    output [ 2:0] funct3,             // funct3 of the instruction in MEMORY (access size / sign)
    output [31:0] Mem_WrAddr, Mem_WrData,
    input  [31:0] ReadData,
    // WRITEBACK-stage probes used by the testbench
    output [31:0] Result,
    output [31:0] PCW, ALUResultW, WriteDataW
);

// ------------------------------------------------------------------
// wires, grouped by stage
// ------------------------------------------------------------------
// Fetch
wire [31:0] PCNext, PCPlus4F;
// Decode
wire [31:0] PCD, RD1D, RD2D, ImmExtD;
// Execute
wire [31:0] RD1E, RD2E, ImmExtE, PCE;
wire [ 4:0] Rs1E, Rs2E, RdE;
wire [ 2:0] funct3E;
wire        RegWriteE, MemWriteE, JumpE, JalrE, BranchE, ALUSrcE;
wire [ 1:0] ResultSrcE, ASelE;
wire [ 3:0] ALUControlE;
wire [31:0] SrcAFwd, SrcA, WriteDataE, SrcB, ALUResultE;
wire [31:0] PCBranchE, PCTargetE;
wire        Zero, LT, LTU, TakeBranch, PCSrcE;
// Memory
wire [31:0] ALUResultM, WriteDataM, PCM;
wire [ 4:0] RdM;
wire        RegWriteM, MemWriteM;
wire [ 1:0] ResultSrcM;
wire [ 2:0] funct3M;
// Writeback
wire [31:0] ReadDataW, PCPlus4W, ResultW;   // PCPlus4W = PCW + 4 (not pipelined)
wire [ 4:0] RdW;
wire        RegWriteW;
wire [ 1:0] ResultSrcW;

// ------------------------------------------------------------------
// hazard-unit signals (driven by hazard_unit below)
// ------------------------------------------------------------------
wire       StallF, StallD, FlushD, FlushE;
wire [1:0] ForwardAE, ForwardBE;   // 00 = register file, 01 = ResultW, 10 = ALUResultM

hazard_unit hu (
    .Rs1D(InstrD[19:15]), .Rs2D(InstrD[24:20]),
    .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE),
    .RdM(RdM), .RdW(RdW),
    .RegWriteM(RegWriteM), .RegWriteW(RegWriteW),
    .ResultSrcE0(ResultSrcE[0]),
    .PCSrcE(PCSrcE),
    .ForwardAE(ForwardAE), .ForwardBE(ForwardBE),
    .StallF(StallF), .StallD(StallD),
    .FlushD(FlushD), .FlushE(FlushE)
);

// ==================================================================
// FETCH
// ==================================================================
// PCSrcE comes from EXECUTE: a taken branch / jump redirects the PC.
mux2 #(32)     pcmux   (PCPlus4F, PCTargetE, PCSrcE, PCNext);
reset_ff #(32) pcreg   (clk, reset, StallF, PCNext, PC);
adder          pcadd4  (PC, 32'd4, PCPlus4F);

// ---------------- Pipeline register 1: Fetch | Decode ----------------
pl_reg_fd plfd (clk, StallD, FlushD, Instr, PC,
                InstrD, PCD);

// ==================================================================
// DECODE
// ==================================================================
// register file writes on the falling edge, so a Writeback in this cycle is seen here
reg_file       rf  (clk, RegWriteW, InstrD[19:15], InstrD[24:20], RdW, ResultW, RD1D, RD2D);
imm_extend     ext (InstrD[31:7], ImmSrcD, ImmExtD);

// ---------------- Pipeline register 2: Decode | Execute ----------------
pl_reg_de plde (
    .clk(clk), .clr(FlushE),
    .RD1D(RD1D), .RD2D(RD2D), .ImmExtD(ImmExtD), .PCD(PCD),
    .Rs1D(InstrD[19:15]), .Rs2D(InstrD[24:20]), .RdD(InstrD[11:7]), .funct3D(InstrD[14:12]),
    .RegWriteD(RegWriteD), .MemWriteD(MemWriteD), .JumpD(JumpD), .JalrD(JalrD),
    .BranchD(BranchD), .ALUSrcD(ALUSrcD), .ResultSrcD(ResultSrcD), .ASelD(ASelD),
    .ALUControlD(ALUControlD),
    .RD1E(RD1E), .RD2E(RD2E), .ImmExtE(ImmExtE), .PCE(PCE),
    .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE), .funct3E(funct3E),
    .RegWriteE(RegWriteE), .MemWriteE(MemWriteE), .JumpE(JumpE), .JalrE(JalrE),
    .BranchE(BranchE), .ALUSrcE(ALUSrcE), .ResultSrcE(ResultSrcE), .ASelE(ASelE),
    .ALUControlE(ALUControlE)
);

// ==================================================================
// EXECUTE
// ==================================================================
// forwarding muxes (selects come from the hazard unit)
mux3 #(32)     fwdamux (RD1E, ResultW, ALUResultM, ForwardAE, SrcAFwd);
mux3 #(32)     fwdbmux (RD2E, ResultW, ALUResultM, ForwardBE, WriteDataE);   // WriteDataE = forwarded rs2 (store data)

// ALU operand A: rs1 / PC (auipc) / 0 (lui)
mux3 #(32)     srcamux (SrcAFwd, PCE, 32'd0, ASelE, SrcA);
mux2 #(32)     srcbmux (WriteDataE, ImmExtE, ALUSrcE, SrcB);
alu            alu     (SrcA, SrcB, ALUControlE, ALUResultE, Zero, LT, LTU);

// branch / jump resolution
branching_unit bu      (funct3E, Zero, LT, LTU, TakeBranch);
adder          pcaddbranch (PCE, ImmExtE, PCBranchE);
// jalr target = (rs1 + imm) with bit 0 cleared; branches and jal use PC + imm
mux2 #(32)     jalrmux (PCBranchE, {ALUResultE[31:1], 1'b0}, JalrE, PCTargetE);
assign PCSrcE = (BranchE & TakeBranch) | JumpE;

// ---------------- Pipeline register 3: Execute | Memory ----------------
pl_reg_em plem (
    .clk(clk),
    .ALUResultE(ALUResultE), .WriteDataE(WriteDataE), .PCE(PCE),
    .RdE(RdE), .funct3E(funct3E),
    .RegWriteE(RegWriteE), .MemWriteE(MemWriteE), .ResultSrcE(ResultSrcE),
    .ALUResultM(ALUResultM), .WriteDataM(WriteDataM), .PCM(PCM),
    .RdM(RdM), .funct3M(funct3M),
    .RegWriteM(RegWriteM), .MemWriteM(MemWriteM), .ResultSrcM(ResultSrcM)
);

// ==================================================================
// MEMORY  (data_mem sits outside the CPU; ReadData is its output)
// ==================================================================
assign Mem_WrAddr = ALUResultM;
assign Mem_WrData = WriteDataM;
assign MemWrite   = MemWriteM;
assign funct3     = funct3M;

// ---------------- Pipeline register 4: Memory | Writeback ----------------
pl_reg_mw plmw (
    .clk(clk),
    .ALUResultM(ALUResultM), .ReadDataM(ReadData), .PCM(PCM),
    .WriteDataM(WriteDataM), .RdM(RdM), .RegWriteM(RegWriteM), .ResultSrcM(ResultSrcM),
    .ALUResultW(ALUResultW), .ReadDataW(ReadDataW), .PCW(PCW),
    .WriteDataW(WriteDataW), .RdW(RdW), .RegWriteW(RegWriteW), .ResultSrcW(ResultSrcW)
);

// ==================================================================
// WRITEBACK
// ==================================================================
// 00 = ALU result, 01 = load data, 10 = PC + 4 (jal / jalr)
// PC+4 for jal/jalr is rebuilt from PCW (already carried for the testbench probe)
// instead of pipelining a separate PCPlus4 through D/E/M/W (saves 4 x 32 registers)
adder          pcadd4w (PCW, 32'd4, PCPlus4W);
mux3 #(32)     resultmux (ALUResultW, ReadDataW, PCPlus4W, ResultSrcW, ResultW);
assign Result = ResultW;

endmodule