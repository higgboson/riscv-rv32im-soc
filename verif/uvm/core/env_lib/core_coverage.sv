// core_coverage.sv - functional coverage
//
//   cg_isa    : which instructions ran, and their interesting cases (from the reference model,
//               so it describes what the program really executed)
//   cg_muldiv : multiply / divide corner cases (divide by zero, overflow, sign combinations)
//   cg_branch : each branch type taken and not taken
//   cg_mem    : load / store sizes at every byte offset
//   cg_hazard : what the pipeline did: forwarding paths, stalls, branch guesses, crossed with
//               the kind of instruction in Execute (from the pipeline probe)
// Closing these is the goal of the regression: every bin hit means the case was really
// exercised and checked by the scoreboard.

`uvm_analysis_imp_decl(_iss)
`uvm_analysis_imp_decl(_pipe)

class core_coverage extends uvm_component;
    `uvm_component_utils(core_coverage)

    uvm_analysis_imp_iss  #(iss_item,  core_coverage) iss_export;
    uvm_analysis_imp_pipe #(pipe_item, core_coverage) pipe_export;

    // decoded fields of the last executed instruction
    typedef enum {OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_BRANCH, OP_LOAD, OP_STORE,
                  OP_ALU_I, OP_ALU_R, OP_MULDIV, OP_OTHER} opclass_e;
    opclass_e  opclass;
    bit [2:0]  f3;
    bit [6:0]  f7;
    bit [4:0]  rd, rs1, rs2;
    bit [31:0] a, b;
    bit        taken;
    bit [1:0]  addr_off;

    pipe_item  p;

    covergroup cg_isa;
        option.per_instance = 1;
        OPCLASS : coverpoint opclass { ignore_bins other = {OP_OTHER}; }
        F3      : coverpoint f3;
        // every funct3 of the ALU / M groups (each one is a different instruction)
        ALU_R   : cross OPCLASS, F3 { ignore_bins not_r = !binsof(OPCLASS) intersect {OP_ALU_R}; }
        ALU_I   : cross OPCLASS, F3 { ignore_bins not_i = !binsof(OPCLASS) intersect {OP_ALU_I}; }
        MULDIV  : cross OPCLASS, F3 { ignore_bins not_m = !binsof(OPCLASS) intersect {OP_MULDIV}; }
        SUB_SRA : coverpoint {opclass == OP_ALU_R, f3, f7[5]} {
            bins sub = {5'b1_000_1};
            bins sra = {5'b1_101_1};
        }
        RD_X0     : coverpoint (rd == 0 && opclass inside {OP_ALU_R, OP_ALU_I, OP_LOAD, OP_JAL, OP_JALR, OP_LUI})
                    { bins write_to_x0 = {1}; }
        SAME_SRCS : coverpoint (rs1 == rs2 && opclass inside {OP_ALU_R, OP_MULDIV, OP_BRANCH})
                    { bins rs1_is_rs2 = {1}; }
    endgroup

    covergroup cg_muldiv;
        option.per_instance = 1;
        OP     : coverpoint f3;
        B_ZERO : coverpoint (b == 0) { bins zero = {1}; bins nonzero = {0}; }
        OVF    : coverpoint (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) { bins overflow = {1}; }
        SIGNS  : coverpoint {a[31], b[31]};
        OPxB_ZERO : cross OP, B_ZERO { ignore_bins mul_only = binsof(OP) intersect {[0:3]} && binsof(B_ZERO) intersect {1}; }
        OPxSIGNS  : cross OP, SIGNS;
        DIVxOVF   : cross OP, OVF { ignore_bins not_div = binsof(OP) intersect {[0:3], 5, 7}; }
    endgroup

    covergroup cg_branch;
        option.per_instance = 1;
        TYPE  : coverpoint f3 { bins beq = {0}; bins bne = {1}; bins blt = {4};
                                bins bge = {5}; bins bltu = {6}; bins bgeu = {7}; }
        TAKEN : coverpoint taken;
        EQUAL : coverpoint (a == b);
        TYPExTAKEN : cross TYPE, TAKEN;
        TYPExEQUAL : cross TYPE, EQUAL;
    endgroup

    covergroup cg_mem;
        option.per_instance = 1;
        KIND : coverpoint opclass { bins load = {OP_LOAD}; bins store = {OP_STORE}; }
        SIZE : coverpoint f3 { bins b = {0}; bins h = {1}; bins w = {2}; bins bu = {4}; bins hu = {5}; }
        OFF  : coverpoint addr_off;
        KINDxSIZExOFF : cross KIND, SIZE, OFF {
            ignore_bins half_odd  = binsof(SIZE) intersect {1, 5} && binsof(OFF) intersect {1, 3};
            ignore_bins word_off  = binsof(SIZE) intersect {2} && binsof(OFF) intersect {[1:3]};
            ignore_bins store_uns = binsof(KIND) intersect {OP_STORE} && binsof(SIZE) intersect {4, 5};
        }
    endgroup

    covergroup cg_hazard;
        option.per_instance = 1;
        ECLASS : coverpoint p.eclass;
        FWD_A  : coverpoint p.fwd_a { bins regfile = {0}; bins from_wb = {1}; bins from_mem = {2}; }
        FWD_B  : coverpoint p.fwd_b { bins regfile = {0}; bins from_wb = {1}; bins from_mem = {2}; }
        // a forwarded value used by every kind of instruction (ALU, address, store data,
        // branch compare, jalr target, multiply / divide operand)
        FWD_AxECLASS : cross FWD_A, ECLASS { ignore_bins bubble = binsof(ECLASS) intersect {pipe_item::E_BUBBLE, pipe_item::E_JAL}; }
        FWD_BxECLASS : cross FWD_B, ECLASS {
            ignore_bins no_rs2 = binsof(ECLASS) intersect {pipe_item::E_BUBBLE, pipe_item::E_JAL,
                                                           pipe_item::E_JALR, pipe_item::E_LOAD};
        }
        LOAD_USE  : coverpoint p.load_use  { bins stall = {1}; }
`ifndef VERILATOR
        // a stall that lasts 20+ cycles (repetition in a transition bin: not in every simulator)
        DIV_STALL : coverpoint p.div_stall { bins stall = {1}; bins long_stall = (0 => 1 [*20]); }
`else
        DIV_STALL : coverpoint p.div_stall { bins stall = {1}; }
`endif
        // branch prediction: every combination of guess and outcome, for each jump kind
        GUESS : coverpoint {p.pred, p.taken} iff (p.eclass inside {pipe_item::E_BRANCH, pipe_item::E_JAL, pipe_item::E_JALR}) {
            bins nt_nt = {2'b00}; bins nt_t = {2'b01}; bins t_nt = {2'b10}; bins t_t = {2'b11};
        }
        JKIND : coverpoint p.eclass { bins branch = {pipe_item::E_BRANCH}; bins jal = {pipe_item::E_JAL};
                                      bins jalr = {pipe_item::E_JALR}; }
        GUESSxJKIND : cross GUESS, JKIND {
            ignore_bins jump_not_taken = binsof(JKIND) intersect {pipe_item::E_JAL, pipe_item::E_JALR}
                                         && binsof(GUESS) intersect {2'b00, 2'b10};
            ignore_bins jalr_predicted = binsof(JKIND) intersect {pipe_item::E_JALR}
                                         && binsof(GUESS) intersect {2'b11};
        }
        MISPREDICT : coverpoint p.mispredict { bins wrong = {1}; bins two_in_a_row = (1 => 0 => 0 => 1); }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        iss_export  = new("iss_export", this);
        pipe_export = new("pipe_export", this);
        cg_isa    = new();
        cg_muldiv = new();
        cg_branch = new();
        cg_mem    = new();
        cg_hazard = new();
    endfunction

    function void write_iss(iss_item it);
        bit [6:0] op = it.insn[6:0];
        f3  = it.insn[14:12];
        f7  = it.insn[31:25];
        rd  = it.insn[11:7];
        rs1 = it.insn[19:15];
        rs2 = it.insn[24:20];
        a   = it.rs1_val;
        b   = it.rs2_val;
        taken = it.taken;
        case (op)
            7'h37: opclass = OP_LUI;
            7'h17: opclass = OP_AUIPC;
            7'h6F: opclass = OP_JAL;
            7'h67: opclass = OP_JALR;
            7'h63: opclass = OP_BRANCH;
            7'h03: opclass = OP_LOAD;
            7'h23: opclass = OP_STORE;
            7'h13: opclass = OP_ALU_I;
            7'h33: opclass = (f7 == 7'h01) ? OP_MULDIV : OP_ALU_R;
            default: opclass = OP_OTHER;
        endcase
        // byte offset of the access: base + immediate, low 2 bits
        if (opclass == OP_LOAD)
            addr_off = it.rs1_val[1:0] + it.insn[21:20];
        else if (opclass == OP_STORE)
            addr_off = it.rs1_val[1:0] + it.insn[8:7];
        cg_isa.sample();
        if (opclass == OP_MULDIV) cg_muldiv.sample();
        if (opclass == OP_BRANCH) cg_branch.sample();
        if (opclass inside {OP_LOAD, OP_STORE}) cg_mem.sample();
    endfunction

    function void write_pipe(pipe_item it);
        p = it;
        cg_hazard.sample();
    endfunction

endclass
