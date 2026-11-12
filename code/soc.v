// soc.v - the complete system: CPU + instruction memory + data memory + memory-mapped I/O
// Board-independent. Each FPGA board has its own small top file that adds the clock,
// pins and display (see fpga/).

module soc #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input         clk, reset,
    // data memory access from outside while reset is held (used by the e-Yantra testbench)
    input         Ext_MemWrite,
    input  [31:0] Ext_WriteData, Ext_DataAdr,
    // debug view of the Memory and Writeback stages (testbenches)
    output        MemWrite,
    output [31:0] WriteData, DataAdr, ReadData,
    output [31:0] PCW, Result, ALUResultW, WriteDataW,
    // board I/O
    output [15:0] leds,
    output [19:0] hex,
    input  [15:0] switches,
    input  [ 3:0] buttons,
    input         uart_rx,
    output        uart_tx,
    output [31:0] tohost,
    output        tohost_valid
);

wire [31:0] Instr, PC;
wire [31:0] DataAdr_rv32, WriteData_rv32;
wire [ 2:0] Store, funct3;
wire        MemWrite_rv32;
wire [31:0] dmem_rdata, mmio_rdata;
wire [ 3:0] perf_events;

riscv_cpu rvcpu    (clk, reset, PC, Instr,
                    MemWrite_rv32, DataAdr_rv32,
                    WriteData_rv32, ReadData, Result,
                    funct3, PCW, ALUResultW, WriteDataW, perf_events);

instr_mem instrmem (clk, PC, Instr);

// Top 4 address bits = 0x1 -> I/O. Everything else -> data memory.
wire is_mmio = (DataAdr[31:28] == 4'h1);

data_mem  datamem  (clk, MemWrite & ~is_mmio, Store, DataAdr, WriteData, dmem_rdata);

mmio #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) io (
    .clk(clk), .reset(reset),
    .wr_en(MemWrite & is_mmio), .addr(DataAdr), .wr_data(WriteData),
    .perf_events(perf_events), .rd_data(mmio_rdata),
    .leds(leds), .hex(hex), .switches(switches), .buttons(buttons),
    .uart_rx(uart_rx), .uart_tx(uart_tx),
    .tohost(tohost), .tohost_valid(tohost_valid)
);

assign ReadData  = is_mmio ? mmio_rdata : dmem_rdata;

assign Store     = (Ext_MemWrite && reset) ? 3'b010 : funct3;
assign MemWrite  = (Ext_MemWrite && reset) ? 1'b1 : MemWrite_rv32;
assign WriteData = (Ext_MemWrite && reset) ? Ext_WriteData : WriteData_rv32;
assign DataAdr   = reset ? Ext_DataAdr : DataAdr_rv32;

endmodule
