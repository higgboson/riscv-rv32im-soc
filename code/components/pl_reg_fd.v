// pl_reg_fd.v - pipeline register between Fetch and Decode (IF/ID)
// stall : keep the current instruction (load-use or divide)
// clr   : replace it with a bubble (wrong path after a taken branch)

module pl_reg_fd (
    input             clk, stall, clr,
    input      [31:0] InstrF, PCF,
    output reg [31:0] InstrD, PCD
);

initial begin
    InstrD = 0; PCD = 0;
end

always @(posedge clk) begin
    if (clr) begin
        InstrD <= 0; PCD <= 0;
    end else if (!stall) begin
        InstrD <= InstrF; PCD <= PCF;
    end
end

endmodule
