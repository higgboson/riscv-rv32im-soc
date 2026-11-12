// instr_mem.v - instruction memory, built to map onto block RAM (16 KB by default)
//
// Block RAM can only be read on a clock edge. The read happens on the FALLING edge:
// the PC changes at the rising edge, the word is read half a cycle later, and it is
// ready for the IF/ID register at the next rising edge. So Fetch still takes one
// cycle, same as with the old combinational ROM, but now a large program fits in
// RAM blocks instead of using thousands of logic cells.
//
// The program is loaded from imem.hex (one 32-bit word per line). The software build
// in sw/ writes this file.

module instr_mem #(parameter WORDS = 4096) (
    input             clk,
    input      [31:0] instr_addr,
    output reg [31:0] instr
);

localparam AW = $clog2(WORDS);

reg [31:0] instr_ram [0:WORDS-1];

// instr starts at 0 so the first rising edge after power-up does not load an unknown
// value into IF/ID (the RAM has not been read yet at that point). 0 decodes as a bubble.
initial begin
    $readmemh("imem.hex", instr_ram);
    instr = 32'b0;
end

// instructions are word aligned, so the low 2 address bits are not used
always @(negedge clk) begin
    instr <= instr_ram[instr_addr[AW+1:2]];
end

endmodule
