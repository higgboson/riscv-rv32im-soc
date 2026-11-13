// accel_test_lib.sv - the tests. Pick one with +UVM_TESTNAME=<name> (see sim/Makefile).
//
//   accel_rand_test     random jobs, default mix
//   accel_corner_test   fixed extreme patterns at K = 1, 4, 64
//   accel_accum_test    chains of jobs without clear (long sums in pieces)
//   accel_b2b_test      back-to-back jobs, A buffer often reused
//   accel_poke_test     a second start during every run, which must be ignored
//   accel_full_test     all of the above in one run, for coverage closure
//
// Number of jobs per sequence: +NJOBS=<n> (default 200).

class accel_base_test extends uvm_test;
    `uvm_component_utils(accel_base_test)

    accel_env    env;
    int unsigned n_jobs = 200;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        void'($value$plusargs("NJOBS=%d", n_jobs));
        env = accel_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_root::get().print_topology();
    endfunction

    // start one sequence on the agent
    task run_seq(accel_base_seq seq);
        seq.n_jobs = n_jobs;
        seq.start(env.agt.seqr);
    endtask

    virtual task run_seqs();
        run_seq(accel_rand_seq::type_id::create("rand_seq"));
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_seqs();
        #100ns;                            // let the monitor finish the last job
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server svr = uvm_report_server::get_server();
        int errors = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
        if (errors == 0)
            `uvm_info("RESULT", $sformatf("TEST PASSED: %s", get_type_name()), UVM_NONE)
        else
            `uvm_info("RESULT", $sformatf("TEST FAILED: %s (%0d errors)", get_type_name(), errors), UVM_NONE)
    endfunction

endclass

class accel_rand_test extends accel_base_test;
    `uvm_component_utils(accel_rand_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class accel_corner_test extends accel_base_test;
    `uvm_component_utils(accel_corner_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(accel_corner_seq::type_id::create("corner_seq"));
    endtask
endclass

class accel_accum_test extends accel_base_test;
    `uvm_component_utils(accel_accum_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(accel_accum_seq::type_id::create("accum_seq"));
    endtask
endclass

class accel_b2b_test extends accel_base_test;
    `uvm_component_utils(accel_b2b_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(accel_b2b_seq::type_id::create("b2b_seq"));
    endtask
endclass

class accel_poke_test extends accel_base_test;
    `uvm_component_utils(accel_poke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(accel_poke_seq::type_id::create("poke_seq"));
    endtask
endclass

class accel_full_test extends accel_base_test;
    `uvm_component_utils(accel_full_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(accel_corner_seq::type_id::create("corner_seq"));
        run_seq(accel_rand_seq::type_id::create("rand_seq"));
        run_seq(accel_accum_seq::type_id::create("accum_seq"));
        run_seq(accel_b2b_seq::type_id::create("b2b_seq"));
        run_seq(accel_poke_seq::type_id::create("poke_seq"));
    endtask
endclass
