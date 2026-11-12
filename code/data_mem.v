// data_mem.v - data memory with byte / half / word stores, built to map onto block RAM
//
// funct3 comes from the store in the Memory stage: 000 = SB, 001 = SH, 010 = SW.
// Loads always read the whole word (see the end of this file).
//
// Read and write both happen on the FALLING edge, so it is a plain single-port block RAM.
// Address and store data come from the EX/MEM register (stable from the rising edge), so they
// are ready half a cycle later, and the load data reaches MEM/WB at the next rising edge.
// A load right after a store to the same word sees the new data, because the store was
// written one cycle earlier.
//
// Only the low address bits are used, so the memory repeats across the address space.
// The software puts data at 0x0001_0000, which lands at offset 0 here.
// Accesses must be aligned (no misaligned loads / stores).

module data_mem #(parameter WORDS = 4096) (
    input        clk, wr_en,
    input  [2:0] funct3,
    input  [31:0] wr_addr, wr_data,
    output reg [31:0] rd_data_mem
);

localparam AW = $clog2(WORDS);

// One byte-wide array per byte lane. Quartus only builds a block RAM with byte enables
// from this style. Writing a part-select like data_ram[addr][7:0] makes it use flip-flops.
reg [7:0] mem0 [0:WORDS-1];   // bits  7: 0
reg [7:0] mem1 [0:WORDS-1];   // bits 15: 8
reg [7:0] mem2 [0:WORDS-1];   // bits 23:16
reg [7:0] mem3 [0:WORDS-1];   // bits 31:24

// Starting contents (global variables, constant tables). The software build writes
// these four files, one per byte lane.
initial begin
    $readmemh("dmem0.hex", mem0);
    $readmemh("dmem1.hex", mem1);
    $readmemh("dmem2.hex", mem2);
    $readmemh("dmem3.hex", mem3);
end

wire [AW-1:0] word_addr = wr_addr[AW+1:2];
wire [1:0]    byte_off  = wr_addr[1:0];

// Store: pick the byte enables and copy the store data into every lane it could go to
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

// Loads return the whole word. Picking the byte / half and extending it is done later,
// in Writeback (load_extend.v), where there is a full clock cycle for it.
always @(*) rd_data_mem = q;

endmodule
