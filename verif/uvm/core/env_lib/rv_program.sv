// rv_program.sv - one complete test program: the sequence item of the program agent
//
// Randomizing it picks the knobs (length, instruction mix, how often hazards happen);
// post_randomize() then builds the instruction list. Branches, loops and jumps are placed
// here because they depend on their position: they only ever jump forward (so the program
// always finishes), loops count down a register, and no jump may land in the middle of a
// two-instruction sequence it would break.
//
// Every program ends the same way: a few NOPs, a store of 1 to TOHOST, then "jal x0, 0".
//
// A program can also come from a file (riscv-tests): set img_file instead of randomizing.

class rv_program extends uvm_sequence_item;
    `uvm_object_utils(rv_program)

    // knobs
    rand int unsigned n_instr;       // instructions before the end sequence (roughly)
    rand int unsigned w_alu, w_muldiv, w_upper, w_load, w_store;
    rand int unsigned w_branch, w_jal, w_jalr, w_loop;
    rand int unsigned hazard_pct;    // chance a source register is a recent destination
    rand int unsigned special_pct;   // chance a mul/div first loads 0, -1 or -2^31

    constraint c_len    { n_instr inside {[100:500]}; }
    constraint c_mix    { w_alu    inside {[20:40]}; w_muldiv inside {[5:15]};
                          w_upper  inside {[2:6]};   w_load   inside {[8:15]};
                          w_store  inside {[8:15]};  w_branch inside {[8:15]};
                          w_jal    inside {[2:6]};   w_jalr   inside {[2:5]};
                          w_loop   inside {[2:5]}; }
    constraint c_hazard { hazard_pct inside {[50:70]}; special_pct inside {[20:40]}; }

    // the result
    string     name_tag = "random";
    string     img_file;             // non-empty: load this image instead of generating
    bit [31:0] code[$];              // instruction memory, from address 0
    bit [31:0] data_words[bit [31:0]];   // data memory: byte address -> word
    int unsigned max_cycles = 200_000;

    // private state while building
    local bit [4:0] recent[$];
    local int       targets[int];    // instruction indexes some jump lands on

    function new(string name = "rv_program");
        super.new(name);
    endfunction

    function void post_randomize();
        if (img_file == "")
            build();
    endfunction

    local function void emit(bit [31:0] w);
        code.push_back(w);
    endfunction

    local function void note_dest(bit [4:0] rd);
        if (rd == 0) return;
        recent.push_back(rd);
        if (recent.size() > 3) void'(recent.pop_front());
    endfunction

    local function bit [31:0] enc_i(int imm, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
        bit [11:0] i = imm;
        return {i, rs1, f3, rd, op};
    endfunction

    local function bit [31:0] enc_b(int imm, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3);
        bit [12:0] i = imm;
        return {i[12], i[10:5], rs2, rs1, f3, i[4:1], i[11], 7'h63};
    endfunction

    local function bit [31:0] enc_j(int imm, bit [4:0] rd);
        bit [20:0] i = imm;
        return {i[20], i[10:1], i[11], i[19:12], rd, 7'h6F};
    endfunction

    local function bit [4:0] pick_src();
        if (recent.size() > 0 && $urandom_range(99) < hazard_pct)
            return recent[$urandom_range(recent.size() - 1)];
        return $urandom_range(27);
    endfunction

    local function bit [4:0] pick_dst();
        bit [4:0] r = $urandom_range(27, 1);
        note_dest(r);
        return r;
    endfunction

    // one instruction that does not change the PC, as a constrained-random rv_instr
    local function void emit_plain(rv_instr::kind_e kind);
        rv_instr ins = rv_instr::type_id::create("ins");
        if (kind == rv_instr::K_MULDIV && $urandom_range(99) < special_pct) begin
            // set up an awkward operand first: divide by zero, -2^31 / -1, sign corners
            bit [4:0] r = pick_dst();
            case ($urandom_range(2))
                0: emit(enc_i(0, 0, 0, r, 7'h13));             // li r, 0
                1: emit(enc_i(-1, 0, 0, r, 7'h13));            // li r, -1
                2: emit({20'h80000, r, 7'h37});                // lui r, 0x80000  (-2^31)
            endcase
        end
        ins.recent = recent;
        ins.hazard_pct = hazard_pct;
        if (!ins.randomize() with { kind == local::kind; })
            `uvm_fatal("RVPROG", "rv_instr randomize failed")
        emit(ins.encode());
        if (ins.writes_rd()) note_dest(ins.rd);
    endfunction

    local function void build();
        rv_instr::kind_e plain_kinds[5] = '{rv_instr::K_ALU_R, rv_instr::K_MULDIV,
                                           rv_instr::K_UPPER, rv_instr::K_LOAD, rv_instr::K_STORE};
        code.delete();
        data_words.delete();
        targets.delete();
        recent = '{1, 2, 3};

        // start every register (except the reserved ones) with a random value
        for (int r = 1; r <= 29; r++)
            emit(enc_i($urandom_range(4095) - 2048, 0, 0, r, 7'h13));

        while (code.size() < n_instr) begin
            randcase
                w_alu:    emit_plain($urandom_range(1) ? rv_instr::K_ALU_R : rv_instr::K_ALU_I);
                w_muldiv: emit_plain(rv_instr::K_MULDIV);
                w_upper:  emit_plain(rv_instr::K_UPPER);
                w_load:   emit_plain(rv_instr::K_LOAD);
                w_store:  emit_plain(rv_instr::K_STORE);

                w_branch: begin                              // forward branch, skips 1..3
                    int skip = $urandom_range(3, 1);
                    bit [2:0] f3s[6] = '{0, 1, 4, 5, 6, 7};
                    targets[code.size() + skip + 1] = 1;
                    emit(enc_b((skip + 1) * 4, pick_src(), pick_src(), f3s[$urandom_range(5)]));
                end

                w_jal: begin                                 // forward jal, skips 0..2
                    int skip = $urandom_range(2);
                    targets[code.size() + skip + 1] = 1;
                    emit(enc_j((skip + 1) * 4, $urandom_range(1) ? pick_dst() : 5'd0));
                end

                w_jalr: begin                                // auipc x30, 0 ; jalr rd, off(x30)
                    if (targets.exists(code.size() + 1)) begin
                        emit(`NOP_INSN);                     // a jump would land on the jalr
                    end else begin
                        int skip = $urandom_range(2);
                        targets[code.size() + 2 + skip] = 1;
                        emit({20'h0, 5'd30, 7'h17});
                        emit(enc_i(8 + skip * 4, 30, 0, $urandom_range(1) ? pick_dst() : 5'd0, 7'h67));
                    end
                end

                w_loop: begin                                // x28 = n; body; x28--; bne x28, x0
                    bit [31:0] body[$];
                    int start = code.size();
                    int n_body = $urandom_range(5, 1);
                    bit inside_hit = 0;
                    // generate the body separately, then check nothing jumps into it
                    for (int i = 0; i < n_body; i++) begin
                        int at = code.size();
                        emit_plain(plain_kinds[$urandom_range(4)]);
                        while (code.size() > at) body.push_front(code.pop_back());
                    end
                    foreach (targets[t])
                        if (t > start && t <= start + body.size() + 2) inside_hit = 1;
                    if (inside_hit) begin
                        emit(`NOP_INSN);
                    end else begin
                        emit(enc_i($urandom_range(6, 1), 0, 0, 28, 7'h13));
                        foreach (body[i]) emit(body[i]);
                        emit(enc_i(-1, 28, 0, 28, 7'h13));
                        emit(enc_b(-(body.size() + 1) * 4, 0, 28, 3'd1));
                    end
                end
            endcase
        end

        // end: NOPs so no forward jump can skip the TOHOST setup, report pass, stop
        repeat (5) emit(`NOP_INSN);
        emit({20'h10000, 5'd30, 7'h37});                     // lui  x30, 0x10000
        emit(enc_i(1, 0, 0, 29, 7'h13));                     // addi x29, x0, 1
        emit({7'h0, 5'd29, 5'd30, 3'd2, 5'd4, 7'h23});       // sw   x29, 4(x30)
        emit(`HALT_INSN);
    endfunction

    // riscv-tests image: lines "i <addr> <word>" (code) and "d <addr> <word>" (data), hex
    function bit load_image(string path);
        int fd = $fopen(path, "r");
        string kind;
        bit [31:0] a, w;
        if (fd == 0) return 0;
        code.delete();
        data_words.delete();
        while ($fscanf(fd, "%s %h %h", kind, a, w) == 3) begin
            if (kind == "i") begin
                while (code.size() <= a / 4) code.push_back(32'h0);
                code[a / 4] = w;
            end else
                data_words[a] = w;
        end
        $fclose(fd);
        return 1;
    endfunction

    function string convert2string();
        return $sformatf("%s: %0d instructions, %0d data words", name_tag, code.size(), data_words.size());
    endfunction

endclass
