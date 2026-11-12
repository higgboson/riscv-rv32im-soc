
// pipeline registers -> fetch | decode stage
// pipeline registers -> fetch | decode stage

module pl_reg_fd (
    input             clk, en, clr,
    input      [31:0] InstrF, PCF,
    output reg [31:0] InstrD, PCD
);

initial begin
    InstrD = 0; PCD = 0;
end

always @(posedge clk) begin
    if (clr) begin
        InstrD <= 0; PCD <= 0;
    end else if (!en) begin
        InstrD <= InstrF; PCD <= PCF;
    end
end

endmodule