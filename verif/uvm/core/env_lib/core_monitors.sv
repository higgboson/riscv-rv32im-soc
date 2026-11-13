// core_monitors.sv - passive monitors on the pipeline probe
//
// commit_monitor : every register write leaving Writeback -> scoreboard
// pipe_monitor   : what the pipeline did each cycle (forwarding, stalls, branch guesses)
//                  -> coverage. It only watches; the SVA in core_probe_if do the checking.

class commit_monitor extends uvm_monitor;
    `uvm_component_utils(commit_monitor)

    virtual core_probe_if.MON         vif;
    core_env_config                   cfg;
    uvm_analysis_port #(commit_item)  ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(core_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("CFG", "no core_env_config")
    endfunction

    function void connect_phase(uvm_phase phase);
        vif = cfg.pif;
    endfunction

    // sampled just before the rising edge: these are the values the register file takes
    task run_phase(uvm_phase phase);
        commit_item c;
        forever begin
            @(vif.mon_cb);
            if (!vif.mon_cb.reset && vif.mon_cb.RegWriteW && vif.mon_cb.RdW != 0) begin
                c = commit_item::type_id::create("c");
                c.rd    = vif.mon_cb.RdW;
                c.value = vif.mon_cb.ResultW;
                c.pc    = vif.mon_cb.PCW;
                ap.write(c);
            end
        end
    endtask

endclass

class pipe_monitor extends uvm_monitor;
    `uvm_component_utils(pipe_monitor)

    virtual core_probe_if.MON       vif;
    core_env_config                 cfg;
    uvm_analysis_port #(pipe_item)  ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(core_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("CFG", "no core_env_config")
    endfunction

    function void connect_phase(uvm_phase phase);
        vif = cfg.pif;
    endfunction

    task run_phase(uvm_phase phase);
        pipe_item p;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.reset) continue;
            p = pipe_item::type_id::create("p");
            if (!vif.mon_cb.ValidE)                p.eclass = pipe_item::E_BUBBLE;
            else if (vif.mon_cb.MulDivE)           p.eclass = pipe_item::E_MULDIV;
            else if (vif.mon_cb.JalrE)             p.eclass = pipe_item::E_JALR;
            else if (vif.mon_cb.JumpE)             p.eclass = pipe_item::E_JAL;
            else if (vif.mon_cb.BranchE)           p.eclass = pipe_item::E_BRANCH;
            else if (vif.mon_cb.ResultSrcE == 2'b01) p.eclass = pipe_item::E_LOAD;
            else if (vif.mon_cb.MemWriteE)         p.eclass = pipe_item::E_STORE;
            else                                   p.eclass = pipe_item::E_ALU;
            p.fwd_a      = vif.mon_cb.ForwardAE;
            p.fwd_b      = vif.mon_cb.ForwardBE;
            // a load-use stall holds Fetch / Decode without a divide being the reason
            p.load_use   = vif.mon_cb.StallD && !vif.mon_cb.DivStallE;
            p.div_stall  = vif.mon_cb.DivStallE;
            p.mispredict = vif.mon_cb.MispredictE && vif.mon_cb.ValidE;
            p.pred       = vif.mon_cb.PredE;
            p.taken      = vif.mon_cb.TakenE;
            p.funct3     = vif.mon_cb.funct3E;
            p.rs1_eq_rs2 = (vif.mon_cb.Rs1E == vif.mon_cb.Rs2E);
            ap.write(p);
        end
    endtask

endclass
