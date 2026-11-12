// pl_reg_fd.v - pipeline register between Fetch and Decode (IF/ID)
// stall : keep the current instruction (load-use or divide)
// clr   : replace it with a bubble (wrong path after a mispredicted branch, or reset)
//
// ValidD : 1 = a real instruction, 0 = a bubble. Used to count retired instructions.
// PredD  : 1 = Fetch predicted this instruction as a taken branch / jump and already
//          fetched from the predicted target. Execute checks the guess.

module pl_reg_fd (
    input             clk, stall, clr,
    input      [31:0] InstrF, PCF,
    input             PredF,
    output reg [31:0] InstrD, PCD,
    output reg        ValidD, PredD
);

initial begin
    InstrD = 0; PCD = 0; ValidD = 0; PredD = 0;
end

always @(posedge clk) begin
    if (clr) begin
        InstrD <= 0; PCD <= 0; ValidD <= 0; PredD <= 0;
    end else if (!stall) begin
        InstrD <= InstrF; PCD <= PCF; ValidD <= 1'b1; PredD <= PredF;
    end
end

endmodule
