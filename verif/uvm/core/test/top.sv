// top.sv - the CPU core (riscv_cpu) with the testbench around it
// The memories are not RTL here: the imem / dmem agents answer through core_if.

// timescale comes from the command line (xrun -timescale 1ns/1ps), same for all files

module top;

    import uvm_pkg::*;
    import core_pkg::*;
    `include "uvm_macros.svh"

    bit clk = 0;
    always #5 clk = ~clk;              // 100 MHz in simulation time; only the order matters

    core_if cif (clk);

    riscv_cpu dut (
        .clk(clk), .reset(cif.reset),
        .PC(cif.PC), .Instr(cif.Instr),
        .MemWrite(cif.MemWrite), .Mem_WrAddr(cif.Mem_WrAddr), .Mem_WrData(cif.Mem_WrData),
        .ReadData(cif.ReadData), .Result(cif.Result), .funct3(cif.funct3),
        .PCW(cif.PCW), .ALUResultW(), .WriteDataW(), .PerfEvents()
    );

    initial begin
        // known values before the memory agents start answering
        cif.reset    = 1'b1;
        cif.Instr    = 32'h0;
        cif.ReadData = 32'h0;
        uvm_config_db #(virtual core_if)::set(null, "*", "cif", cif);
        // the probe was placed inside the datapath by core_probe_bind.sv
        uvm_config_db #(virtual core_probe_if)::set(null, "*", "pif", top.dut.dp.probe_i);
        run_test();
    end

endmodule
