// pl_reg_em.v - pipeline register between Execute and Memory (EX/MEM)
// clr : put a bubble into Memory. Used while a divide holds Execute, so the
//       instructions already ahead of it are not repeated.
// PCM is carried only so the testbench can see which instruction reaches Writeback (PCW).
// ValidM marks a real instruction (for the retired-instruction counter).

module pl_reg_em (
    input             clk, clr,
    input      [31:0] ALUResultE, WriteDataE, PCE,
    input      [ 4:0] RdE,
    input      [ 2:0] funct3E,
    input             RegWriteE, MemWriteE, ValidE,
    input      [ 1:0] ResultSrcE,
    output reg [31:0] ALUResultM, WriteDataM, PCM,
    output reg [ 4:0] RdM,
    output reg [ 2:0] funct3M,
    output reg        RegWriteM, MemWriteM, ValidM,
    output reg [ 1:0] ResultSrcM
);

initial begin
    ALUResultM = 0; WriteDataM = 0; PCM = 0;
    RdM = 0; funct3M = 0; RegWriteM = 0; MemWriteM = 0; ResultSrcM = 0; ValidM = 0;
end

always @(posedge clk) begin
    if (clr) begin
        ALUResultM <= 0; WriteDataM <= 0; PCM <= 0;
        RdM <= 0; funct3M <= 0; RegWriteM <= 0; MemWriteM <= 0; ResultSrcM <= 0; ValidM <= 0;
    end else begin
        ALUResultM <= ALUResultE; WriteDataM <= WriteDataE; PCM <= PCE;
        RdM <= RdE; funct3M <= funct3E;
        RegWriteM <= RegWriteE; MemWriteM <= MemWriteE; ResultSrcM <= ResultSrcE; ValidM <= ValidE;
    end
end

endmodule
