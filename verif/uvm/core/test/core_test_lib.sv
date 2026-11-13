// core_test_lib.sv - the tests. Pick one with +UVM_TESTNAME=<name> (see sim/Makefile).
//
//   core_rand_test       random programs with the default mix
//   core_hazard_test     dense dependencies: most sources are recent destinations
//   core_branch_test     branch, jump and loop heavy (branch predictor)
//   core_muldiv_test     multiply / divide heavy, many corner-case operands
//   core_riscv_tests     the official riscv-tests (rv32ui + rv32um) inside UVM
//
// The specialised tests use the factory: they replace rv_program by an extended class
// with different knob constraints, so the sequence and the rest of the testbench stay the
// same. Number of programs: +NPROG=<n> (default 20).

class core_base_test extends uvm_test;
    `uvm_component_utils(core_base_test)

    core_env        env;
    core_env_config cfg;
    int unsigned    n_programs = 20;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        cfg = core_env_config::type_id::create("cfg");
        if (!uvm_config_db #(virtual core_if)::get(this, "", "cif", cfg.cif))
            `uvm_fatal("CFG", "no core_if in config_db")
        if (!uvm_config_db #(virtual core_probe_if)::get(this, "", "pif", cfg.pif))
            `uvm_fatal("CFG", "no core_probe_if in config_db")
        void'($value$plusargs("NPROG=%d", n_programs));
        uvm_config_db #(core_env_config)::set(this, "*", "cfg", cfg);
        env = core_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_root::get().print_topology();
    endfunction

    virtual task run_programs();
        rand_prog_seq seq = rand_prog_seq::type_id::create("seq");
        seq.n_programs = n_programs;
        seq.start(env.prog_agt.seqr);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_programs();
        phase.drop_objection(this);
    endtask

    // one clear line at the end, easy to grep in a regression
    function void report_phase(uvm_phase phase);
        uvm_report_server svr = uvm_report_server::get_server();
        int errors = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
        if (errors == 0)
            `uvm_info("RESULT", $sformatf("TEST PASSED: %s", get_type_name()), UVM_NONE)
        else
            `uvm_info("RESULT", $sformatf("TEST FAILED: %s (%0d errors)", get_type_name(), errors), UVM_NONE)
    endfunction

endclass

class core_rand_test extends core_base_test;
    `uvm_component_utils(core_rand_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

// Extended programs: same generator, different knobs

class rv_program_hazard extends rv_program;
    `uvm_object_utils(rv_program_hazard)
    constraint c_hazard { hazard_pct inside {[85:95]}; special_pct inside {[20:40]}; }
    constraint c_mix    { w_alu    inside {[25:40]}; w_muldiv inside {[8:15]};
                          w_upper  inside {[1:3]};   w_load   inside {[15:25]};
                          w_store  inside {[10:15]}; w_branch inside {[5:10]};
                          w_jal    inside {[1:3]};   w_jalr   inside {[1:3]};
                          w_loop   inside {[1:3]}; }
    function new(string name = "rv_program_hazard"); super.new(name); endfunction
endclass

class rv_program_branchy extends rv_program;
    `uvm_object_utils(rv_program_branchy)
    constraint c_mix { w_alu    inside {[15:25]}; w_muldiv inside {[2:5]};
                       w_upper  inside {[1:3]};   w_load   inside {[5:10]};
                       w_store  inside {[5:10]};  w_branch inside {[25:35]};
                       w_jal    inside {[8:12]};  w_jalr   inside {[6:10]};
                       w_loop   inside {[10:15]}; }
    function new(string name = "rv_program_branchy"); super.new(name); endfunction
endclass

class rv_program_muldiv extends rv_program;
    `uvm_object_utils(rv_program_muldiv)
    constraint c_hazard { hazard_pct inside {[60:80]}; special_pct inside {[40:60]}; }
    constraint c_mix    { w_alu    inside {[10:20]}; w_muldiv inside {[35:50]};
                          w_upper  inside {[2:5]};   w_load   inside {[5:10]};
                          w_store  inside {[5:10]};  w_branch inside {[5:10]};
                          w_jal    inside {[1:3]};   w_jalr   inside {[1:3]};
                          w_loop   inside {[2:5]}; }
    function new(string name = "rv_program_muldiv"); super.new(name); endfunction
endclass

class core_hazard_test extends core_base_test;
    `uvm_component_utils(core_hazard_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        rv_program::type_id::set_type_override(rv_program_hazard::get_type());
        super.build_phase(phase);
    endfunction
endclass

class core_branch_test extends core_base_test;
    `uvm_component_utils(core_branch_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        rv_program::type_id::set_type_override(rv_program_branchy::get_type());
        super.build_phase(phase);
    endfunction
endclass

class core_muldiv_test extends core_base_test;
    `uvm_component_utils(core_muldiv_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        rv_program::type_id::set_type_override(rv_program_muldiv::get_type());
        super.build_phase(phase);
    endfunction
endclass

// The official ISA tests, converted to image files by ref/make_rvtest_images.py.
// +RVT_DIR=<folder> (default ../tests/riscv-tests), +RVT=<name> to run only one.
class core_riscv_tests extends core_base_test;
    `uvm_component_utils(core_riscv_tests)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_programs();
        file_prog_seq seq = file_prog_seq::type_id::create("seq");
        string one;
        seq.dir = "../tests/riscv-tests";
        void'($value$plusargs("RVT_DIR=%s", seq.dir));
        if ($value$plusargs("RVT=%s", one))
            seq.names.push_back(one);
        seq.start(env.prog_agt.seqr);
    endtask
endclass
