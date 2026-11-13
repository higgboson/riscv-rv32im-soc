// accel_seqs.sv - sequences of tile jobs

class accel_base_seq extends uvm_sequence #(accel_xtn);
    `uvm_object_utils(accel_base_seq)

    int unsigned n_jobs = 100;
    int unsigned edge_w = 10;

    function new(string name = "accel_base_seq");
        super.new(name);
    endfunction

    // one job; the caller's constraints come in through the derived sequences
    task send(accel_xtn t);
        start_item(t);
        finish_item(t);
    endtask

    function accel_xtn make();
        accel_xtn t = accel_xtn::type_id::create("t");
        t.edge_w = edge_w;
        return t;
    endfunction
endclass

// fully random jobs with the default distributions
class accel_rand_seq extends accel_base_seq;
    `uvm_object_utils(accel_rand_seq)
    function new(string name = "accel_rand_seq"); super.new(name); endfunction

    task body();
        repeat (n_jobs) begin
            accel_xtn t = make();
            if (!t.randomize()) `uvm_fatal("SEQ", "randomize failed")
            send(t);
        end
    endtask
endclass

// fixed patterns at K = 1, 4 and 64: all -128, all 127, mixed signs, zeros, one-hot
class accel_corner_seq extends accel_base_seq;
    `uvm_object_utils(accel_corner_seq)
    function new(string name = "accel_corner_seq"); super.new(name); endfunction

    task body();
        int ks[3] = '{1, 4, 64};
        foreach (ks[n])
            for (int p = 0; p < 6; p++) begin
                accel_xtn t = make();
                if (!t.randomize() with { k == ks[n]; clear == 1; reload_a == 1; poke == 0; })
                    `uvm_fatal("SEQ", "randomize failed")
                for (int kk = 0; kk < 64; kk++)
                    for (int i = 0; i < 4; i++)
                        case (p)
                            0: begin t.a[i][kk] = -128; t.b[kk][i] = -128; end   // largest sum
                            1: begin t.a[i][kk] = -128; t.b[kk][i] =  127; end   // most negative
                            2: begin t.a[i][kk] =  127; t.b[kk][i] =  127; end
                            3: begin t.a[i][kk] = (kk + i) % 2 ? -128 : 127;
                                     t.b[kk][i] = (kk + i) % 3 ? 127 : -128; end
                            4: begin t.a[i][kk] = 0;    t.b[kk][i] = -128; end   // zero A
                            5: begin t.a[i][kk] = (i == kk % 4) ? 1 : 0;          // identity-like
                                     t.b[kk][i] = kk * 4 + i; end
                        endcase
                send(t);
            end
    endtask
endclass

// chains of jobs without clear: long sums split into pieces, as software does for K > 64
class accel_accum_seq extends accel_base_seq;
    `uvm_object_utils(accel_accum_seq)
    function new(string name = "accel_accum_seq"); super.new(name); endfunction

    task body();
        int unsigned done = 0;
        while (done < n_jobs) begin
            int unsigned len = $urandom_range(2, 10);
            for (int n = 0; n < len; n++) begin
                accel_xtn t = make();
                if (!t.randomize() with { clear == (n == 0); poke == 0;
                                          k dist { [1:16] :/ 30, [17:63] :/ 40, 64 := 30 }; })
                    `uvm_fatal("SEQ", "randomize failed")
                send(t);
            end
            done += len;
        end
    endtask
endclass

// no idle cycles between jobs, often reusing A (only B is rewritten, like accel.h)
class accel_b2b_seq extends accel_base_seq;
    `uvm_object_utils(accel_b2b_seq)
    function new(string name = "accel_b2b_seq"); super.new(name); endfunction

    task body();
        repeat (n_jobs) begin
            accel_xtn t = make();
            if (!t.randomize() with { gap == 0; poke == 0; reload_a dist { 1 := 50, 0 := 50 }; })
                `uvm_fatal("SEQ", "randomize failed")
            send(t);
        end
    endtask
endclass

// every job tries to start again while busy; the DUT must ignore it
class accel_poke_seq extends accel_base_seq;
    `uvm_object_utils(accel_poke_seq)
    function new(string name = "accel_poke_seq"); super.new(name); endfunction

    task body();
        repeat (n_jobs) begin
            accel_xtn t = make();
            if (!t.randomize() with { poke == 1; }) `uvm_fatal("SEQ", "randomize failed")
            send(t);
        end
    endtask
endclass
