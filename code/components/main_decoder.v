// main_decoder.v - logic for main decoder

module main_decoder (
    input  [6:0] op,
    output [1:0] ResultSrc,
    output       MemWrite, Branch, ALUSrc,
    output       RegWrite, Jump,
    output [2:0] ImmSrc,
    output [1:0] ALUOp
);

reg [11:0] controls;

always @(*) begin
    case (op)
        // RegWrite_ImmSrc_ALUSrc_MemWrite_ResultSrc_Branch_ALUOp_Jump
        7'b0000011: controls = 12'b1_000_1_0_01_0_00_0; // lw (all loads)
        7'b0100011: controls = 12'b0_001_1_1_00_0_00_0; // sw (all stores)
        7'b0110011: controls = 12'b1_000_0_0_00_0_10_0; // R-type
        7'b1100011: controls = 12'b0_010_0_0_00_1_01_0; // branches
        7'b0010011: controls = 12'b1_000_1_0_00_0_10_0; // I-type ALU
        7'b1101111: controls = 12'b1_011_0_0_10_0_00_1; // jal
        7'b0110111: controls = 12'b1_100_1_0_00_0_00_0; // lui   (ALU: 0 + imm, ASel = 10)
        7'b0010111: controls = 12'b1_100_1_0_00_0_00_0; // auipc (ALU: PC + imm, ASel = 01)
        7'b1100111: controls = 12'b1_000_1_0_10_0_00_1; // jalr  (ResultSrc = PC+4, Jump = 1)
        default:    controls = 12'b0_000_0_0_00_0_00_0; // NOP / bubble: must NOT write or jump
    endcase
end

assign {RegWrite, ImmSrc, ALUSrc, MemWrite, ResultSrc, Branch, ALUOp, Jump} = controls;

endmodule
