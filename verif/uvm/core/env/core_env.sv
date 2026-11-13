// core_env.sv - puts the agents, monitors, scoreboard and coverage together
//
//   prog_agent ----- programs ----> CPU <---- imem_agent (instruction fetch)
//        |                         | ^
//        | start / finish          | +------- dmem_agent (loads / stores)
//        v                         |               | stores
//   core_sb <---- register writes -+ commit_monitor|
//        ^ <-------------------------------------- +
//        | instructions executed by the reference model
//   core_coverage <---- pipeline events ---- pipe_monitor

class core_env extends uvm_env;
    `uvm_component_utils(core_env)

    core_env_config cfg;
    prog_agent      prog_agt;
    imem_agent      imem_agt;
    dmem_agent      dmem_agt;
    commit_monitor  commit_mon;
    pipe_monitor    pipe_mon;
    core_sb         sb;
    core_coverage   cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(core_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("CFG", "no core_env_config")
        prog_agt   = prog_agent::type_id::create("prog_agt", this);
        imem_agt   = imem_agent::type_id::create("imem_agt", this);
        dmem_agt   = dmem_agent::type_id::create("dmem_agt", this);
        commit_mon = commit_monitor::type_id::create("commit_mon", this);
        pipe_mon   = pipe_monitor::type_id::create("pipe_mon", this);
        sb         = core_sb::type_id::create("sb", this);
        if (cfg.has_coverage)
            cov = core_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        prog_agt.drv.marker_ap.connect(sb.mark_export);
        commit_mon.ap.connect(sb.reg_export);
        dmem_agt.mon.ap.connect(sb.st_export);
        if (cfg.has_coverage) begin
            sb.iss_ap.connect(cov.iss_export);
            pipe_mon.ap.connect(cov.pipe_export);
        end
    endfunction

endclass
