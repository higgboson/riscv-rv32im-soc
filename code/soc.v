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
    output        tohost_valid,
    output        loading,              // the UART loader is receiving a program
    // 2.4" SPI TFT (code/io/tft_spi.v)
    output        tft_cs, tft_rst, tft_dc, tft_mosi, tft_sck, tft_led
);

wire [31:0] Instr, PC;
wire [31:0] DataAdr_rv32, WriteData_rv32;
wire [ 2:0] Store, funct3;
wire        MemWrite_rv32;
wire [31:0] dmem_rdata, mmio_rdata;
wire [ 3:0] perf_events;

// UART program loader. While it receives a program (or after a failed one) the CPU and
// its I/O registers are held in reset. The UART itself only resets with the board.
wire        ld_active, ld_hold, ld_imem_we, ld_dmem_we, ld_tx_we;
wire [12:0] ld_waddr;
wire [31:0] ld_wdata;
wire [ 7:0] ld_tx_data, rx_byte;
wire        rx_byte_valid;

uart_loader #(.AW(13)) loader (                  // 13 bits: 8K words of data memory
    .clk(clk), .reset(reset),
    .rx_valid(rx_byte_valid), .rx_data(rx_byte),
    .active(ld_active), .hold(ld_hold),
    .imem_we(ld_imem_we), .dmem_we(ld_dmem_we), .waddr(ld_waddr), .wdata(ld_wdata),
    .tx_we(ld_tx_we), .tx_data(ld_tx_data)
);

wire core_reset = reset | ld_active | ld_hold;
assign loading  = ld_active;

riscv_cpu rvcpu    (clk, core_reset, PC, Instr,
                    MemWrite_rv32, DataAdr_rv32,
                    WriteData_rv32, ReadData, Result,
                    funct3, PCW, ALUResultW, WriteDataW, perf_events);

instr_mem instrmem (clk, PC, Instr, ld_imem_we, ld_waddr[11:0], ld_wdata);

// Top 4 address bits: 0x1 -> I/O, 0x2 -> matrix accelerator, 0x3 -> TFT display,
// anything else -> data memory
wire is_mmio  = (DataAdr[31:28] == 4'h1);
wire is_accel = (DataAdr[31:28] == 4'h2);
wire is_tft   = (DataAdr[31:28] == 4'h3);
wire [31:0] tft_rdata;
wire [31:0] accel_rdata, accel_mem_addr, accel_mem_data, accel_mem_wdata;
wire [3:0]  accel_mem_we;

// 32 KB of data memory (8K words, 0x0001_0000 .. 0x0001_7FFF)
data_mem #(.WORDS(8192)) datamem (clk, MemWrite & ~is_mmio & ~is_accel & ~is_tft, Store, DataAdr, WriteData, dmem_rdata,
                    accel_mem_addr, accel_mem_data, accel_mem_we, accel_mem_wdata);

matmul_accel accel (
    .clk(clk), .reset(core_reset),
    .wr_en(MemWrite & is_accel), .addr(DataAdr), .wr_data(WriteData),
    .rd_data(accel_rdata),
    .mem_addr(accel_mem_addr), .mem_rdata(accel_mem_data),
    .mem_we(accel_mem_we), .mem_wdata(accel_mem_wdata)
);

mmio #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) io (
    .clk(clk), .reset(core_reset), .uart_reset(reset),
    .wr_en(MemWrite & is_mmio), .addr(DataAdr), .wr_data(WriteData),
    .perf_events(perf_events), .rd_data(mmio_rdata),
    .leds(leds), .hex(hex), .switches(switches), .buttons(buttons),
    .uart_rx(uart_rx), .uart_tx(uart_tx),
    .rx_byte_valid(rx_byte_valid), .rx_byte(rx_byte),
    .tx_ext_we(ld_tx_we), .tx_ext_data(ld_tx_data),
    .tohost(tohost), .tohost_valid(tohost_valid)
);

tft_spi tft (
    .clk(clk), .reset(core_reset),
    .wr_en(MemWrite & is_tft), .addr(DataAdr), .wr_data(WriteData), .rd_data(tft_rdata),
    .tft_cs(tft_cs), .tft_rst(tft_rst), .tft_dc(tft_dc), .tft_mosi(tft_mosi),
    .tft_sck(tft_sck), .tft_led(tft_led)
);

assign ReadData  = is_mmio ? mmio_rdata : is_accel ? accel_rdata : is_tft ? tft_rdata : dmem_rdata;

// While the CPU is in reset, data memory can be written from outside: by a testbench
// (Ext_*, e-Yantra) or by the loader. CPU stores are blocked then, so a store that was
// still in the pipeline when the loader started cannot land on the loader's address.
wire        ext_wr   = (Ext_MemWrite && reset) | ld_dmem_we;
wire [31:0] ext_addr = ld_active ? {17'b0, ld_waddr, 2'b00} : Ext_DataAdr;
wire [31:0] ext_data = ld_active ? ld_wdata : Ext_WriteData;

assign Store     = ext_wr ? 3'b010 : funct3;
assign MemWrite  = ext_wr ? 1'b1 : (MemWrite_rv32 & ~core_reset);
assign WriteData = ext_wr ? ext_data : WriteData_rv32;
assign DataAdr   = core_reset ? ext_addr : DataAdr_rv32;

endmodule
