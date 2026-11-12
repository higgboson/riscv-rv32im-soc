// load_extend.v - picks the byte / half a load asked for out of the 32-bit memory word,
// then sign- or zero-extends it. Used in Writeback.
//
// This used to sit right after the data memory, in the Memory stage. The memory is read on
// the falling edge, so that logic only had half a clock cycle, and it was the slowest path
// in the CPU (57 MHz). In Writeback it has a full cycle.

module load_extend (
    input      [31:0] word,       // whole word read from memory
    input      [ 2:0] funct3,     // 000 lb, 001 lh, 010 lw, 100 lbu, 101 lhu
    input      [ 1:0] byte_off,   // low address bits: which byte / half in the word
    output reg [31:0] data
);

reg [ 7:0] b;
reg [15:0] h;

always @(*) begin
    case (byte_off)
        2'b00:   b = word[ 7: 0];
        2'b01:   b = word[15: 8];
        2'b10:   b = word[23:16];
        default: b = word[31:24];
    endcase
    h = byte_off[1] ? word[31:16] : word[15:0];

    case (funct3)
        3'b000:  data = {{24{b[7]}},  b};   // lb
        3'b001:  data = {{16{h[15]}}, h};   // lh
        3'b100:  data = {24'b0, b};         // lbu
        3'b101:  data = {16'b0, h};         // lhu
        default: data = word;               // lw
    endcase
end

endmodule
