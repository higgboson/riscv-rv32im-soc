// pipeline registers -> memory | writeback stage (MEM/WB)
// PCW and WriteDataW are carried only for the testbench probes (PCW, WriteDataW).

module pl_reg_mw (
    input             clk,
    input      [31:0] ALUResultM, ReadDataM, PCM, WriteDataM,
    input      [ 4:0] RdM,
    input             RegWriteM,
    input      [ 1:0] ResultSrcM,
    output reg [31:0] ALUResultW, ReadDataW, PCW, WriteDataW,
    output reg [ 4:0] RdW,
    output reg        RegWriteW,
    output reg [ 1:0] ResultSrcW
);

initial begin
    ALUResultW = 0; ReadDataW = 0; PCW = 0; WriteDataW = 0;
    RdW = 0; RegWriteW = 0; ResultSrcW = 0;
end

always @(posedge clk) begin
    ALUResultW <= ALUResultM; ReadDataW <= ReadDataM;
    PCW <= PCM; WriteDataW <= WriteDataM;
    RdW <= RdM; RegWriteW <= RegWriteM; ResultSrcW <= ResultSrcM;
end

endmodule