// accel_pkg.sv - the class-based testbench, in dependency order

package accel_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "accel_defs.svh"
    `include "accel_xtn.sv"
    `include "accel_agent.sv"
    `include "accel_sb.sv"
    `include "accel_coverage.sv"
    `include "accel_seqs.sv"
    `include "accel_env.sv"
    `include "accel_test_lib.sv"

endpackage
