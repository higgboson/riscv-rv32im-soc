// muldiv_unit.v - RV32M multiply / divide unit, sits in the Execute stage
//
// Multiply (mul, mulh, mulhsu, mulhu) finishes in the same cycle, like the ALU.
// The FPGA has hard multiplier blocks, so a full 32x32 multiply is cheap there.
//
// Divide (div, divu, rem, remu) takes 33 cycles. It finds one quotient bit per cycle
// (restoring division), which needs only one subtractor instead of 32 of them.
// While it works, `stall` freezes the front of the pipeline.

module muldiv_unit (
    input             clk, reset,
    input             valid,        // an M instruction is in Execute
    input      [2:0]  funct3,       // which M instruction
    input      [31:0] a, b,         // rs1, rs2 after forwarding
    output     [31:0] result,
    output            stall         // 1 while a divide is still running
);

wire is_div = funct3[2];

// Multiply
// Add one extra top bit to each operand so one signed multiplier handles every case:
// the bit is a copy of the sign bit for a signed operand and 0 for an unsigned one.
//   mulh   : signed   x signed
//   mulhsu : signed   x unsigned
//   mulhu  : unsigned x unsigned
//   mul    : low 32 bits are the same either way
wire a_signed = (funct3[1:0] != 2'b11);
wire b_signed = (funct3[1:0] == 2'b01);

wire signed [32:0] mul_a = {a_signed & a[31], a};
wire signed [32:0] mul_b = {b_signed & b[31], b};
wire signed [65:0] product = mul_a * mul_b;

wire [31:0] mul_result = (funct3[1:0] == 2'b00) ? product[31:0] : product[63:32];

// Divide
// Work on positive numbers and fix the signs at the end:
//   quotient is negative if the operand signs differ
//   remainder takes the sign of the dividend
reg        busy, done;
reg [5:0]  count;
reg [31:0] quo, rem, divisor, dividend_saved;
reg        neg_quo, neg_rem, div_by_zero;

// known power-up state, same as the pipeline registers
initial begin
    busy = 0;
    done = 0;
end

wire div_signed = ~funct3[0];                // div, rem are signed; divu, remu are not
wire a_neg = div_signed & a[31];
wire b_neg = div_signed & b[31];
wire [31:0] a_mag = a_neg ? -a : a;
wire [31:0] b_mag = b_neg ? -b : b;

// One step: bring the next dividend bit into the remainder and try to subtract the divisor
wire [32:0] rem_shift = {rem, quo[31]};
wire [32:0] rem_try   = rem_shift - {1'b0, divisor};
wire        fits      = ~rem_try[32];        // no borrow -> divisor fits, quotient bit is 1

// Start only once per instruction. `done` stops a restart in the cycle the result is used.
wire start = valid & is_div & ~busy & ~done;

always @(posedge clk) begin
    if (reset) begin
        busy <= 0;
        done <= 0;
    end else if (start) begin
        // Save the operands now. They come through the forwarding muxes, which are only
        // right in this first cycle: the instructions ahead move on while we stall.
        quo            <= a_mag;
        rem            <= 0;
        divisor        <= b_mag;
        dividend_saved <= a;
        neg_quo        <= a_neg ^ b_neg;
        neg_rem        <= a_neg;
        div_by_zero    <= (b == 0);
        count          <= 6'd32;
        busy           <= 1;
    end else if (busy) begin
        rem   <= fits ? rem_try[31:0] : rem_shift[31:0];
        quo   <= {quo[30:0], fits};
        count <= count - 1'b1;
        if (count == 6'd1) begin
            busy <= 0;
            done <= 1;
        end
    end else begin
        // the divide leaves Execute in the cycle after `done`, so clear it here
        done <= 0;
    end
end

// RISC-V defines divide by zero instead of trapping: quotient = all ones, remainder = dividend.
// Overflow (-2^31 / -1) needs no special case, the sign fix already gives the right answer.
wire [31:0] div_quo = div_by_zero ? 32'hFFFF_FFFF : (neg_quo ? -quo : quo);
wire [31:0] div_rem = div_by_zero ? dividend_saved : (neg_rem ? -rem : rem);

assign result = is_div ? (funct3[1] ? div_rem : div_quo) : mul_result;
assign stall  = valid & is_div & ~done;

endmodule
