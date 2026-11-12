
// alu.v - ALU module

module alu #(parameter WIDTH = 32) (
    input       [WIDTH-1:0] a, b,       // operands
    input       [3:0] alu_ctrl,         //  3 -> 4 bits (10 operations now)
    output reg  [WIDTH-1:0] alu_out,    // ALU output
    output      zero,                   // zero flag (used by BEQ / BNE)
    output      lt,                     //  signed   a < b (BLT / BGE)
    output      ltu                     //  unsigned a < b (BLTU / BGEU)
);

// Shift amount: only the low 5 bits count. For register shifts this is rs2[4:0];
// for SLLI/SRLI/SRAI the immediate's low 5 bits are the shamt.
wire [4:0] shamt = b[4:0];

// Comparators defined ONCE and shared: they drive the SLT/SLTU results below
// AND the lt/ltu flags that the controller uses for branches (saves logic elements).
assign lt  = ($signed(a) < $signed(b));   // signed compare 
assign ltu = (a < b);                     // unsigned compare

always @(*) begin
    case (alu_ctrl)
        4'b0000: alu_out = a + b;                        // ADD, ADDI
        4'b0001: alu_out = a + ~b + 1;                   // SUB
        4'b0010: alu_out = a & b;                        // AND, ANDI
        4'b0011: alu_out = a | b;                        // OR, ORI
        4'b0100: alu_out = a ^ b;                        // XOR, XORI        
        4'b0101: alu_out = {{(WIDTH-1){1'b0}}, lt};      // SLT, SLTI        
        4'b0110: alu_out = {{(WIDTH-1){1'b0}}, ltu};     // SLTU, SLTIU      
        4'b0111: alu_out = a << shamt;                   // SLL, SLLI        
        4'b1000: alu_out = a >> shamt;                   // SRL, SRLI (logical)     
        4'b1001: alu_out = $signed(a) >>> shamt;         // SRA, SRAI (arithmetic)  
        default: alu_out = 0;
    endcase
end

// For branches the ALU runs SUB, so zero <=> rs1 == rs2
assign zero = (alu_out == 0) ? 1'b1 : 1'b0;

endmodule



