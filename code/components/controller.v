// controller.v - control unit, works on the instruction in Decode
//
// Branch conditions are not decided here. Branches resolve in Execute, so Branch and
// funct3 travel down the pipeline and the branching unit there uses the ALU flags.

module controller (
    input [6:0]  op,
    input [2:0]  funct3,
    input        funct7b5,
    input        funct7b0,
    output       [1:0] ResultSrc,
    output       MemWrite,
    output       ALUSrc,
    output       RegWrite, Branch, Jump, Jalr,
    output [2:0] ImmSrc,
    output [3:0] ALUControl,
    output [1:0] ASel,             // ALU operand A: 00 = rs1, 01 = PC (auipc), 10 = zero (lui)
    output       MulDiv            // RV32M instruction: result comes from the mul/div unit
);

wire [1:0] ALUOp;

main_decoder    md (op, ResultSrc, MemWrite, Branch,
                    ALUSrc, RegWrite, Jump, ImmSrc, ALUOp);

alu_decoder     ad (op[5], funct3, funct7b5, ALUOp, ALUControl);

// JALR: the decoder already sets Jump. Jalr tells Execute to jump to rs1 + imm instead of PC + imm.
assign Jalr = (op == 7'b1100111);

// LUI = 0 + imm, AUIPC = PC + imm. Both reuse the ALU adder.
assign ASel = (op == 7'b0110111) ? 2'b10 :
              (op == 7'b0010111) ? 2'b01 : 2'b00;

// M instructions are R-type with funct7 = 0000001. In RV32IM no other R-type
// instruction sets bit 0 of funct7, so checking that one bit is enough.
// The main decoder already treats them as R-type (register write, ALU result).
assign MulDiv = (op == 7'b0110011) & funct7b0;

endmodule
