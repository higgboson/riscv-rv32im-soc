// top.sv - the matrix-multiply accelerator with its UVM testbench

module top;

    import uvm_pkg::*;
    import accel_pkg::*;
    `include "uvm_macros.svh"

    bit clk = 0;
    always #5 clk = ~clk;

    accel_if aif (clk);

    matmul_accel dut (
        .clk(clk), .reset(aif.reset), .wr_en(aif.wr_en),
        .addr(aif.addr), .wr_data(aif.wr_data), .rd_data(aif.rd_data),
        // the gather engine is not used here (verif/tb_accel.v tests it with a memory model)
        .mem_addr(), .mem_rdata(32'b0)
    );

    // busy is internal; the monitor and the checks in accel_if need it
    assign aif.busy = dut.busy;

    initial begin
        uvm_config_db #(virtual accel_if)::set(null, "*", "vif", aif);
        run_test();
    end

endmodule
