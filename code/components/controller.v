
// controller.v - controller for pipelined RISC-V CPU (DECODE stage only)
//
// Branch conditions (BEQ/BNE/BLT/BGE/BLTU/BGEU) are NOT decided here any more:
// the branch is resolved in EXECUTE, so Branch + funct3 travel down the pipeline
// and the branching unit in Execute combines them with the ALU flags.

module controller (
    input [6:0]  op,
    input [2:0]  funct3,
    input        funct7b5,
    output       [1:0] ResultSrc,
    output       MemWrite,
    output       ALUSrc,
    output       RegWrite, Branch, Jump, Jalr,
    output [2:0] ImmSrc,
    output [3:0] ALUControl,
    output [1:0] ASel              // ALU operand A: 00 = rs1, 01 = PC (auipc), 10 = zero (lui)
);

wire [1:0] ALUOp;

main_decoder    md (op, ResultSrc, MemWrite, Branch,
                    ALUSrc, RegWrite, Jump, ImmSrc, ALUOp);

alu_decoder     ad (op[5], funct3, funct7b5, ALUOp, ALUControl);

// JALR: Jump = 1 from the decoder; Jalr tells Execute to use the ALU result (rs1 + imm) as target
assign Jalr = (op == 7'b1100111);

// LUI = 0 + imm,  AUIPC = PC + imm : both go through the ALU as ADD
assign ASel = (op == 7'b0110111) ? 2'b10 :
              (op == 7'b0010111) ? 2'b01 : 2'b00;

endmodule
