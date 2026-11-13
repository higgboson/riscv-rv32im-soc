// accel_coverage.sv - functional coverage of the jobs the monitor saw

class accel_coverage extends uvm_subscriber #(accel_xtn);
    `uvm_component_utils(accel_coverage)

    accel_xtn    t;
    int unsigned chain;                // jobs since the last clear (1 = this job cleared)
    int          v;                    // one result value, for cg_result
    bit          mm, mx, xx, zero_k;   // products seen in this job (see write)

    covergroup cg_job;
        K: coverpoint t.k {
            bins one      = {1};
            bins few      = {[2:3]};
            bins four     = {4};
            bins mid      = {[5:31]};
            bins big      = {[32:63]};
            bins max      = {64};
        }
        CLEAR:  coverpoint t.clear;
        RELOAD: coverpoint t.reload_a;
        GAP: coverpoint t.gap {
            bins back_to_back = {0};
            bins short_gap    = {[1:3]};
            bins long_gap     = {[4:$]};
        }
        POKE: coverpoint t.poked;
        CHAIN: coverpoint chain {
            bins fresh  = {1};
            bins two    = {2};
            bins few    = {[3:4]};
            bins long_c = {[5:$]};
        }
        K_X_CLEAR:  cross K, CLEAR;
        K_X_RELOAD: cross K, RELOAD;
        K_X_POKE:   cross K, POKE;
        GAP_X_CLEAR: cross GAP, CLEAR;
    endgroup

    // the extreme products, where an 8-bit signed multiplier usually goes wrong
    covergroup cg_products;
        MIN_MIN: coverpoint mm { bins hit = {1}; }   // -128 * -128 = +16384, the largest
        MIN_MAX: coverpoint mx { bins hit = {1}; }   // -128 *  127, the most negative
        MAX_MAX: coverpoint xx { bins hit = {1}; }   //  127 *  127
        ALL_ZERO_A: coverpoint zero_k { bins hit = {1}; }
    endgroup

    covergroup cg_result;
        VAL: coverpoint v {
            bins neg_huge = {[$:-1048576]};          // beyond what one K = 64 job can make
            bins neg      = {[-1048575:-1]};
            bins zero     = {0};
            bins pos      = {[1:1048575]};
            bins pos_huge = {[1048576:$]};           // only reachable by accumulating
        }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_job      = new();
        cg_products = new();
        cg_result   = new();
    endfunction

    function void write(accel_xtn t);
        this.t = t;
        chain = t.clear ? 1 : chain + 1;
        mm = 0; mx = 0; xx = 0; zero_k = 1;
        for (int kk = 0; kk < t.k; kk++)
            for (int i = 0; i < 4; i++) begin
                if (t.a[i][kk] != 0) zero_k = 0;
                for (int j = 0; j < 4; j++) begin
                    if (t.a[i][kk] == -128 && t.b[kk][j] == -128) mm = 1;
                    if ((t.a[i][kk] == -128 && t.b[kk][j] == 127) ||
                        (t.a[i][kk] == 127 && t.b[kk][j] == -128)) mx = 1;
                    if (t.a[i][kk] == 127 && t.b[kk][j] == 127) xx = 1;
                end
            end
        cg_job.sample();
        cg_products.sample();
        foreach (t.c[i, j]) begin
            v = t.c[i][j];
            cg_result.sample();
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("COV", $sformatf("job %.1f%%  products %.1f%%  results %.1f%%",
                  cg_job.get_inst_coverage(), cg_products.get_inst_coverage(),
                  cg_result.get_inst_coverage()), UVM_LOW)
    endfunction

endclass
