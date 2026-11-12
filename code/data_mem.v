
 
// data_mem.v - data memory (byte / half / word access), built to map onto block RAM
//
// funct3 comes from the instruction in the MEMORY stage:
//   stores : 000 = SB, 001 = SH, 010 = SW
//   loads  : 000 = LB, 001 = LH, 010 = LW, 100 = LBU, 101 = LHU
//
// One RAM, ONE clock (falling edge) for both write and read, so it is a plain
// single-port block RAM:
// WRITE : at the falling edge, per-byte write enables -> no read-modify-write needed
// READ  : the word is latched at the same falling edge. The address and store data come
//         from the EX/MEM register (stable from the rising edge), so everything is ready
//         half a cycle later and the load data reaches the MEM/WB register at the next
//         rising edge. A load right after a store to the same word sees the new data,
//         because the store was written in the previous cycle.
 
module data_mem #(parameter DATA_WIDTH = 32, ADDR_WIDTH = 32, MEM_SIZE = 64) (
    input       clk, wr_en,
    input [2:0] funct3,
    input       [ADDR_WIDTH-1:0] wr_addr, wr_data,
    output reg  [DATA_WIDTH-1:0] rd_data_mem
);
 
// Four separate byte-wide arrays (one per byte lane). Quartus only infers a block RAM with
// byte enables from this style; a part-select write like data_ram[addr][7:0] <= ...
// is NOT recognised and the whole array is built from flip-flops.
reg [7:0] mem0 [0:MEM_SIZE-1];   // bits  7: 0
reg [7:0] mem1 [0:MEM_SIZE-1];   // bits 15: 8
reg [7:0] mem2 [0:MEM_SIZE-1];   // bits 23:16
reg [7:0] mem3 [0:MEM_SIZE-1];   // bits 31:24
 
integer i;
initial begin
    for (i = 0; i < MEM_SIZE; i = i + 1) begin
        mem0[i] = 0; mem1[i] = 0; mem2[i] = 0; mem3[i] = 0;
    end
end
 
wire [5:0] word_addr = wr_addr[7:2];      // = (byte address / 4) mod 64
wire [1:0] byte_off  = wr_addr[1:0];
 
// ---------------- store: byte enables + replicated store data ----------------
reg [3:0]  be;
reg [31:0] wdata;
 
always @(*) begin
    case (funct3[1:0])
        2'b00: begin                                  // sb
            be    = 4'b0001 << byte_off;
            wdata = {4{wr_data[7:0]}};
        end
        2'b01: begin                                  // sh
            be    = byte_off[1] ? 4'b1100 : 4'b0011;
            wdata = {2{wr_data[15:0]}};
        end
        default: begin                                // sw
            be    = 4'b1111;
            wdata = wr_data;
        end
    endcase
end
 
// one clock edge for write and read -> plain single-port block RAM per lane
reg [31:0] q;
 
always @(negedge clk) begin
    if (wr_en && be[0]) mem0[word_addr] <= wdata[ 7: 0];
    q[ 7: 0] <= mem0[word_addr];
end
always @(negedge clk) begin
    if (wr_en && be[1]) mem1[word_addr] <= wdata[15: 8];
    q[15: 8] <= mem1[word_addr];
end
always @(negedge clk) begin
    if (wr_en && be[2]) mem2[word_addr] <= wdata[23:16];
    q[23:16] <= mem2[word_addr];
end
always @(negedge clk) begin
    if (wr_en && be[3]) mem3[word_addr] <= wdata[31:24];
    q[31:24] <= mem3[word_addr];
end
 
// ---------------- load: registered word read, then pick byte/half and extend ----------------
reg [7:0]  rd_byte;
reg [15:0] rd_half;
 
always @(*) begin
    case (byte_off)
        2'b00:   rd_byte = q[ 7: 0];
        2'b01:   rd_byte = q[15: 8];
        2'b10:   rd_byte = q[23:16];
        default: rd_byte = q[31:24];
    endcase
    rd_half = byte_off[1] ? q[31:16] : q[15:0];
 
    case (funct3)
        3'b000:  rd_data_mem = {{24{rd_byte[7]}},  rd_byte}; // lb
        3'b001:  rd_data_mem = {{16{rd_half[15]}}, rd_half}; // lh
        3'b100:  rd_data_mem = {24'b0, rd_byte};             // lbu
        3'b101:  rd_data_mem = {16'b0, rd_half};             // lhu
        default: rd_data_mem = q;                            // lw (and don't-care for non-loads)
    endcase
end
 
endmodule