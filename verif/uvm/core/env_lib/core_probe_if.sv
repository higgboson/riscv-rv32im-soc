// core_probe_if.sv - a look inside the pipeline, bound into the datapath (core_probe_bind.sv)
//
// The commit monitor reads the Writeback stage here (which register is written, with what),
// and the pipe monitor reads the hazard and branch-prediction signals for coverage.
// The checks at the bottom (SVA) run in every test. They state rules the pipeline must
// always follow, independent of the program it runs.

interface core_probe_if (
    input logic        clk, reset,
    // Writeback: what the CPU commits
    input logic        RegWriteW, ValidW,
    input logic [ 4:0] RdW,
    input logic [31:0] ResultW, PCW,
    // fetch
    input logic [31:0] PC,
    input logic        ValidD,
    // hazard unit
    input logic [ 1:0] ForwardAE, ForwardBE,
    input logic        StallF, StallD, StallE, FlushD, FlushE, FlushM,
    // Execute stage
    input logic        ValidE, BranchE, JumpE, JalrE, MulDivE, MemWriteE,
    input logic [ 1:0] ResultSrcE,
    input logic [ 2:0] funct3E,
    input logic [ 4:0] Rs1E, Rs2E, RdE,
    input logic        DivStallE, MispredictE, PredE, TakenE
);

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    clocking mon_cb @(posedge clk);
        default input #1step;
        input reset, RegWriteW, ValidW, RdW, ResultW, PCW, ForwardAE, ForwardBE,
              StallF, StallD, StallE, FlushD, FlushE, FlushM, ValidE, BranchE, JumpE, JalrE,
              MulDivE, MemWriteE, ResultSrcE, funct3E, Rs1E, Rs2E, RdE,
              DivStallE, MispredictE, PredE, TakenE;
    endclocking

    modport MON (clocking mon_cb);

    // A committed register value must never be unknown
    a_commit_known : assert property (@(posedge clk) disable iff (reset)
        (RegWriteW && RdW != 0) |-> !$isunknown(ResultW))
        else `uvm_error("SVA", $sformatf("unknown value written to x%0d (pc %h)", RdW, PCW))

    // Holding Execute (divide) must also hold everything behind it
    a_stall_order : assert property (@(posedge clk) disable iff (reset)
        StallE |-> (StallD && StallF))
        else `uvm_error("SVA", "Execute is held but Fetch / Decode are not")

    // An instruction held in Execute must never be flushed at the same time
    a_hold_not_flush : assert property (@(posedge clk) disable iff (reset)
        !(StallE && FlushE))
        else `uvm_error("SVA", "Execute held and flushed in the same cycle")

    // A divide holds the pipeline for at most 33 cycles (1 load + 32 steps)
    a_div_length : assert property (@(posedge clk) disable iff (reset)
        $rose(DivStallE) |-> ##[1:34] !DivStallE)
        else `uvm_error("SVA", "divide stall lasted more than 34 cycles")

    // A wrong guess throws away the two younger instructions in the next cycle
    a_mispredict_flush : assert property (@(posedge clk) disable iff (reset)
        (MispredictE && ValidE) |=> (!ValidD && !ValidE))
        else `uvm_error("SVA", "a mispredicted branch did not flush Decode and Execute")

    // Instructions are 4-byte aligned, so the fetch PC must always be
    a_pc_aligned : assert property (@(posedge clk) disable iff (reset)
        PC[1:0] == 2'b00)
        else `uvm_error("SVA", $sformatf("misaligned fetch PC %h", PC))

    // Bubbles never write registers
    a_bubble_quiet : assert property (@(posedge clk) disable iff (reset)
        !ValidW |-> !RegWriteW)
        else `uvm_error("SVA", "a bubble in Writeback wrote a register")

endinterface
