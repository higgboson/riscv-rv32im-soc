// accel_if.sv - the accelerator's register bus, as the CPU sees it
//
// The DUT reads combinationally (rd_data follows addr), so it has no read strobe.
// rd_en exists only in the testbench: the driver raises it on its reads so the monitor
// knows which cycles are real reads. busy is the DUT's internal flag, tied in top.sv,
// so the monitor and the checks below can see run boundaries.

interface accel_if (input bit clk);

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    logic        reset = 1'b1;          // known from time 0, before the driver starts
    logic        wr_en = 1'b0, rd_en = 1'b0;
    logic [31:0] addr, wr_data, rd_data;
    logic        busy;

    // drive 1 ns after the edge, so every value is stable long before the DUT samples it
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output reset, wr_en, rd_en, addr, wr_data;
        input  rd_data;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input reset, wr_en, rd_en, addr, wr_data, rd_data, busy;
    endclocking

    modport DRV (clocking drv_cb);
    modport MON (clocking mon_cb);

    // Checks (SVA). They hold for any sequence, so they run in every test.

    wire ctrl_wr  = wr_en && addr[9:8] == 2'd0;
    wire start_ok = ctrl_wr && wr_data[8] && !busy;   // the DUT ignores starts while busy

    // A run is exactly K + 6 cycles: K feed steps, 3 skew and 3 hop cycles to PE(3,3).
`ifndef VERILATOR
    // n counts down once per busy cycle and must be 0 when busy drops
    property p_run_length;
        int n;
        @(posedge clk) disable iff (reset)
        (start_ok, n = wr_data[6:0] + 6) |=> (busy, n = n - 1) [*1:$] ##1 (!busy && n == 0);
    endproperty
`else
    // (no property local variables in that simulator) count the busy cycles in a register
    logic [7:0] run_k, run_n;
    always @(posedge clk)
        if (start_ok) begin run_k <= 8'(wr_data[6:0]); run_n <= 0; end
        else if (busy) run_n <= run_n + 1;
    property p_run_length;
        @(posedge clk) disable iff (reset) $fell(busy) |-> run_n == run_k + 6;
    endproperty
`endif
    a_run_length: assert property (p_run_length)
        else `uvm_error("SVA", "a run did not take K + 6 cycles")

    // the buffers feed the array during a run, so software must not change them then
    a_no_operand_write: assert property (@(posedge clk) disable iff (reset)
        busy |-> !(wr_en && addr[9:8] inside {2'd1, 2'd2}))
        else `uvm_error("SVA", "A / B buffer written while busy")

    a_reset_idle: assert property (@(posedge clk) reset |=> !busy)
        else `uvm_error("SVA", "busy right after reset")

    a_ctrl_known: assert property (@(posedge clk) disable iff (reset)
        !$isunknown({wr_en, rd_en}))
        else `uvm_error("SVA", "X on wr_en / rd_en")

    a_addr_known: assert property (@(posedge clk) disable iff (reset)
        (wr_en || rd_en) |-> !$isunknown(addr) && (!wr_en || !$isunknown(wr_data)))
        else `uvm_error("SVA", "X on addr / wr_data during an access")

    a_read_known: assert property (@(posedge clk) disable iff (reset)
        rd_en |-> !$isunknown(rd_data))
        else `uvm_error("SVA", $sformatf("X read from address %h", addr))

    // interesting situations, reported in the assertion coverage
    c_start_while_busy: cover property (@(posedge clk) ctrl_wr && wr_data[8] && busy);
    c_back_to_back:     cover property (@(posedge clk) $fell(busy) ##[1:24] start_ok);
    c_k_max:            cover property (@(posedge clk) start_ok && wr_data[6:0] == 7'd64);
    c_k_min:            cover property (@(posedge clk) start_ok && wr_data[6:0] == 7'd1);

endinterface
