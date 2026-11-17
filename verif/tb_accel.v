// tb_accel.v - unit test for the matrix-multiply accelerator, through its registers
//
// Each test picks a random K (1..64) and random INT8 matrices A (4xK) and B (Kx4), with
// extra weight on the edge values -128, 127, -1, 0. It writes them to the accelerator,
// starts it, waits for busy = 0 and compares all 16 results with a sum computed here.
// Some tests skip "clear" and must add onto the previous C (accumulate mode), and some
// start the next run straight away (back-to-back). It also checks the run takes K + 6 cycles,
// and the output stage: with random BIAS and MULT, the four Q words must equal
// clamp((C + bias) * mult + 2^23 >> 24, 0, 127) per element, ready at most 8 cycles later.
// Half of the tests load A and B with the gather engine instead, from a memory model with
// random contents: random loop counts, strides, lane counts and alignments (so both the
// byte-by-byte and the whole-word path are used), as one command (gather A, gather B, run)
// or as separate commands. The expected A and B are worked out here from the descriptors.
//
// +TESTS=<n> number of tests (default 500), +SEED=<s> random seed

`timescale 1ns/1ns
module tb_accel;

reg         clk = 0, reset = 1, wr_en = 0;
reg  [31:0] addr = 0, wr_data = 0;
wire [31:0] rd_data;

wire [31:0] mem_addr;
reg  [31:0] mem_rdata;
reg  [7:0]  tbmem [0:16383];                 // data memory model: word one cycle after the address
always @(posedge clk)
    mem_rdata <= {tbmem[{mem_addr[13:2], 2'd3}], tbmem[{mem_addr[13:2], 2'd2}],
                  tbmem[{mem_addr[13:2], 2'd1}], tbmem[{mem_addr[13:2], 2'd0}]};

matmul_accel dut (.clk(clk), .reset(reset), .wr_en(wr_en), .addr(addr),
                  .wr_data(wr_data), .rd_data(rd_data),
                  .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_we(), .mem_wdata());

always #5 clk = ~clk;

integer seed, ntests, test, k, kk, i, j, errors = 0, cycles;
integer expect_c [0:3][0:3];
reg signed [7:0] a [0:3][0:63];
reg signed [7:0] b [0:63][0:3];
reg clear_first;
reg signed [31:0] bias [0:3];
reg        [17:0] mult [0:3];
reg signed [63:0] p, r;
integer use_dma, mode, n0, n1, n2, i0, i1, i2, ndma = 0;
integer base [0:1], s0 [0:1], s1 [0:1], s2 [0:1], sl [0:1], lanes [0:1];

// value lane i of step (i2, i1, i0) gets from descriptor d
function [7:0] gathered(input integer d, input integer i2, input integer i1, input integer i0,
                        input integer i);
    begin
        if (i >= lanes[d]) gathered = 8'd0;
        else gathered = tbmem[(base[d] + i2 * s2[d] + i1 * s1[d] + i0 * s0[d] + i * sl[d]) & 16383];
    end
endfunction

task set_desc(input integer d);
    begin
        write_reg(32'h2000_0010 + 16 * d, base[d]);
        write_reg(32'h2000_0014 + 16 * d, (lanes[d] << 24) | (n2 << 16) | (n1 << 8) | n0);
        write_reg(32'h2000_0018 + 16 * d, (s1[d] << 16) | s0[d]);
        write_reg(32'h2000_001C + 16 * d, (sl[d] << 16) | s2[d]);
    end
endtask

task wait_idle;
    begin
        addr = 32'h2000_0000;
        #1;
        while (rd_data[0]) @(negedge clk);
    end
endtask
reg        [7:0]  qe;
integer qwait;

// mostly random, sometimes an edge value
function [7:0] rand_int8(input integer dummy);
    integer r;
    begin
        r = $random(seed) & 7;
        case (r)
            0: rand_int8 = 8'h80;    // -128
            1: rand_int8 = 8'h7F;    //  127
            2: rand_int8 = 8'hFF;    //   -1
            3: rand_int8 = 8'h00;
            default: rand_int8 = $random(seed);
        endcase
    end
endfunction

task write_reg(input [31:0] a_addr, input [31:0] data);
    begin
        @(negedge clk);
        addr = a_addr; wr_data = data; wr_en = 1;
        @(negedge clk);
        wr_en = 0;
    end
endtask

initial begin
    if (!$value$plusargs("TESTS=%d", ntests)) ntests = 500;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    for (i = 0; i < 16384; i = i + 1) tbmem[i] = rand_int8(0);
    for (i = 0; i < 4; i = i + 1)
        for (j = 0; j < 4; j = j + 1)
            expect_c[i][j] = 0;
    repeat (3) @(negedge clk);
    reset = 0;

    for (test = 0; test < ntests; test = test + 1) begin
        k = 1 + ($random(seed) & 63);
        if (test < 3) k = (test == 0) ? 1 : (test == 1) ? 64 : 4;    // corners first
        clear_first = (test == 0) || (($random(seed) & 3) != 0);

        use_dma = (test >= 3) && ($random(seed) & 1);
        if (use_dma) begin
            // loop counts with n0 * n1 * n2 <= 64; descriptors A (0) and B (1) share them
            n0 = 1 + ($random(seed) & 15);  n1 = 1 + ($random(seed) & 3);  n2 = 1 + ($random(seed) & 3);
            while (n0 * n1 * n2 > 64) n0 = n0 - 1;
            k = n0 * n1 * n2;
            for (i = 0; i < 2; i = i + 1) begin
                lanes[i] = 1 + ($random(seed) & 3);
                mode = $random(seed) & 3;
                if (mode == 2) begin               // 4 bytes in a row at any alignment (conv1)
                    lanes[i] = 4;  sl[i] = 1;  base[i] = $random(seed) & 16383;
                    s0[i] = $random(seed) & 7;  s1[i] = $random(seed) & 63;  s2[i] = $random(seed) & 511;
                end else if (mode < 2) begin       // word path: 4 bytes in a row, aligned
                    lanes[i] = 4;  sl[i] = 1;  base[i] = ($random(seed) & 4095) * 4;
                    s0[i] = 4 * ($random(seed) & 7); s1[i] = 4 * ($random(seed) & 31); s2[i] = 4 * ($random(seed) & 255);
                end else begin
                    sl[i] = $random(seed) & 31;  base[i] = $random(seed) & 16383;
                    s0[i] = $random(seed) & 15;  s1[i] = $random(seed) & 127;  s2[i] = $random(seed) & 1023;
                end
                base[i] = base[i] | 32'h0001_0000;  // a data-memory address as the CPU sees it
            end
            kk = 0;
            for (i2 = 0; i2 < n2; i2 = i2 + 1)
                for (i1 = 0; i1 < n1; i1 = i1 + 1)
                    for (i0 = 0; i0 < n0; i0 = i0 + 1) begin
                        for (i = 0; i < 4; i = i + 1) begin
                            a[i][kk] = gathered(0, i2, i1, i0, i);
                            b[kk][i] = gathered(1, i2, i1, i0, i);
                        end
                        kk = kk + 1;
                    end
            set_desc(0);
            set_desc(1);
        end else begin
            for (kk = 0; kk < k; kk = kk + 1)
                for (i = 0; i < 4; i = i + 1) begin
                    a[i][kk] = rand_int8(0);
                    b[kk][i] = rand_int8(0);
                end

            for (kk = 0; kk < k; kk = kk + 1) begin
                write_reg(32'h2000_0100 + 4 * kk, {a[3][kk], a[2][kk], a[1][kk], a[0][kk]});
                write_reg(32'h2000_0200 + 4 * kk, {b[kk][3], b[kk][2], b[kk][1], b[kk][0]});
            end
        end

        // output stage settings: scales around the useful range, sometimes extreme
        for (j = 0; j < 4; j = j + 1) begin
            bias[j] = (($random(seed) & 3) == 0) ? $random(seed) : ($random(seed) % 65536);
            mult[j] = (($random(seed) & 3) == 0) ? $random(seed) : (16384 + ($random(seed) & 131071));
            write_reg(32'h2000_0380 + 4 * j, bias[j]);
            write_reg(32'h2000_03C0 + 4 * j, {14'b0, mult[j]});
        end

        // reference
        for (i = 0; i < 4; i = i + 1)
            for (j = 0; j < 4; j = j + 1) begin
                if (clear_first) expect_c[i][j] = 0;
                for (kk = 0; kk < k; kk = kk + 1)
                    expect_c[i][j] = expect_c[i][j] + a[i][kk] * b[kk][j];
            end

        if (use_dma) begin
            ndma = ndma + 1;
            mode = $random(seed) & 3;
            if (mode == 0) begin                  // gather A, then B, then run, as separate commands
                write_reg(32'h2000_0000, 1 << 10);                       wait_idle;
                write_reg(32'h2000_0000, 1 << 11);                       wait_idle;
                write_reg(32'h2000_0000, (clear_first << 9) | (1 << 8) | k);   wait_idle;
            end else if (mode == 1) begin         // A on its own, then B and the run together
                write_reg(32'h2000_0000, 1 << 10);                       wait_idle;
                write_reg(32'h2000_0000, (1 << 11) | (clear_first << 9) | (1 << 8) | k);  wait_idle;
            end else begin                        // everything in one command
                write_reg(32'h2000_0000, (3 << 10) | (clear_first << 9) | (1 << 8) | k);  wait_idle;
            end
        end else begin
        // start, then count cycles until busy drops
        @(negedge clk);
        addr = 32'h2000_0000; wr_data = (clear_first << 9) | (1 << 8) | k; wr_en = 1;
        @(negedge clk);
        wr_en = 0;
        cycles = 1;
        while (rd_data[0]) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (cycles != k + 7) begin
            $display("test %0d: K=%0d took %0d cycles, expected %0d", test, k, cycles, k + 7);
            errors = errors + 1;
        end
        end

        for (i = 0; i < 4; i = i + 1)
            for (j = 0; j < 4; j = j + 1) begin
                addr = 32'h2000_0300 + 16 * i + 4 * j;
                #1;
                if ($signed(rd_data) !== expect_c[i][j]) begin
                    if (errors < 10)
                        $display("test %0d: K=%0d clear=%0d C[%0d][%0d] = %0d, expected %0d",
                                 test, k, clear_first, i, j, $signed(rd_data), expect_c[i][j]);
                    errors = errors + 1;
                end
            end

        // Q: wait for "ready" (CTRL bit 1), then check the four packed rows
        addr = 32'h2000_0000;
        qwait = 0;
        #1;
        while (!rd_data[1] && qwait < 20) begin
            @(negedge clk);
            qwait = qwait + 1;
        end
        if (qwait > 8) begin
            $display("test %0d: Q not ready after %0d cycles", test, qwait);
            errors = errors + 1;
        end
        for (i = 0; i < 4; i = i + 1) begin
            addr = 32'h2000_0340 + 4 * i;
            #1;
            for (j = 0; j < 4; j = j + 1) begin
                p  = ($signed(expect_c[i][j]) + $signed(bias[j])) * $signed({46'b0, mult[j]});
                r  = (p + 64'sd8388608) >>> 24;
                qe = (r < 0) ? 8'd0 : (r > 127) ? 8'd127 : r[7:0];
                if (rd_data[8*j +: 8] !== qe) begin
                    if (errors < 10)
                        $display("test %0d: Q[%0d][%0d] = %0d, expected %0d (C=%0d bias=%0d mult=%0d)",
                                 test, i, j, rd_data[8*j +: 8], qe, expect_c[i][j], bias[j], mult[j]);
                    errors = errors + 1;
                end
            end
        end
    end

    if (errors == 0)
        $display("accelerator test: %0d tests PASS (%0d with the gather engine)", ntests, ndma);
    else
        $display("accelerator test: FAIL (%0d errors)", errors);
    $finish;
end

endmodule
