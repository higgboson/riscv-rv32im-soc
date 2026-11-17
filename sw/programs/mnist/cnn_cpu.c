// cnn_cpu.c - the network in plain C, the way the CPU would run it without the accelerator.
// Also compiled on the PC (sw/programs/mnist/host) to check it against the golden model.

#include "cnn.h"
#include "weights.h"

// back to 8 bits and ReLU in one step (see weights.h)
static inline int8_t requant(int32_t acc, int32_t m)
{
    int32_t y = (int32_t)(((int64_t)acc * m + (1 << (CNN_SHIFT - 1))) >> CNN_SHIFT);
    return (int8_t)(y < 0 ? 0 : y > 127 ? 127 : y);
}

void cnn_input(const uint8_t *pixels, int8_t *x)
{
    for (int i = 0; i < 28 * 28; i++)
        x[i] = (int8_t)(pixels[i] >> 1);
}

// 3x3 convolution, ReLU and 2x2 max pooling. Only the conv outputs that the pooling uses
// are computed (for an odd size the last row and column are dropped).
// wt is K x F with K = 9 * C in the order (ky, kx, channel).
static void conv_pool(const int8_t *in, int H, int W, int C, int F,
                      const int8_t *wt, const int32_t *bias, const int32_t *mult, int8_t *out)
{
    int PH = (H - 2) / 2, PW = (W - 2) / 2;
    for (int py = 0; py < PH; py++)
        for (int px = 0; px < PW; px++)
            for (int f = 0; f < F; f++) {
                int8_t best = 0;                     // outputs are >= 0 after ReLU
                for (int d = 0; d < 4; d++) {
                    int oy = 2 * py + (d >> 1), ox = 2 * px + (d & 1);
                    int32_t acc = bias[f];
                    for (int ky = 0; ky < 3; ky++)
                        for (int kx = 0; kx < 3; kx++) {
                            const int8_t *p = in + ((oy + ky) * W + ox + kx) * C;
                            const int8_t *w = wt + (ky * 3 + kx) * C * F + f;
                            for (int c = 0; c < C; c++)
                                acc += p[c] * w[c * F];
                        }
                    int8_t y = requant(acc, mult[f]);
                    if (y > best) best = y;
                }
                out[(py * PW + px) * F + f] = best;
            }
}

void cnn_conv_pool_cpu(const int8_t *in, int H, int W, int C, int F, const int8_t *wt,
                       const int32_t *bias, const int32_t *mult, int8_t *out)
{
    conv_pool(in, H, W, C, F, wt, bias, mult, out);
}

void conv1_cpu(const int8_t *x,  int8_t *p1) { conv_pool(x,  28, 28, 1,  8, w1t, b1, m1, p1); }
void conv2_cpu(const int8_t *p1, int8_t *p2) { conv_pool(p1, 13, 13, 8, 16, w2t, b2, m2, p2); }

void fc_cpu(const int8_t *p2, int32_t *scores)
{
    for (int o = 0; o < 10; o++) {
        int32_t acc = b3[o];
        for (int k = 0; k < 400; k++)
            acc += p2[k] * w3t[k * 12 + o];
        scores[o] = acc;
    }
}

int cnn_argmax(const int32_t *scores)
{
    int best = 0;
    for (int i = 1; i < 10; i++)
        if (scores[i] > scores[best]) best = i;
    return best;
}
