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
    output [31:0] PCW, ALUResultW, WriteDataW,
    // one pulse per event, counted by the performance counters in mmio.v
    output [ 3:0] PerfEvents          // {mispredict, jump, branch, retire}
);

// Fetch
wire [31:0] PCNext, PCPlus4F, PredTargetF, PCFetchNext;
wire        PredF;
// Decode
wire [31:0] PCD, RD1D, RD2D, ImmExtD;
wire        ValidD, PredD;
// Execute
wire [31:0] RD1E, RD2E, ImmExtE, PCE;
wire [ 4:0] Rs1E, Rs2E, RdE;
wire [ 2:0] funct3E;
wire        RegWriteE, MemWriteE, JumpE, JalrE, BranchE, ALUSrcE, MulDivE;
wire        ValidE, PredE;
wire [ 1:0] ResultSrcE, ASelE;
wire [ 3:0] ALUControlE;
wire [31:0] SrcAFwd, SrcA, WriteDataE, SrcB, ALUOutE, MulDivResultE, ALUResultE;
wire [31:0] PCBranchE, JalrTargetE, PCTargetE, PCPlus4E, RedirectPCE;
wire        Zero, LT, LTU;                                  // ALU flags are unused now
wire        TakeBranch, TakenE, MispredictE, DivStallE;
// Memory
wire [31:0] ALUResultM, WriteDataM, PCM;
wire [ 4:0] RdM;
wire        RegWriteM, MemWriteM, ValidM;
wire [ 1:0] ResultSrcM;
wire [ 2:0] funct3M;
// Writeback
wire [31:0] ReadDataW, LoadDataW, PCPlus4W, ResultW;
wire [ 4:0] RdW;
wire [ 2:0] funct3W;
wire        RegWriteW, ValidW;
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
    .MispredictE(MispredictE),
    .DivStallE(DivStallE),
    .ForwardAE(ForwardAE), .ForwardBE(ForwardBE),
    .StallF(StallF), .StallD(StallD), .StallE(StallE),
    .FlushD(FlushD), .FlushE(FlushE), .FlushM(FlushM)
);

// FETCH
// Next PC, highest priority first:
//   1. Execute found a wrong guess -> go to the correct address (RedirectPCE)
//   2. the predictor says this PC is a taken branch / jal -> go to its stored target
//   3. otherwise PC + 4
adder          pcadd4  (PC, 32'd4, PCPlus4F);

`ifdef NO_BPRED
// Prediction switched off (used to measure the speedup): always guess "not taken"
assign PredF = 1'b0;
assign PredTargetF = 32'b0;
`else
branch_predictor bp (
    .clk(clk), .reset(reset),
    .pc_f(PC), .pred_taken_f(PredF), .pred_target_f(PredTargetF),
    // learn from every branch and jal in Execute (jalr is not stored, see branch_predictor.v)
    .update(ValidE & (BranchE | (JumpE & ~JalrE))),
    .pc_e(PCE), .taken_e(TakenE), .target_e(PCBranchE)
);
`endif

mux2 #(32)     predmux (PCPlus4F, PredTargetF, PredF, PCFetchNext);
mux2 #(32)     pcmux   (PCFetchNext, RedirectPCE, MispredictE, PCNext);
reset_ff #(32) pcreg   (clk, reset, StallF, PCNext, PC);

// During reset only bubbles enter the pipeline. Without this, the first instruction is
// fetched again every reset cycle and those copies still finish after reset ends.
pl_reg_fd plfd (clk, StallD, FlushD | reset, Instr, PC, PredF,
                InstrD, PCD, ValidD, PredD);

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
    .ValidD(ValidD), .PredD(PredD),
    .ResultSrcD(ResultSrcD), .ASelD(ASelD), .ALUControlD(ALUControlD),
    .RD1E(RD1E), .RD2E(RD2E), .ImmExtE(ImmExtE), .PCE(PCE),
    .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE), .funct3E(funct3E),
    .RegWriteE(RegWriteE), .MemWriteE(MemWriteE), .JumpE(JumpE), .JalrE(JalrE),
    .BranchE(BranchE), .ALUSrcE(ALUSrcE), .MulDivE(MulDivE),
    .ValidE(ValidE), .PredE(PredE),
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
// The branch compare and the jalr adder take the forwarded register values directly
// instead of going through the ALU. This is the path that sets the clock speed:
// forward -> decide the branch -> pick the new PC / flush. Skipping the ALU's input
// muxes and operation select makes it shorter.
branching_unit bu      (funct3E, SrcAFwd, WriteDataE, TakeBranch);
adder          pcaddbranch (PCE, ImmExtE, PCBranchE);
adder          jalradd (SrcAFwd, ImmExtE, JalrTargetE);
// jalr jumps to (rs1 + imm) with bit 0 cleared; branches and jal jump to PC + imm
mux2 #(32)     jalrmux (PCBranchE, {JalrTargetE[31:1], 1'b0}, JalrE, PCTargetE);
assign TakenE = (BranchE & TakeBranch) | JumpE;

// Check the guess made in Fetch (PredE):
//   guessed taken, really taken     -> right, the target was already fetched
//   guessed not taken, not taken    -> right, PC + 4 was already fetched
//   any other case                  -> wrong: flush Fetch / Decode and go to the right PC
// A taken guess always used the right target: only branches and jal are stored, and their
// target is PC + offset, which is the same every time. jalr is never stored, but if it ever
// had a taken guess it is redirected anyway, to be safe.
assign MispredictE = (PredE != TakenE) | (PredE & JalrE);
adder          pcadd4e (PCE, 32'd4, PCPlus4E);
mux2 #(32)     redirmux (PCPlus4E, PCTargetE, TakenE, RedirectPCE);

pl_reg_em plem (
    .clk(clk), .clr(FlushM),
    .ALUResultE(ALUResultE), .WriteDataE(WriteDataE), .PCE(PCE),
    .RdE(RdE), .funct3E(funct3E),
    .RegWriteE(RegWriteE), .MemWriteE(MemWriteE), .ValidE(ValidE), .ResultSrcE(ResultSrcE),
    .ALUResultM(ALUResultM), .WriteDataM(WriteDataM), .PCM(PCM),
    .RdM(RdM), .funct3M(funct3M),
    .RegWriteM(RegWriteM), .MemWriteM(MemWriteM), .ValidM(ValidM), .ResultSrcM(ResultSrcM)
);

// MEMORY (data memory sits outside the CPU, ReadData comes back from it as a whole word)
assign Mem_WrAddr = ALUResultM;
assign Mem_WrData = WriteDataM;
assign MemWrite   = MemWriteM;
assign funct3     = funct3M;

pl_reg_mw plmw (
    .clk(clk),
    .ALUResultM(ALUResultM), .ReadDataM(ReadData), .PCM(PCM),
    .WriteDataM(WriteDataM), .RdM(RdM), .funct3M(funct3M), .RegWriteM(RegWriteM), .ValidM(ValidM), .ResultSrcM(ResultSrcM),
    .ALUResultW(ALUResultW), .ReadDataW(ReadDataW), .PCW(PCWr),
    .WriteDataW(WriteDataW), .RdW(RdW), .funct3W(funct3W), .RegWriteW(RegWriteW), .ValidW(ValidW), .ResultSrcW(ResultSrcW)
);

// WRITEBACK
// A bubble keeps the PC of the instruction before it (flushes clear only the control
// bits), so the PCW output is shown as 0 for bubbles, as before. Testbenches that watch
// PCW then never see one PC twice.
wire [31:0] PCWr;
assign PCW = ValidW ? PCWr : 32'b0;
// memory returns a whole word; cut out the byte / half the load wanted
load_extend    lext    (ReadDataW, funct3W, ALUResultW[1:0], LoadDataW);

// 00 = ALU result, 01 = load data, 10 = PC + 4 (jal / jalr)
// PC + 4 is rebuilt from PCW here instead of being carried through every stage,
// which saves 4 x 32 flip-flops.
adder          pcadd4w (PCWr, 32'd4, PCPlus4W);
mux3 #(32)     resultmux (ALUResultW, LoadDataW, PCPlus4W, ResultSrcW, ResultW);
assign Result = ResultW;

// Performance events. Only divides ever wait in Execute, so each branch / jump is
// in Execute for exactly one cycle and is counted once. They are registered: the
// counters do not care about one cycle of delay, and a direct output from the
// mispredict logic was the slowest path of the chip layout.
reg [3:0] perf_q = 4'b0;
always @(posedge clk)
    if (reset) perf_q <= 4'b0;
    else       perf_q <= {ValidE & MispredictE, ValidE & JumpE, ValidE & BranchE, ValidW};
assign PerfEvents = perf_q;

endmodule
