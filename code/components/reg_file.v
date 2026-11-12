
// reg_file.v - register file for the pipelined RISC-V CPU, built to map onto block RAM
//              (32 registers x 32 bits, two read ports, one write port, x0 reads as 0)
//
// WRITE : synchronous at the rising edge (end of the Writeback cycle).
// READ  : each read port is a RAM that latches its word at the FALLING edge; the read
//         addresses come from IF/ID (stable from the rising edge), so the data is ready
//         for the ID/EX register at the next rising edge.
// BYPASS: an instruction in Decode that reads the register Writeback is writing in the
//         same cycle gets the Writeback value directly (the RAM still holds the old one).
//         This is the "third forwarding path from Writeback into Decode".

module reg_file #(parameter DATA_WIDTH = 32) (
    input       clk,
    input       wr_en,
    input       [4:0] rd_addr1, rd_addr2, wr_addr,
    input       [DATA_WIDTH-1:0] wr_data,
    output      [DATA_WIDTH-1:0] rd_data1, rd_data2
);

// two copies of the array, one per read port (a RAM block has one read port)
reg [DATA_WIDTH-1:0] ram1 [0:31];
reg [DATA_WIDTH-1:0] ram2 [0:31];

integer i;
initial begin
    for (i = 0; i < 32; i = i + 1) begin
        ram1[i] = 0;
        ram2[i] = 0;
    end
end

// write (a write to x0 lands in the RAM but is never visible: x0 is masked on read)
always @(posedge clk) begin
    if (wr_en) begin
        ram1[wr_addr] <= wr_data;
        ram2[wr_addr] <= wr_data;
    end
end

// read (falling edge)
reg [DATA_WIDTH-1:0] q1, q2;
always @(negedge clk) begin
    q1 <= ram1[rd_addr1];
    q2 <= ram2[rd_addr2];
end

// x0 = 0, Writeback -> Decode bypass, otherwise the RAM output
assign rd_data1 = (rd_addr1 == 5'd0)                  ? {DATA_WIDTH{1'b0}} :
                  (wr_en && (wr_addr == rd_addr1))    ? wr_data : q1;
assign rd_data2 = (rd_addr2 == 5'd0)                  ? {DATA_WIDTH{1'b0}} :
                  (wr_en && (wr_addr == rd_addr2))    ? wr_data : q2;

endmodule
