// hazard_unit.v - decides forwarding, stalls and flushes (pure logic, no clock)
//
//  1. Data hazard    : a result still in Memory / Writeback is forwarded to the ALU in Execute.
//  2. Load-use       : a load in Execute feeds the instruction in Decode. The data is not
//                      ready yet, so Fetch and Decode wait one cycle and a bubble goes into Execute.
//  3. Control hazard : when Execute finds the branch predictor guessed wrong, the two
//                      wrong-path instructions behind it (in Fetch and Decode) are thrown away.
//  4. Divide busy    : a divide in Execute takes many cycles. Everything behind it waits,
//                      and bubbles go into Memory so the instructions ahead can still finish.

module hazard_unit (
    input  [4:0] Rs1D, Rs2D,          // sources of the instruction in Decode
    input  [4:0] Rs1E, Rs2E, RdE,     // sources / destination of the instruction in Execute
    input  [4:0] RdM,  RdW,           // destinations in Memory / Writeback
    input        RegWriteM, RegWriteW,
    input        ResultSrcE0,         // 1 -> the instruction in Execute is a load
    input        MispredictE,         // branch / jump in Execute was guessed wrong
    input        DivStallE,           // divide in Execute is not finished
    output reg [1:0] ForwardAE, ForwardBE,   // 00 = register file, 01 = ResultW, 10 = ALUResultM
    output       StallF, StallD, StallE,
    output       FlushD, FlushE, FlushM
);

// Memory is checked first because it holds the newer value of the register
always @(*) begin
    if      (RegWriteM && (RdM != 5'd0) && (RdM == Rs1E)) ForwardAE = 2'b10;
    else if (RegWriteW && (RdW != 5'd0) && (RdW == Rs1E)) ForwardAE = 2'b01;
    else                                                  ForwardAE = 2'b00;

    if      (RegWriteM && (RdM != 5'd0) && (RdM == Rs2E)) ForwardBE = 2'b10;
    else if (RegWriteW && (RdW != 5'd0) && (RdW == Rs2E)) ForwardBE = 2'b01;
    else                                                  ForwardBE = 2'b00;
end

wire lwStall = ResultSrcE0 && (RdE != 5'd0) && ((Rs1D == RdE) || (Rs2D == RdE));

assign StallF = lwStall | DivStallE;
assign StallD = lwStall | DivStallE;
assign StallE = DivStallE;

assign FlushD = MispredictE;
// A divide is never a load or a branch, so this never clashes with StallE.
// The guard is there so a held instruction can never be wiped by mistake.
assign FlushE = (lwStall | MispredictE) & ~DivStallE;
assign FlushM = DivStallE;

endmodule
