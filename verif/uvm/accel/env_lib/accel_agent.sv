// accel_agent.sv - sequencer, driver and monitor for the accelerator's register bus
//
// The driver does what the C driver (sw/common/accel.h) does: write the operands, write
// CTRL to start, poll busy, read the 16 results. The monitor only watches the bus, so the
// scoreboard checks what really happened, not what the driver meant to do.

typedef uvm_sequencer #(accel_xtn) accel_sequencer;

class accel_driver extends uvm_driver #(accel_xtn);
    `uvm_component_utils(accel_driver)

    virtual accel_if.DRV vif;
    int unsigned jobs;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(virtual accel_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "no accel_if in config_db")
    endfunction

    // One bus operation per clock. Values go out just after an edge and the DUT
    // takes them at the next edge, where rd_data is sampled too.
    task bus_write(bit [31:0] a, bit [31:0] d);
        vif.drv_cb.wr_en   <= 1'b1;
        vif.drv_cb.rd_en   <= 1'b0;
        vif.drv_cb.addr    <= a;
        vif.drv_cb.wr_data <= d;
        @(vif.drv_cb);
    endtask

    task bus_read(bit [31:0] a, output bit [31:0] d);
        vif.drv_cb.wr_en <= 1'b0;
        vif.drv_cb.rd_en <= 1'b1;
        vif.drv_cb.addr  <= a;
        @(vif.drv_cb);
        d = vif.drv_cb.rd_data;
    endtask

    task bus_idle(int unsigned n);
        vif.drv_cb.wr_en <= 1'b0;
        vif.drv_cb.rd_en <= 1'b0;
        repeat (n) @(vif.drv_cb);
    endtask

    task run_phase(uvm_phase phase);
        vif.drv_cb.reset   <= 1'b1;
        vif.drv_cb.wr_en   <= 1'b0;
        vif.drv_cb.rd_en   <= 1'b0;
        vif.drv_cb.addr    <= '0;
        vif.drv_cb.wr_data <= '0;
        repeat (4) @(vif.drv_cb);
        vif.drv_cb.reset <= 1'b0;
        @(vif.drv_cb);

        // The operand buffers have no reset (they are LUT RAM). Fill them with zeros once,
        // so a job that keeps old A values or uses a larger K never reads X.
        for (int kk = 0; kk < `ACCEL_MAXK; kk++) begin
            bus_write(`ACCEL_A + 4 * kk, 0);
            bus_write(`ACCEL_B + 4 * kk, 0);
        end
        bus_idle(1);

        forever begin
            seq_item_port.get_next_item(req);
            drive_job(req);
            seq_item_port.item_done();
            jobs++;
        end
    endtask

    task drive_job(accel_xtn t);
        bit [31:0] d;
        int unsigned n = 0;

        bus_idle(t.gap);
        if (t.reload_a)
            for (int kk = 0; kk < t.k; kk++)
                bus_write(`ACCEL_A + 4 * kk, t.a_word(kk));
        for (int kk = 0; kk < t.k; kk++)
            bus_write(`ACCEL_B + 4 * kk, t.b_word(kk));
        bus_write(`ACCEL_CTRL, `ACCEL_START | (t.clear ? `ACCEL_CLEAR : 0) | t.k);

        // poll busy like software would; on the chosen cycle, try to start again instead
        forever begin
            if (t.poke && n == t.poke_at)
                bus_write(`ACCEL_CTRL, `ACCEL_START | `ACCEL_CLEAR | (t.k % `ACCEL_MAXK + 1));
            else begin
                bus_read(`ACCEL_CTRL, d);
                if (!d[0]) break;
            end
            n++;
            if (n > 2 * `ACCEL_MAXK + 20)
                `uvm_fatal("DRV", "accelerator stuck busy")
        end

        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                bus_read(`ACCEL_C + 4 * (4 * i + j), d);
                t.c[i][j] = d;
            end
        // leave the bus quiet, so a pause before the next item is not seen as reads
        vif.drv_cb.wr_en <= 1'b0;
        vif.drv_cb.rd_en <= 1'b0;
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("DRV", $sformatf("%0d jobs driven", jobs), UVM_LOW)
    endfunction

endclass

class accel_monitor extends uvm_monitor;
    `uvm_component_utils(accel_monitor)

    virtual accel_if.MON vif;
    uvm_analysis_port #(accel_xtn) ap;

    // copies of the operand buffers, built from the writes seen on the bus
    bit [31:0] a_sh [`ACCEL_MAXK];
    bit [31:0] b_sh [`ACCEL_MAXK];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(virtual accel_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "no accel_if in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        accel_xtn    cur;                  // the job in flight, until its 16 results are read
        int          got;                  // results read so far
        bit          a_written;            // A written since the last start
        int unsigned idle, gap;
        bit          seen_write;           // first write of the next job seen (gap recorded)
        bit [1:0]    region;
        bit [5:0]    idx;

        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.reset) begin
                cur = null;
                continue;
            end
            region = vif.mon_cb.addr[9:8];
            idx    = vif.mon_cb.addr[7:2];

            // gap = quiet cycles before the first write of a job
            if (!vif.mon_cb.wr_en && !vif.mon_cb.rd_en)
                idle++;
            else begin
                if (vif.mon_cb.wr_en && !seen_write) begin
                    gap = idle;
                    seen_write = 1;
                end
                idle = 0;
            end

            if (cur != null && vif.mon_cb.busy)
                cur.cycles++;

            if (vif.mon_cb.wr_en) begin
                case (region)
                    2'd1: begin a_sh[idx] = vif.mon_cb.wr_data; a_written = 1; end
                    2'd2: b_sh[idx] = vif.mon_cb.wr_data;
                    2'd0: if (vif.mon_cb.wr_data[8]) begin
                        if (!vif.mon_cb.busy) begin
                            // accepted: the operands are what the buffers hold now
                            cur = accel_xtn::type_id::create("mon_xtn");
                            cur.k        = vif.mon_cb.wr_data[6:0];
                            cur.clear    = vif.mon_cb.wr_data[9];
                            cur.reload_a = a_written;
                            cur.gap      = gap;
                            for (int kk = 0; kk < `ACCEL_MAXK; kk++)
                                for (int i = 0; i < 4; i++) begin
                                    cur.a[i][kk] = (kk < cur.k) ? a_sh[kk][8*i +: 8] : 0;
                                    cur.b[kk][i] = (kk < cur.k) ? b_sh[kk][8*i +: 8] : 0;
                                end
                            got = 0;
                            a_written = 0;
                        end
                        else if (cur != null)
                            cur.poked = 1;
                    end
                    default: ;
                endcase
            end

            if (vif.mon_cb.rd_en && region == 2'd3 && cur != null) begin
                cur.c[vif.mon_cb.addr[5:4]][vif.mon_cb.addr[3:2]] = vif.mon_cb.rd_data;
                if (++got == 16) begin
                    `uvm_info("MON", $sformatf("job: K=%0d clear=%0d cycles=%0d", cur.k, cur.clear, cur.cycles), UVM_HIGH)
                    ap.write(cur);
                    cur = null;
                    seen_write = 0;
                end
            end
        end
    endtask

endclass

class accel_agent extends uvm_agent;
    `uvm_component_utils(accel_agent)

    accel_sequencer seqr;
    accel_driver    drv;
    accel_monitor   mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        mon = accel_monitor::type_id::create("mon", this);
        if (get_is_active() == UVM_ACTIVE) begin
            seqr = accel_sequencer::type_id::create("seqr", this);
            drv  = accel_driver::type_id::create("drv", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE)
            drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction

endclass
