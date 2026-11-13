// core_env_config.sv - everything the components share: interfaces, memories, end-of-program
// signalling. The test builds it and puts it in uvm_config_db.

class core_env_config extends uvm_object;
    `uvm_object_utils(core_env_config)

    virtual core_if       cif;
    virtual core_probe_if pif;

    rv_mem imem, dmem;               // the memories the CPU runs from (agents read / write these)

    // the data monitor raises this when the program stores to TOHOST
    uvm_event  tohost_ev;
    bit [31:0] tohost_value;

    bit has_coverage = 1;

    function new(string name = "core_env_config");
        super.new(name);
        imem = rv_mem::type_id::create("imem");
        dmem = rv_mem::type_id::create("dmem");
        tohost_ev = new("tohost_ev");
    endfunction

endclass
