// pl_reg_mw.v - pipeline register between Memory and Writeback (MEM/WB)
// funct3W tells Writeback how to cut the loaded word (byte / half / word, signed or not).
// PCW and WriteDataW are carried only for the testbench probes.

module pl_reg_mw (
    input             clk,
    input      [31:0] ALUResultM, ReadDataM, PCM, WriteDataM,
    input      [ 4:0] RdM,
    input      [ 2:0] funct3M,
    input             RegWriteM,
    input      [ 1:0] ResultSrcM,
    output reg [31:0] ALUResultW, ReadDataW, PCW, WriteDataW,
    output reg [ 4:0] RdW,
    output reg [ 2:0] funct3W,
    output reg        RegWriteW,
    output reg [ 1:0] ResultSrcW
);

initial begin
    ALUResultW = 0; ReadDataW = 0; PCW = 0; WriteDataW = 0;
    RdW = 0; funct3W = 0; RegWriteW = 0; ResultSrcW = 0;
end

always @(posedge clk) begin
    ALUResultW <= ALUResultM; ReadDataW <= ReadDataM;
    PCW <= PCM; WriteDataW <= WriteDataM;
    RdW <= RdM; funct3W <= funct3M; RegWriteW <= RegWriteM; ResultSrcW <= ResultSrcM;
end

endmodule
