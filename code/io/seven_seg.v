// seven_seg.v - drives the Basys 3 4-digit 7-segment display with a 16-bit value in hex
//
// The 4 digits share the same 7 segment lines, so only one digit is lit at a time and they
// take turns about 1,000 times a second. The eye sees all 4 lit at once.
// On the Basys 3, segments and digit enables are active low (0 = on).

module seven_seg #(parameter CLK_HZ = 50_000_000) (
    input             clk,
    input      [15:0] value,
    input      [ 3:0] dots,         // decimal point per digit, 1 = on
    output reg [ 6:0] seg,          // {g, f, e, d, c, b, a}
    output reg        dp,
    output reg [ 3:0] an
);

// change digit every ~1 ms
localparam integer REFRESH = CLK_HZ / 1000;
localparam integer CW      = $clog2(REFRESH);
localparam integer LAST_I  = REFRESH - 1;
localparam [CW-1:0] LAST   = LAST_I[CW-1:0];
reg [CW-1:0] cnt = 0;
reg [1:0] digit = 0;

always @(posedge clk) begin
    if (cnt == LAST) begin
        cnt   <= 0;
        digit <= digit + 1'b1;
    end else begin
        cnt <= cnt + 1'b1;
    end
end

reg [3:0] nibble;

always @(*) begin
    case (digit)
        2'd0:    nibble = value[ 3: 0];
        2'd1:    nibble = value[ 7: 4];
        2'd2:    nibble = value[11: 8];
        default: nibble = value[15:12];
    endcase
    an = ~(4'b0001 << digit);
    dp = ~dots[digit];

    case (nibble)                     // gfedcba, 0 = segment on
        4'h0: seg = 7'b1000000;
        4'h1: seg = 7'b1111001;
        4'h2: seg = 7'b0100100;
        4'h3: seg = 7'b0110000;
        4'h4: seg = 7'b0011001;
        4'h5: seg = 7'b0010010;
        4'h6: seg = 7'b0000010;
        4'h7: seg = 7'b1111000;
        4'h8: seg = 7'b0000000;
        4'h9: seg = 7'b0010000;
        4'hA: seg = 7'b0001000;
        4'hB: seg = 7'b0000011;
        4'hC: seg = 7'b1000110;
        4'hD: seg = 7'b0100001;
        4'hE: seg = 7'b0000110;
        default: seg = 7'b0001110;    // F
    endcase
end

endmodule
