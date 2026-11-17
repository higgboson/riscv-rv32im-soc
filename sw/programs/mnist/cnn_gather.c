// cnn_gather.c - the network with the accelerator fetching its own data.
//
// Same arithmetic as cnn_accel.c, but the CPU no longer builds the im2col patches or copies
// weights into the array: it describes where they are (a gather descriptor) and the gather
// engine reads them from data memory, then starts the run. Per 4x4 tile the CPU writes a few
// registers, waits, and stores the 4 result words the output stage has already turned into
// INT8. Pooling is still done by the CPU.

#include "cnn.h"
#include "weights.h"
#include "accel.h"

static inline void wait_idle(void)
{
    while (ACCEL_CTRL & ACCEL_BUSY)
        ;
}

static void conv_pool(const int8_t *in, int H, int W, int C, int F,
                      const int8_t *wt, const int32_t *bias, const int32_t *mult, int8_t *out)
{
    int PH = (H - 2) / 2, PW = (W - 2) / 2;
    int OW = 2 * PW;
    // a run has at most 64 steps: split the 3x3xC patch by kernel rows (conv2: 2 rows + 1 row)
    int rows_per_run = ACCEL_MAXK / (3 * C);
    if (rows_per_run > 3) rows_per_run = 3;
    int one_run = rows_per_run == 3;
    static int8_t rows[2][26 * 16] __attribute__((aligned(4)));

    for (int py = 0; py < PH; py++) {
        for (int d = 0; d < 2; d++) {
            int oy = 2 * py + d;
            for (int x0 = 0; x0 < OW; x0 += 4) {
                int lanes = OW - x0 < 4 ? OW - x0 : 4;
                for (int f0 = 0; f0 < F; f0 += 4) {
                    for (int j = 0; j < 4; j++) {
                        ACCEL_BIAS[j] = bias[f0 + j];
                        ACCEL_MULT[j] = (uint32_t)mult[f0 + j];
                    }
                    for (int ky0 = 0; ky0 < 3; ky0 += rows_per_run) {
                        int nr = 3 - ky0 < rows_per_run ? 3 - ky0 : rows_per_run;
                        int steps = nr * 3 * C, k0 = ky0 * 3 * C;
                        uint32_t cmd = ACCEL_START | ACCEL_GATHER_B | (uint32_t)steps;
                        // A: patches of pixels x0 .. x0+3 (channel, kx, ky); kept in the
                        // array between filter groups when the whole patch fits in one run
                        if (!one_run || f0 == 0) {
                            accel_gather_desc(ACCEL_GA, &in[((oy + ky0) * W + x0) * C],
                                              C, 3, nr, lanes, 1, C, W * C, C);
                            cmd |= ACCEL_GATHER_A;
                        }
                        // B: weights of filters f0 .. f0+3, one aligned word per step
                        accel_gather_desc(ACCEL_GB, &wt[k0 * F + f0], steps, 1, 1, 4, F, 0, 0, 1);
                        if (ky0 == 0) cmd |= ACCEL_CLEAR;
                        ACCEL_CTRL = cmd;
                        wait_idle();
                    }
                    while (!(ACCEL_CTRL & ACCEL_QREADY))
                        ;
                    for (int i = 0; i < lanes; i++)
                        *(uint32_t *)&rows[d][(x0 + i) * F + f0] = ACCEL_Q[i];
                }
            }
        }
        for (int px = 0; px < PW; px++)              // 2x2 max pooling of the two rows
            for (int f = 0; f < F; f++) {
                int8_t a = rows[0][(2 * px) * F + f], b = rows[0][(2 * px + 1) * F + f];
                int8_t c = rows[1][(2 * px) * F + f], e = rows[1][(2 * px + 1) * F + f];
                int8_t m = a > b ? a : b;
                if (c > m) m = c;
                if (e > m) m = e;
                out[(py * PW + px) * F + f] = m;
            }
    }
}

void conv1_gather(const int8_t *x,  int8_t *p1) { conv_pool(x,  28, 28, 1,  8, w1t, b1, m1, p1); }
void conv2_gather(const int8_t *p1, int8_t *p2) { conv_pool(p1, 13, 13, 8, 16, w2t, b2, m2, p2); }

// Fully connected: rows = 4 outputs (aligned words of w3t), one column = the 400 inputs
void fc_gather(const int8_t *p2, int32_t *scores)
{
    for (int o0 = 0; o0 < 12; o0 += 4) {
        for (int k0 = 0; k0 < 400; k0 += ACCEL_MAXK) {
            int kn = 400 - k0 < ACCEL_MAXK ? 400 - k0 : ACCEL_MAXK;
            accel_gather_desc(ACCEL_GA, &w3t[k0 * 12 + o0], kn, 1, 1, 4, 12, 0, 0, 1);
            accel_gather_desc(ACCEL_GB, &p2[k0], kn, 1, 1, 1, 1, 0, 0, 1);
            ACCEL_CTRL = ACCEL_START | ACCEL_GATHER_A | ACCEL_GATHER_B |
                         (k0 == 0 ? ACCEL_CLEAR : 0) | (uint32_t)kn;
            wait_idle();
        }
        for (int i = 0; i < 4 && o0 + i < 10; i++)
            scores[o0 + i] = ACCEL_C[i * 4] + b3[o0 + i];
    }
}
