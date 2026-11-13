// core_probe_bind.sv - puts core_probe_if inside every datapath instance, without
// touching the RTL. The names on the right are signals inside code/components/datapath.v.

bind datapath core_probe_if probe_i (
    .clk(clk), .reset(reset),
    .RegWriteW(RegWriteW), .ValidW(ValidW), .RdW(RdW), .ResultW(ResultW), .PCW(PCW),
    .PC(PC), .ValidD(ValidD),
    .ForwardAE(ForwardAE), .ForwardBE(ForwardBE),
    .StallF(StallF), .StallD(StallD), .StallE(StallE),
    .FlushD(FlushD), .FlushE(FlushE), .FlushM(FlushM),
    .ValidE(ValidE), .BranchE(BranchE), .JumpE(JumpE), .JalrE(JalrE), .MulDivE(MulDivE),
    .MemWriteE(MemWriteE), .ResultSrcE(ResultSrcE), .funct3E(funct3E),
    .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE),
    .DivStallE(DivStallE), .MispredictE(MispredictE), .PredE(PredE), .TakenE(TakenE)
);
