// core_pkg.sv - everything the class-based testbench needs, in dependency order

package core_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "core_defs.svh"
    `include "core_iss_dpi.svh"

    `include "rv_mem.sv"
    `include "core_items.sv"
    `include "rv_instr.sv"
    `include "rv_program.sv"
    `include "core_env_config.sv"

    `include "imem_agent.sv"
    `include "dmem_agent.sv"
    `include "core_monitors.sv"
    `include "prog_agent.sv"
    `include "prog_seqs.sv"
    `include "core_sb.sv"
    `include "core_coverage.sv"

    `include "core_env.sv"
    `include "core_test_lib.sv"

endpackage
