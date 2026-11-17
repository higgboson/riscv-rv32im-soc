// tb_accel.v - unit test for the matrix-multiply accelerator, through its registers
//
// Each test picks a random K (1..64) and random INT8 matrices A (4xK) and B (Kx4), with
// extra weight on the edge values -128, 127, -1, 0. It writes them to the accelerator,
// starts it, waits for busy = 0 and compares all 16 results with a sum computed here.
// Some tests skip "clear" and must add onto the previous C (accumulate mode), and some
// start the next run straight away (back-to-back). It also checks the run takes K + 6 cycles,
// and the output stage: with random BIAS and MULT, the four Q words must equal
// clamp((C + bias) * mult + 2^23 >> 24, 0, 127) per element, ready at most 8 cycles later.
//
// +TESTS=<n> number of tests (default 500), +SEED=<s> random seed

`timescale 1ns/1ns
module tb_accel;

reg         clk = 0, reset = 1, wr_en = 0;
reg  [31:0] addr = 0, wr_data = 0;
wire [31:0] rd_data;

matmul_accel dut (.clk(clk), .reset(reset), .wr_en(wr_en), .addr(addr),
                  .wr_data(wr_data), .rd_data(rd_data));

always #5 clk = ~clk;

integer seed, ntests, test, k, kk, i, j, errors = 0, cycles;
integer expect_c [0:3][0:3];
reg signed [7:0] a [0:3][0:63];
reg signed [7:0] b [0:63][0:3];
reg clear_first;
reg signed [31:0] bias [0:3];
reg        [17:0] mult [0:3];
reg signed [63:0] p, r;
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
    for (i = 0; i < 4; i = i + 1)
        for (j = 0; j < 4; j = j + 1)
            expect_c[i][j] = 0;
    repeat (3) @(negedge clk);
    reset = 0;

    for (test = 0; test < ntests; test = test + 1) begin
        k = 1 + ($random(seed) & 63);
        if (test < 3) k = (test == 0) ? 1 : (test == 1) ? 64 : 4;    // corners first
        clear_first = (test == 0) || (($random(seed) & 3) != 0);

        for (kk = 0; kk < k; kk = kk + 1)
            for (i = 0; i < 4; i = i + 1) begin
                a[i][kk] = rand_int8(0);
                b[kk][i] = rand_int8(0);
            end

        for (kk = 0; kk < k; kk = kk + 1) begin
            write_reg(32'h2000_0100 + 4 * kk, {a[3][kk], a[2][kk], a[1][kk], a[0][kk]});
            write_reg(32'h2000_0200 + 4 * kk, {b[kk][3], b[kk][2], b[kk][1], b[kk][0]});
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
        $display("accelerator test: %0d tests PASS", ntests);
    else
        $display("accelerator test: FAIL (%0d errors)", errors);
    $finish;
end

endmodule
