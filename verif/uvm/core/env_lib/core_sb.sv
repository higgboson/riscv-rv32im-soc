// core_sb.sv - scoreboard: the CPU against the C reference model, step by step
//
// The CPU reports register writes (from Writeback) and stores (from Memory) at different
// times, so they arrive as two separate ordered streams. The reference model runs the same
// program one instruction at a time and fills two queues of expected events.
// When the CPU reports a register write, the scoreboard runs the reference model until it
// has an expected register write, then compares. Same for stores. Both streams must match
// in order, and at the end of a program neither side may have anything left over.
//
// Comparing every write (not just the final registers) also catches a wrong value that is
// overwritten later, or one extra write.

`uvm_analysis_imp_decl(_reg)
`uvm_analysis_imp_decl(_st)
`uvm_analysis_imp_decl(_mark)

class core_sb extends uvm_scoreboard;
    `uvm_component_utils(core_sb)

    uvm_analysis_imp_reg  #(commit_item, core_sb) reg_export;
    uvm_analysis_imp_st   #(store_item,  core_sb) st_export;
    uvm_analysis_imp_mark #(prog_marker, core_sb) mark_export;
    uvm_analysis_port     #(iss_item)             iss_ap;      // to coverage

    local commit_item exp_reg[$];
    local store_item  exp_st[$];
    local bit         halted;
    local int unsigned steps;
    local string      prog_name;

    int unsigned n_reg_checked, n_st_checked, n_errors, n_programs, n_instr;

    localparam int unsigned STEP_LIMIT = 2_000_000;
    localparam int unsigned MAX_PRINT  = 10;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        reg_export  = new("reg_export", this);
        st_export   = new("st_export", this);
        mark_export = new("mark_export", this);
        iss_ap      = new("iss_ap", this);
    endfunction

    // run one instruction on the reference model and queue what it did
    local function void step_ref();
        int unsigned pc, insn, rd, rd_val, st_addr, st_data, st_size, rs1_val, rs2_val;
        int rd_we, st, taken;
        iss_item it;

        if (halted) return;
        if (iss_step(pc, insn, rd_we, rd, rd_val, st, st_addr, st_data, st_size,
                     rs1_val, rs2_val, taken) == 0 || ++steps > STEP_LIMIT) begin
            halted = 1;
            return;
        end
        n_instr++;

        if (rd_we) begin
            commit_item c = commit_item::type_id::create("exp_reg");
            c.rd = rd; c.value = rd_val; c.pc = pc;
            exp_reg.push_back(c);
        end
        if (st) begin
            store_item s = store_item::type_id::create("exp_st");
            s.addr = st_addr; s.data = st_data; s.size = st_size;
            exp_st.push_back(s);
        end

        it = iss_item::type_id::create("it");
        it.pc = pc; it.insn = insn; it.rs1_val = rs1_val; it.rs2_val = rs2_val;
        it.rd_val = rd_val; it.taken = taken;
        iss_ap.write(it);
    endfunction

    local function void error(string msg);
        n_errors++;
        if (n_errors <= MAX_PRINT)
            `uvm_error("SB", {prog_name, ": ", msg})
    endfunction

    // program boundaries from the program driver
    function void write_mark(prog_marker m);
        if (m.kind == prog_marker::START) begin
            prog_name = m.name;
            exp_reg.delete();
            exp_st.delete();
            halted = 0;
            steps  = 0;
            iss_reset();
            foreach (m.imem.words[wa]) iss_imem_write({wa, 2'b00}, m.imem.words[wa]);
            foreach (m.dmem.words[wa]) iss_dmem_write({wa, 2'b00}, m.dmem.words[wa]);
            n_programs++;
        end else begin
            // run the reference to its end: anything it still produces, the CPU missed
            while (!halted) step_ref();
            if (!m.timed_out) begin
                if (exp_reg.size() != 0)
                    error($sformatf("CPU missed %0d register writes, first: %s",
                                    exp_reg.size(), exp_reg[0].convert2string()));
                if (exp_st.size() != 0)
                    error($sformatf("CPU missed %0d stores, first: %s",
                                    exp_st.size(), exp_st[0].convert2string()));
            end
            if (iss_bad_access())
                `uvm_warning("SB", {prog_name, ": program used memory outside the reference model"})
            if (steps > STEP_LIMIT)
                error("reference model did not finish (endless loop?)");
        end
    endfunction

    function void write_reg(commit_item got);
        commit_item exp;
        while (exp_reg.size() == 0 && !halted) step_ref();
        if (exp_reg.size() == 0) begin
            error({"CPU wrote a register after the program ended: ", got.convert2string()});
            return;
        end
        exp = exp_reg.pop_front();
        n_reg_checked++;
        if (got.rd != exp.rd || got.value != exp.value)
            error({"register write mismatch\n  CPU      : ", got.convert2string(),
                   "\n  expected : ", exp.convert2string()});
    endfunction

    function void write_st(store_item got);
        store_item exp;
        bit [31:0] mask;
        while (exp_st.size() == 0 && !halted) step_ref();
        if (exp_st.size() == 0) begin
            error({"CPU stored after the program ended: ", got.convert2string()});
            return;
        end
        exp = exp_st.pop_front();
        n_st_checked++;
        // only the bytes the store really writes count
        mask = (exp.size == 0) ? 32'hFF : (exp.size == 1) ? 32'hFFFF : 32'hFFFF_FFFF;
        if (got.addr != exp.addr || got.size != exp.size || (got.data & mask) != (exp.data & mask))
            error({"store mismatch\n  CPU      : ", got.convert2string(),
                   "\n  expected : ", exp.convert2string()});
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf({"%0d programs, %0d instructions on the reference model, ",
                                   "%0d register writes and %0d stores compared, %0d mismatches"},
                                  n_programs, n_instr, n_reg_checked, n_st_checked, n_errors), UVM_LOW)
    endfunction

endclass
