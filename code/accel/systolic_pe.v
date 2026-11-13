// systolic_pe.v - one processing element (PE) of the systolic array
//
// Every cycle it multiplies the two INT8 values passing through it and adds the product
// to its own 32-bit sum (output-stationary: each PE owns one element of C).
// The A value is passed on to the right and the B value down, one cycle later, so the
// neighbours get them on the next cycle. No PE ever reads memory: data only moves
// between neighbours, which is what makes a systolic array small and fast.

module systolic_pe (
    input                    clk,
    input                    clear,        // start a new result: sum = 0
    input      signed [7:0]  a_in, b_in,
    output reg signed [7:0]  a_out, b_out,
    output reg signed [31:0] acc
);

initial begin
    a_out = 0; b_out = 0; acc = 0;
end

always @(posedge clk) begin
    a_out <= a_in;
    b_out <= b_in;
    // a product of two INT8 values fits in 16 bits; 32 bits leave room for long sums
    acc   <= clear ? 32'sd0 : acc + a_in * b_in;
end

endmodule
