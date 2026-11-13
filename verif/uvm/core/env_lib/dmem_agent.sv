// dmem_agent.sv - data memory, played by the testbench, plus a monitor for stores
//
// Driver (reactive): every falling edge it returns the word at the CPU's address and, if
// the CPU is storing, writes the new bytes. Like the RTL block RAM, a read in the same edge
// as a write returns the old word (a load and a store are never in Memory together anyway).
// Stores to the I/O area (0x1000_0000 and up) are not kept, they only matter to the monitor.
//
// Monitor (passive): reports every store to the scoreboard, and tells the program driver
// when the program stores to TOHOST, which means "finished".

class dmem_driver extends uvm_component;
    `uvm_component_utils(dmem_driver)

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
        bit [31:0] addr, q;
        forever begin
            @(vif.mem_cb);
            addr = vif.mem_cb.Mem_WrAddr;
            q    = cfg.dmem.read_word(addr);
            if (!vif.mem_cb.reset && vif.mem_cb.MemWrite && addr < `IO_BASE)
                cfg.dmem.store(addr, vif.mem_cb.Mem_WrData, vif.mem_cb.funct3);
            vif.mem_cb.ReadData <= q;
        end
    endtask

endclass

class dmem_monitor extends uvm_monitor;
    `uvm_component_utils(dmem_monitor)

    virtual core_if.MON              vif;
    core_env_config                  cfg;
    uvm_analysis_port #(store_item)  ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(core_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("CFG", "no core_env_config")
    endfunction

    function void connect_phase(uvm_phase phase);
        vif = cfg.cif;
    endfunction

    task run_phase(uvm_phase phase);
        store_item st;
        forever begin
            @(vif.mon_cb);
            if (!vif.mon_cb.reset && vif.mon_cb.MemWrite) begin
                st = store_item::type_id::create("st");
                st.addr = vif.mon_cb.Mem_WrAddr;
                st.data = vif.mon_cb.Mem_WrData;
                st.size = vif.mon_cb.funct3;
                ap.write(st);
                if (st.addr == `TOHOST_ADDR) begin
                    cfg.tohost_value = st.data;
                    cfg.tohost_ev.trigger();
                end
            end
        end
    endtask

endclass

class dmem_agent extends uvm_agent;
    `uvm_component_utils(dmem_agent)

    dmem_driver  drv;
    dmem_monitor mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        drv = dmem_driver::type_id::create("drv", this);
        mon = dmem_monitor::type_id::create("mon", this);
    endfunction

endclass
