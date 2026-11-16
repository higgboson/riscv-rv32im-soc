// ascon_round.v - one round of the Ascon permutation (pure logic, no clock)
//
// The 320-bit state is five 64-bit words x0..x4. Picture them stacked as 5 rows of 64 bits:
// each of the 64 columns is then a 5-bit value. A round does three things:
//   1. add a constant to x2, so every round is different
//   2. S-box: replace each 5-bit column by another 5-bit value. Written here as AND / XOR /
//      NOT on whole words, so all 64 columns are done at once and there is no lookup table.
//   3. diffusion: XOR each word with two rotated copies of itself, so a change in one bit
//      spreads to three bits of the word (and after a few rounds to the whole state).
//
// Rotations are just wiring in hardware, so a round costs only XOR / AND gates:
// about 5 gate levels deep. That is why several rounds fit in one clock cycle.

module ascon_round (
    input  [ 3:0] i,                    // round number, 0..11 (p12 runs 0..11, p8 runs 4..11)
    input  [63:0] x0, x1, x2, x3, x4,
    output [63:0] y0, y1, y2, y3, y4
);

// round constant: high nibble counts down from f, low nibble counts up from 0
// (f0, e1, d2, ... 4b)
wire [7:0] rc = {4'hf - i, i};

// S-box, first linear part (with the constant folded in)
wire [63:0] a0 = x0 ^ x4;
wire [63:0] a1 = x1;
wire [63:0] a2 = x2 ^ x1 ^ {56'b0, rc};
wire [63:0] a3 = x3;
wire [63:0] a4 = x4 ^ x3;

// S-box, non-linear part: the only AND gates of the whole cipher
wire [63:0] b0 = a0 ^ (~a1 & a2);
wire [63:0] b1 = a1 ^ (~a2 & a3);
wire [63:0] b2 = a2 ^ (~a3 & a4);
wire [63:0] b3 = a3 ^ (~a4 & a0);
wire [63:0] b4 = a4 ^ (~a0 & a1);

// S-box, last linear part
wire [63:0] c0 = b0 ^ b4;
wire [63:0] c1 = b1 ^ b0;
wire [63:0] c2 = ~b2;
wire [63:0] c3 = b3 ^ b2;
wire [63:0] c4 = b4;

// diffusion: x ^ (x rotated right by r1) ^ (x rotated right by r2), different r per word
assign y0 = c0 ^ {c0[18:0], c0[63:19]} ^ {c0[27:0], c0[63:28]};
assign y1 = c1 ^ {c1[60:0], c1[63:61]} ^ {c1[38:0], c1[63:39]};
assign y2 = c2 ^ {c2[ 0:0], c2[63: 1]} ^ {c2[ 5:0], c2[63: 6]};
assign y3 = c3 ^ {c3[ 9:0], c3[63:10]} ^ {c3[16:0], c3[63:17]};
assign y4 = c4 ^ {c4[ 6:0], c4[63: 7]} ^ {c4[40:0], c4[63:41]};

endmodule
