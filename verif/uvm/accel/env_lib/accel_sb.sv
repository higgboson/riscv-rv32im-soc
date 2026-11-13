// accel_sb.sv - reference model and scoreboard
//
// The model keeps its own C, like the PEs do: clear sets it to 0, then every job adds
// A x B. 32-bit int arithmetic wraps exactly like the 32-bit accumulators.

class accel_sb extends uvm_scoreboard;
    `uvm_component_utils(accel_sb)

    uvm_analysis_imp #(accel_xtn, accel_sb) imp;

    int          model_c [4][4];       // the PEs start at 0 (systolic_pe.v), so does the model
    int unsigned jobs, mismatches, timing_errors, pokes;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        imp = new("imp", this);
    endfunction

    function void write(accel_xtn t);
        bit bad;
        jobs++;
        if (t.poked) pokes++;              // the ignored start must not change anything

        if (t.clear)
            foreach (model_c[i, j]) model_c[i][j] = 0;
        foreach (model_c[i, j])
            for (int kk = 0; kk < t.k; kk++)
                model_c[i][j] += int'(t.a[i][kk]) * int'(t.b[kk][j]);

        bad = 0;
        foreach (model_c[i, j])
            if (t.c[i][j] !== model_c[i][j]) begin
                bad = 1;
                `uvm_error("SB", $sformatf("job %0d (K=%0d clear=%0d): C[%0d][%0d] = %0d, expected %0d",
                           jobs, t.k, t.clear, i, j, t.c[i][j], model_c[i][j]))
            end
        if (bad) mismatches++;

        if (t.cycles != t.k + 6) begin
            timing_errors++;
            `uvm_error("SB", $sformatf("job %0d (K=%0d): run took %0d cycles, expected %0d",
                       jobs, t.k, t.cycles, t.k + 6))
        end

        // a mismatch leaves the DUT's C different from the model's; resync so one bug
        // gives one error, not one per later accumulate job
        if (bad)
            foreach (model_c[i, j]) model_c[i][j] = t.c[i][j];
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf("jobs %0d, jobs with wrong results %0d, wrong run lengths %0d, ignored starts %0d",
                  jobs, mismatches, timing_errors, pokes), UVM_LOW)
        if (jobs == 0)
            `uvm_error("SB", "no jobs were checked")
    endfunction

endclass
