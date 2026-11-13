// accel_env.sv - agent, scoreboard and coverage for the accelerator
//
//   sequence -> accel_agent.drv -> registers -> matmul_accel
//                                    |
//               accel_agent.mon <----+   (watches the bus)
//                     | jobs
//            +--------+---------+
//            v                  v
//         accel_sb        accel_coverage

class accel_env extends uvm_env;
    `uvm_component_utils(accel_env)

    accel_agent    agt;
    accel_sb       sb;
    accel_coverage cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        agt = accel_agent::type_id::create("agt", this);
        sb  = accel_sb::type_id::create("sb", this);
        cov = accel_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        agt.mon.ap.connect(sb.imp);
        agt.mon.ap.connect(cov.analysis_export);
    endfunction

endclass
