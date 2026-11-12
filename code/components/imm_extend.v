// imm_extend.v - logic for sign extension
module imm_extend (
    input  [31:7]     instr,
    input  [ 2:0]     immsrc,//immsrc changed to 3 bit width(8 combinations possible) to accomodate  5 instructionsformats
    output reg [31:0] immext
);

always @(*) begin
    case(immsrc)
        // I−type
        3'b000:   immext = {{20{instr[31]}}, instr[31:20]};
        // S−type (stores)
        3'b001:   immext = {{20{instr[31]}}, instr[31:25], instr[11:7]};
        // B−type (branches)
        3'b010:   immext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
        // J−type (jal)
        3'b011:   immext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
         // U-type (upper immediate) unlike the previous  4  instructions , in this instruction the  immediate value is  shoved into the upper 20 bit chunk , 
			// so we lock  the  upper  20 bit of the instruction into upper 20  bit of the 32 bit chunk , and rest are padded to 0
		  3'b100:   immext = {instr[31:12], 12'b0};
        default: immext = 32'bx; // undefined
    endcase
end

endmodule
