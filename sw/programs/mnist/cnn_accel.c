// cnn_accel.c - the same network with the matrix multiplications on the systolic array.
//
// A convolution becomes a matrix multiply ("im2col"): each output pixel is one row of A
// (its 3x3xC input patch), each filter is one column of B, so C[pixel][filter] is the
// convolution result. The array takes 4 pixels x 4 filters at a time. Sums longer than
// 64 steps (conv2 has 72) are split in pieces that the array adds up ("no clear").
// The CPU builds the patches, adds the bias and does requantisation and pooling.

#include "cnn.h"
#include "weights.h"
#include "accel.h"

static inline int8_t requant(int32_t acc, int32_t m)
{
    int32_t y = (int32_t)(((int64_t)acc * m + (1 << (CNN_SHIFT - 1))) >> CNN_SHIFT);
    return (int8_t)(y < 0 ? 0 : y > 127 ? 127 : y);
}

static inline void run(int k, int clear)
{
    ACCEL_CTRL = ACCEL_START | (clear ? ACCEL_CLEAR : 0) | (uint32_t)k;
    while (ACCEL_CTRL & ACCEL_BUSY)
        ;
}

static void conv_pool(const int8_t *in, int H, int W, int C, int F,
                      const int8_t *wt, const int32_t *bias, const int32_t *mult, int8_t *out)
{
    int K  = 9 * C;
    int PH = (H - 2) / 2, PW = (W - 2) / 2;
    int OW = 2 * PW;                                 // conv columns the pooling uses
    static int8_t   rows[2][26 * 16];                // two conv output rows, OW x F each
    static uint32_t a_words[72];                     // A for 4 pixels: one word per step k

    for (int py = 0; py < PH; py++) {
        for (int d = 0; d < 2; d++) {
            int oy = 2 * py + d;
            for (int x0 = 0; x0 < OW; x0 += 4) {
                // im2col: step k = (ky, kx, c); byte i of the word = pixel x0 + i
                int k = 0;
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++)
                        for (int c = 0; c < C; c++, k++) {
                            uint32_t w = 0;
                            for (int i = 0; i < 4; i++)
                                if (x0 + i < OW)
                                    w |= (uint32_t)(uint8_t)in[((oy + ky) * W + x0 + i + kx) * C + c] << (8 * i);
                            a_words[k] = w;
                        }
                for (int f0 = 0; f0 < F; f0 += 4) {
                    for (int k0 = 0; k0 < K; k0 += ACCEL_MAXK) {
                        int kn = K - k0 < ACCEL_MAXK ? K - k0 : ACCEL_MAXK;
                        // A stays in the array between filter groups when it fits in one run
                        if (K > ACCEL_MAXK || f0 == 0)
                            for (int j = 0; j < kn; j++) ACCEL_A[j] = a_words[k0 + j];
                        for (int j = 0; j < kn; j++)
                            ACCEL_B[j] = *(const uint32_t *)&wt[(k0 + j) * F + f0];
                        run(kn, k0 == 0);
                    }
                    for (int i = 0; i < 4 && x0 + i < OW; i++)
                        for (int j = 0; j < 4; j++)
                            rows[d][(x0 + i) * F + f0 + j] =
                                requant(ACCEL_C[i * 4 + j] + bias[f0 + j], mult[f0 + j]);
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

void conv1_accel(const int8_t *x,  int8_t *p1) { conv_pool(x,  28, 28, 1,  8, w1t, b1, m1, p1); }
void conv2_accel(const int8_t *p1, int8_t *p2) { conv_pool(p1, 13, 13, 8, 16, w2t, b2, m2, p2); }

// Fully connected: the 10 outputs are the rows (A = the weights, 4 outputs per tile) and
// the 400 inputs are one column of B. Only 1 of the 4 columns is used, so this layer runs
// the array at a quarter of its speed; it is small enough not to matter.
void fc_accel(const int8_t *p2, int32_t *scores)
{
    for (int o0 = 0; o0 < 12; o0 += 4) {
        for (int k0 = 0; k0 < 400; k0 += ACCEL_MAXK) {
            int kn = 400 - k0 < ACCEL_MAXK ? 400 - k0 : ACCEL_MAXK;
            for (int j = 0; j < kn; j++) {
                ACCEL_A[j] = *(const uint32_t *)&w3t[(k0 + j) * 12 + o0];
                ACCEL_B[j] = (uint8_t)p2[k0 + j];
            }
            run(kn, k0 == 0);
        }
        for (int i = 0; i < 4 && o0 + i < 10; i++)
            scores[o0 + i] = ACCEL_C[i * 4] + b3[o0 + i];
    }
}
