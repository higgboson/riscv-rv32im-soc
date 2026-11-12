// branching_unit.v - decides whether a branch is taken, in the Execute stage
//
// It has its own comparator, fed straight from the forwarded rs1 / rs2 values.
// Before, branches went through the ALU input muxes and the ALU subtract, and that chain,
// plus the flush it triggers, was the slowest path in the CPU. Branches always compare
// rs1 with rs2, so they never need the ALU's operand muxes.
// Equality is a plain bit-by-bit compare, so it does not wait for a subtract's carry chain.

module branching_unit (
    input      [2:0]  funct3,
    input      [31:0] a, b,      // rs1, rs2 after forwarding
    output reg        Branch
);

wire eq  = (a == b);
wire lt  = ($signed(a) < $signed(b));
wire ltu = (a < b);

always @(*) begin
    case (funct3)
        3'b000:  Branch =  eq;   // beq
        3'b001:  Branch = !eq;   // bne
        3'b100:  Branch =  lt;   // blt
        3'b101:  Branch = !lt;   // bge
        3'b110:  Branch =  ltu;  // bltu
        3'b111:  Branch = !ltu;  // bgeu
        default: Branch = 1'b0;
    endcase
end

endmodule
