// rv_instr.sv - one random RV32IM instruction that does not change the PC
// (ALU, M extension, lui/auipc, load, store). Branches and jumps depend on where they sit
// in the program, so rv_program places those itself.
//
// Register use in generated programs:
//   x1..x27  random destinations
//   x28      loop counter, x29 / x30 scratch for jalr and the end of the program
//   x31      always 0, the base address for loads and stores (addresses 0..255)
//
// The "recent" knob makes hazards likely: rs1 / rs2 are often one of the last few
// destinations, so the value has to be forwarded from Memory or Writeback.

class rv_instr extends uvm_object;
    `uvm_object_utils(rv_instr)

    typedef enum {K_ALU_R, K_MULDIV, K_ALU_I, K_UPPER, K_LOAD, K_STORE} kind_e;

    rand kind_e     kind;
    rand bit [4:0]  rd, rs1, rs2;
    rand bit [2:0]  f3;
    rand bit        alt;          // sub / sra / srai, or auipc instead of lui
    rand bit [11:0] imm12;
    rand bit [19:0] imm20;
    rand bit        rs1_recent, rs2_recent;

    // knobs, set by rv_program before randomize()
    bit [4:0]    recent[$] = '{1, 2, 3};
    int unsigned hazard_pct = 60;

    constraint c_rd { rd inside {[1:27]}; }

    constraint c_hazard {
        rs1_recent dist {1 := hazard_pct, 0 := 100 - hazard_pct};
        rs2_recent dist {1 := hazard_pct, 0 := 100 - hazard_pct};
    }

    // sources: one of the recent destinations, or any random register (x0 included)
    constraint c_sources {
        if (kind inside {K_LOAD, K_STORE}) rs1 == 31;
        else if (rs1_recent) rs1 inside {recent};
        else rs1 inside {[0:27]};
        if (rs2_recent) rs2 inside {recent};
        else rs2 inside {[0:27]};
    }

    // only sub and sra have a second form in R-type; only srai in I-type
    constraint c_alt {
        (kind == K_ALU_R && !(f3 inside {3'd0, 3'd5})) -> !alt;
        (kind == K_ALU_I && f3 != 3'd5) -> !alt;
        (kind inside {K_MULDIV, K_LOAD, K_STORE}) -> !alt;
    }

    // shifts take a 5-bit amount
    constraint c_shift { (kind == K_ALU_I && f3 inside {3'd1, 3'd5}) -> imm12[11:5] == 0; }

    // loads / stores: valid sizes, aligned, inside the first 256 bytes
    constraint c_mem {
        (kind == K_LOAD)  -> f3 inside {3'd0, 3'd1, 3'd2, 3'd4, 3'd5};
        (kind == K_STORE) -> f3 inside {3'd0, 3'd1, 3'd2};
        (kind inside {K_LOAD, K_STORE}) -> imm12 < 256;
        (kind inside {K_LOAD, K_STORE} && f3[1:0] == 2'd1) -> imm12[0] == 0;
        (kind inside {K_LOAD, K_STORE} && f3[1:0] == 2'd2) -> imm12[1:0] == 0;
    }

    function new(string name = "rv_instr");
        super.new(name);
    endfunction

    function bit [31:0] encode();
        case (kind)
            K_ALU_R:  return {alt ? 7'h20 : 7'h00, rs2, rs1, f3, rd, 7'h33};
            K_MULDIV: return {7'h01, rs2, rs1, f3, rd, 7'h33};
            K_ALU_I:  return {(f3 == 3'd5 && alt) ? (imm12 | 12'h400) : imm12, rs1, f3, rd, 7'h13};
            K_UPPER:  return {imm20, rd, alt ? 7'h17 : 7'h37};
            K_LOAD:   return {imm12, rs1, f3, rd, 7'h03};
            default:  return {imm12[11:5], rs2, rs1, f3, imm12[4:0], 7'h23};   // store
        endcase
    endfunction

    // does this instruction write rd (stores don't)
    function bit writes_rd();
        return kind != K_STORE;
    endfunction

endclass
