// pl_reg_de.v - pipeline register between Decode and Execute (ID/EX)
// clr   : turn the instruction into a bubble. Every field goes to 0, so it cannot
//         write a register, write memory or change the PC.
// stall : keep the instruction in Execute (a divide is still running)

module pl_reg_de (
    input             clk, clr, stall,
    input      [31:0] RD1D, RD2D, ImmExtD, PCD,
    input      [ 4:0] Rs1D, Rs2D, RdD,
    input      [ 2:0] funct3D,
    input             RegWriteD, MemWriteD, JumpD, JalrD, BranchD, ALUSrcD, MulDivD,
    input      [ 1:0] ResultSrcD, ASelD,
    input      [ 3:0] ALUControlD,
    output reg [31:0] RD1E, RD2E, ImmExtE, PCE,
    output reg [ 4:0] Rs1E, Rs2E, RdE,
    output reg [ 2:0] funct3E,
    output reg        RegWriteE, MemWriteE, JumpE, JalrE, BranchE, ALUSrcE, MulDivE,
    output reg [ 1:0] ResultSrcE, ASelE,
    output reg [ 3:0] ALUControlE
);

initial begin
    RD1E = 0; RD2E = 0; ImmExtE = 0; PCE = 0;
    Rs1E = 0; Rs2E = 0; RdE = 0; funct3E = 0;
    RegWriteE = 0; MemWriteE = 0; JumpE = 0; JalrE = 0; BranchE = 0; ALUSrcE = 0; MulDivE = 0;
    ResultSrcE = 0; ASelE = 0; ALUControlE = 0;
end

always @(posedge clk) begin
    if (clr) begin
        RD1E <= 0; RD2E <= 0; ImmExtE <= 0; PCE <= 0;
        Rs1E <= 0; Rs2E <= 0; RdE <= 0; funct3E <= 0;
        RegWriteE <= 0; MemWriteE <= 0; JumpE <= 0; JalrE <= 0; BranchE <= 0; ALUSrcE <= 0;
        MulDivE <= 0; ResultSrcE <= 0; ASelE <= 0; ALUControlE <= 0;
    end else if (!stall) begin
        RD1E <= RD1D; RD2E <= RD2D; ImmExtE <= ImmExtD; PCE <= PCD;
        Rs1E <= Rs1D; Rs2E <= Rs2D; RdE <= RdD; funct3E <= funct3D;
        RegWriteE <= RegWriteD; MemWriteE <= MemWriteD; JumpE <= JumpD; JalrE <= JalrD;
        BranchE <= BranchD; ALUSrcE <= ALUSrcD; MulDivE <= MulDivD;
        ResultSrcE <= ResultSrcD; ASelE <= ASelD; ALUControlE <= ALUControlD;
    end
end

endmodule
