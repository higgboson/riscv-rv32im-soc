// imem_agent.sv - instruction memory, played by the testbench
//
// A reactive agent: it doesn't create traffic, it answers the CPU. Every falling edge it
// reads the fetch address (PC) and drives back the instruction stored there, exactly when
// the real block RAM would.

class imem_driver extends uvm_component;
    `uvm_component_utils(imem_driver)

    virtual core_if.MEM_DRV vif;
    core_env_config         cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(core_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("CFG", "no core_env_config")
    endfunction

    function void connect_phase(uvm_phase phase);
        vif = cfg.cif;
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(vif.mem_cb);
            vif.mem_cb.Instr <= cfg.imem.read_word(vif.mem_cb.PC);
        end
    endtask

endclass

class imem_agent extends uvm_agent;
    `uvm_component_utils(imem_agent)

    imem_driver drv;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        drv = imem_driver::type_id::create("drv", this);
    endfunction

endclass
