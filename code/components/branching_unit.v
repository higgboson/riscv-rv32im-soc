
// branching_unit.v - logic for branching in execute stage
// Decides whether a branch is taken, from funct3 and the ALU compare flags.
// The ALU runs SUB for branches, so Zero <=> rs1 == rs2; LT / LTU come from its comparators.

module branching_unit (
    input [2:0] funct3,
    input       Zero, LT, LTU,
    output reg  Branch
);

always @(*) begin
    case (funct3)
        3'b000:  Branch =  Zero; // beq
        3'b001:  Branch = !Zero; // bne
        3'b100:  Branch =  LT;   // blt
        3'b101:  Branch = !LT;   // bge
        3'b110:  Branch =  LTU;  // bltu
        3'b111:  Branch = !LTU;  // bgeu
        default: Branch = 1'b0;
    endcase
end

endmodule
