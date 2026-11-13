// prog_agent.sv - the agent that runs programs on the CPU
//
// Its sequence items are whole programs (rv_program). For each one the driver:
//   1. holds the CPU in reset and loads the program into the memory agents' memories
//   2. tells the scoreboard a program starts (so the reference model loads the same image)
//   3. releases reset and waits for the program to store to TOHOST (or times out)
//   4. lets the pipeline drain, tells the scoreboard the program finished
// A test can run many programs one after another in the same simulation.

typedef uvm_sequencer #(rv_program) prog_sequencer;

class prog_driver extends uvm_driver #(rv_program);
    `uvm_component_utils(prog_driver)

    virtual core_if.CTRL               vif;
    core_env_config                    cfg;
    uvm_analysis_port #(prog_marker)   marker_ap;

    int unsigned n_run, n_timeout, n_fail;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        marker_ap = new("marker_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(core_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("CFG", "no core_env_config")
    endfunction

    function void connect_phase(uvm_phase phase);
        vif = cfg.cif;
    endfunction

    task run_phase(uvm_phase phase);
        vif.ctrl_cb.reset <= 1'b1;
        forever begin
            seq_item_port.get_next_item(req);
            run_program(req);
            seq_item_port.item_done();
        end
    endtask

    task run_program(rv_program p);
        prog_marker m;
        bit timed_out = 0;

        // 1. reset and load. Load first and keep reset on for a few more edges: the imem agent
        // reads memory on these same edges, and loading on the release edge was a race
        // (the first instruction could come from the previous program).
        vif.ctrl_cb.reset <= 1'b1;
        @(vif.ctrl_cb);
        cfg.imem.clear();
        cfg.dmem.clear();
        foreach (p.code[i])
            cfg.imem.write_word(i * 4, p.code[i]);
        foreach (p.data_words[a])
            cfg.dmem.write_word(a, p.data_words[a]);
        repeat (4) @(vif.ctrl_cb);

        // 2. the scoreboard's reference model gets the same image
        m = prog_marker::type_id::create("start");
        m.kind = prog_marker::START;
        m.name = p.name_tag;
        m.imem = cfg.imem;
        m.dmem = cfg.dmem;
        marker_ap.write(m);

        // 3. run
        `uvm_info("PROG", $sformatf("running %s", p.convert2string()), UVM_MEDIUM)
        cfg.tohost_ev.reset();
        vif.ctrl_cb.reset <= 1'b0;
        fork
            cfg.tohost_ev.wait_trigger();
            begin
                repeat (p.max_cycles) @(vif.ctrl_cb);
                timed_out = 1;
            end
        join_any
        disable fork;

        n_run++;
        if (timed_out) begin
            n_timeout++;
            `uvm_error("PROG", $sformatf("%s: no TOHOST store after %0d cycles", p.name_tag, p.max_cycles))
        end else if (cfg.tohost_value != 1) begin
            // riscv-tests report the number of the failed check as (n << 1) | 1
            n_fail++;
            `uvm_error("PROG", $sformatf("%s: program reported failure, check %0d",
                                         p.name_tag, cfg.tohost_value >> 1))
        end

        // 4. instructions older than the TOHOST store leave the pipeline within a few cycles
        repeat (10) @(vif.ctrl_cb);
        m = prog_marker::type_id::create("finish");
        m.kind = prog_marker::FINISH;
        m.name = p.name_tag;
        m.timed_out = timed_out;
        marker_ap.write(m);
        vif.ctrl_cb.reset <= 1'b1;
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("PROG", $sformatf("programs run: %0d, timed out: %0d, reported failure: %0d",
                                    n_run, n_timeout, n_fail), UVM_LOW)
    endfunction

endclass

class prog_agent extends uvm_agent;
    `uvm_component_utils(prog_agent)

    prog_sequencer seqr;
    prog_driver    drv;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        seqr = prog_sequencer::type_id::create("seqr", this);
        drv  = prog_driver::type_id::create("drv", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction

endclass
