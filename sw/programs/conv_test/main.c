// conv_test - random layers on the accelerator's layer engine, checked byte for byte against
// the plain C layer (cnn_conv_pool_cpu). Random shapes cover the engine's corners: 1 to 13
// channels and the C = 21 limit (several pieces per patch), 4 to 16 filters, a last group of
// fewer than 4 pixels, odd input sizes (last row / column unused) and the widest row (2*PW = 32).
// Random data, weights, biases and scales.

#include "console.h"
#include "accel.h"
#include "cnn.h"

// cnn_cpu.c also holds the MNIST layers, which need the network's weights; this test does not
// call them, so empty stand-ins are enough
const int8_t  w1t[9 * 8], w2t[72 * 16], w3t[400 * 12];
const int32_t b1[8], m1[8], b2[16], m2[16], b3[10];

#define N_TESTS 24
static int8_t  in[4200]            __attribute__((aligned(4)));
static int8_t  wt[9 * 21 * 16]     __attribute__((aligned(4)));
static int32_t bias[16], mult[16];
static int8_t  out_hw[1024]        __attribute__((aligned(4)));
static int8_t  out_sw[1024]        __attribute__((aligned(4)));

static uint32_t seed = 12345;
static uint32_t rnd(void) { seed = seed * 1664525u + 1013904223u; return seed >> 8; }
static int range(int lo, int hi) { return lo + (int)(rnd() % (uint32_t)(hi - lo + 1)); }

int main(void)
{
    int failed = 0;
    for (int t = 0; t < N_TESTS; t++) {
        int C, F = 4 * range(1, 4), PH, PW;
        if (t == 0)      { C = 1;  PW = 16; PH = 1; }           // widest row: 32 conv columns
        else if (t == 1) { C = 21; PW = 2;  PH = 1; }           // 3 pieces of 63 steps
        else             { C = range(1, 13); PW = range(1, 8); PH = range(1, 2); }
        int W = 2 * PW + 2 + range(0, 1), H = 2 * PH + 2 + range(0, 1);   // sometimes odd
        if (H * W * C > (int)sizeof in) { W = 2 * PW + 2; H = 2 * PH + 2; }

        for (int i = 0; i < H * W * C; i++)   in[i] = (int8_t)range(0, 127);
        for (int i = 0; i < 9 * C * F; i++)   wt[i] = (int8_t)range(-127, 127);
        for (int f = 0; f < F; f++) {
            bias[f] = range(-4000, 4000);
            mult[f] = range(2000, 60000);                       // results spread over 0..127
        }
        for (int i = 0; i < PH * PW * F; i++) { out_hw[i] = -1; out_sw[i] = -2; }

        cnn_conv_pool_cpu(in, H, W, C, F, wt, bias, mult, out_sw);
        accel_conv_layer(in, W, C, F, PH, PW, wt, bias, mult, out_hw);

        int bad = 0, nonzero = 0;
        for (int i = 0; i < PH * PW * F; i++) {
            bad += out_hw[i] != out_sw[i];
            nonzero += out_sw[i] != 0;
        }
        print_str("test "); print_dec(t);
        print_str(": H "); print_dec(H); print_str(" W "); print_dec(W);
        print_str(" C "); print_dec(C); print_str(" F "); print_dec(F);
        print_str(" -> "); print_dec(PH); print_str("x"); print_dec(PW);
        print_str(", "); print_dec(PH * PW * F); print_str(" outputs ("); print_dec(nonzero);
        print_str(" non-zero): "); print_str(bad ? "MISMATCH\n" : "ok\n");
        failed += bad != 0;
    }
    print_str(failed ? "LAYER ENGINE TEST FAILED\n" : "layer engine: all random layers match the CPU\n");
    uart_flush();
    return failed;
}
