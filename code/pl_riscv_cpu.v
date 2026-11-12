// pl_riscv_cpu.v - top level: CPU + instruction memory + data memory + memory-mapped I/O
//
// The ports are kept the same as the original e-Yantra version so its testbench still works.
// Ext_* lets a testbench write data memory while reset is held.

module pl_riscv_cpu (
    input         clk, reset,
    input         Ext_MemWrite,
    input  [31:0] Ext_WriteData, Ext_DataAdr,
    output        MemWrite,
    output [31:0] WriteData, DataAdr, ReadData,
    output [31:0] PCW, Result, ALUResultW, WriteDataW
);

wire [31:0] Instr, PC;
wire [31:0] DataAdr_rv32, WriteData_rv32;
wire [ 2:0] Store, funct3;
wire        MemWrite_rv32;
wire [31:0] dmem_rdata, mmio_rdata;
wire [ 7:0] leds;
wire [31:0] tohost;
wire        tohost_valid;
wire [ 3:0] perf_events;

riscv_cpu rvcpu    (clk, reset, PC, Instr,
                    MemWrite_rv32, DataAdr_rv32,
                    WriteData_rv32, ReadData, Result,
                    funct3, PCW, ALUResultW, WriteDataW, perf_events);

instr_mem instrmem (clk, PC, Instr);

// Top 4 address bits = 0x1 -> I/O. Everything else -> data memory.
wire is_mmio = (DataAdr[31:28] == 4'h1);

data_mem  datamem  (clk, MemWrite & ~is_mmio, Store, DataAdr, WriteData, dmem_rdata);
mmio      io       (clk, reset, MemWrite & is_mmio, DataAdr, WriteData, perf_events,
                    mmio_rdata, leds, tohost, tohost_valid);

assign ReadData  = is_mmio ? mmio_rdata : dmem_rdata;

assign Store     = (Ext_MemWrite && reset) ? 3'b010 : funct3;
assign MemWrite  = (Ext_MemWrite && reset) ? 1'b1 : MemWrite_rv32;
assign WriteData = (Ext_MemWrite && reset) ? Ext_WriteData : WriteData_rv32;
assign DataAdr   = reset ? Ext_DataAdr : DataAdr_rv32;

endmodule
