// core_items.sv - small transactions passed between monitors, scoreboard and coverage

// One register write leaving Writeback
class commit_item extends uvm_sequence_item;
    `uvm_object_utils(commit_item)
    bit [4:0]  rd;
    bit [31:0] value;
    bit [31:0] pc;
    function new(string name = "commit_item"); super.new(name); endfunction
    function string convert2string();
        return $sformatf("x%0d = %h (pc %h)", rd, value, pc);
    endfunction
endclass

// One store in the Memory stage
class store_item extends uvm_sequence_item;
    `uvm_object_utils(store_item)
    bit [31:0] addr;
    bit [31:0] data;          // rs2 as the CPU sent it; only the low 'size' bytes count
    bit [2:0]  size;          // funct3: 0 sb, 1 sh, 2 sw
    function new(string name = "store_item"); super.new(name); endfunction
    function string convert2string();
        return $sformatf("%s [%h] = %h",
                         size == 0 ? "sb" : size == 1 ? "sh" : "sw", addr, data);
    endfunction
endclass

// One instruction as the reference model executed it (for instruction coverage)
class iss_item extends uvm_sequence_item;
    `uvm_object_utils(iss_item)
    bit [31:0] pc, insn, rs1_val, rs2_val, rd_val;
    bit        taken;
    function new(string name = "iss_item"); super.new(name); endfunction
endclass

// What the pipeline did in one cycle (for hazard coverage)
class pipe_item extends uvm_sequence_item;
    `uvm_object_utils(pipe_item)
    typedef enum {E_BUBBLE, E_ALU, E_LOAD, E_STORE, E_BRANCH, E_JAL, E_JALR, E_MULDIV} eclass_e;
    eclass_e   eclass;        // kind of instruction in Execute
    bit [1:0]  fwd_a, fwd_b;  // 0 register file, 1 from Writeback, 2 from Memory
    bit        load_use;      // load-use stall this cycle
    bit        div_stall;
    bit        mispredict;
    bit        pred, taken;   // guess made in Fetch, real outcome in Execute
    bit [2:0]  funct3;
    bit        rs1_eq_rs2;
    function new(string name = "pipe_item"); super.new(name); endfunction
endclass

// Program boundaries, from the program driver to the scoreboard
class prog_marker extends uvm_object;
    `uvm_object_utils(prog_marker)
    typedef enum {START, FINISH} kind_e;
    kind_e      kind;
    string      name;
    rv_mem      imem, dmem;   // START: the program image the CPU will run
    bit         timed_out;    // FINISH: the program never reached TOHOST
    function new(string name = "prog_marker"); super.new(name); endfunction
endclass
