
// hazard_unit.v - combinational hazard unit (no clock, no state)
//
//  1. Data hazards    : forward ALUResultM / ResultW back to the ALU inputs in Execute
//  2. Load-use hazard : a load in Execute whose Rd is a source of the instruction in Decode
//                       -> stall Fetch + Decode one cycle, bubble into Execute
//  3. Control hazard  : branch / jump taken in Execute -> flush the two wrong-path
//                       instructions (one in Decode, one just fetched)

module hazard_unit (
    input  [4:0] Rs1D, Rs2D,          // sources of the instruction in Decode
    input  [4:0] Rs1E, Rs2E, RdE,     // sources / destination of the instruction in Execute
    input  [4:0] RdM,  RdW,           // destinations in Memory / Writeback
    input        RegWriteM, RegWriteW,
    input        ResultSrcE0,         // ResultSrcE[0] = 1 -> instruction in Execute is a load
    input        PCSrcE,              // branch / jump taken in Execute
    output reg [1:0] ForwardAE, ForwardBE,   // 00 = register file, 01 = ResultW, 10 = ALUResultM
    output       StallF, StallD,
    output       FlushD, FlushE
);

// ---------------- forwarding (Memory has priority: it holds the newer value) ----------------
always @(*) begin
    if      (RegWriteM && (RdM != 5'd0) && (RdM == Rs1E)) ForwardAE = 2'b10;
    else if (RegWriteW && (RdW != 5'd0) && (RdW == Rs1E)) ForwardAE = 2'b01;
    else                                                  ForwardAE = 2'b00;

    if      (RegWriteM && (RdM != 5'd0) && (RdM == Rs2E)) ForwardBE = 2'b10;
    else if (RegWriteW && (RdW != 5'd0) && (RdW == Rs2E)) ForwardBE = 2'b01;
    else                                                  ForwardBE = 2'b00;
end

// ---------------- load-use stall ----------------
wire lwStall = ResultSrcE0 && (RdE != 5'd0) && ((Rs1D == RdE) || (Rs2D == RdE));

assign StallF = lwStall;
assign StallD = lwStall;

// ---------------- flushes ----------------
assign FlushD = PCSrcE;
assign FlushE = lwStall | PCSrcE;

endmodule
