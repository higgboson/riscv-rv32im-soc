// pipeline registers -> execute | memory stage (EX/MEM)
// PCM is carried only so the testbench can see which instruction is in Writeback (PCW).

module pl_reg_em (
    input             clk,
    input      [31:0] ALUResultE, WriteDataE, PCE,
    input      [ 4:0] RdE,
    input      [ 2:0] funct3E,
    input             RegWriteE, MemWriteE,
    input      [ 1:0] ResultSrcE,
    output reg [31:0] ALUResultM, WriteDataM, PCM,
    output reg [ 4:0] RdM,
    output reg [ 2:0] funct3M,
    output reg        RegWriteM, MemWriteM,
    output reg [ 1:0] ResultSrcM
);

initial begin
    ALUResultM = 0; WriteDataM = 0; PCM = 0;
    RdM = 0; funct3M = 0; RegWriteM = 0; MemWriteM = 0; ResultSrcM = 0;
end

always @(posedge clk) begin
    ALUResultM <= ALUResultE; WriteDataM <= WriteDataE;
    PCM <= PCE;
    RdM <= RdE; funct3M <= funct3E;
    RegWriteM <= RegWriteE; MemWriteM <= MemWriteE; ResultSrcM <= ResultSrcE;
end

endmodule