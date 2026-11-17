// accel.h - driver for the INT8 matrix-multiply accelerator (code/accel/matmul_accel.v)
//
// accel_matmul computes C = A x B for INT8 A (M x K) and B (K x N), INT32 C (M x N),
// with M and N multiples of 4 and K up to 64.
//
// Layout: A is passed TRANSPOSED (at[k][i] = A[i][k]) and B as usual (row-major).
// Then the 4 values the accelerator needs at step k are 4 neighbouring bytes in memory:
// A[i..i+3][k] = at[k][i..i+3] and B[k][j..j+3] = b[k][j..j+3], so each step is a
// single 32-bit load instead of four byte loads. Neural-network weights are often kept
// transposed for exactly this reason.

#ifndef ACCEL_H
#define ACCEL_H

#include <stdint.h>

#define ACCEL_BASE   0x20000000u
#define ACCEL_CTRL   (*(volatile uint32_t *)(ACCEL_BASE + 0x000))
#define ACCEL_A      ((volatile uint32_t *)(ACCEL_BASE + 0x100))
#define ACCEL_B      ((volatile uint32_t *)(ACCEL_BASE + 0x200))
#define ACCEL_C      ((volatile int32_t  *)(ACCEL_BASE + 0x300))
#define ACCEL_Q      ((volatile uint32_t *)(ACCEL_BASE + 0x340))   // C back in INT8, 1 row per word
#define ACCEL_BIAS   ((volatile int32_t  *)(ACCEL_BASE + 0x380))
#define ACCEL_MULT   ((volatile uint32_t *)(ACCEL_BASE + 0x3C0))

#define ACCEL_GA     ((volatile uint32_t *)(ACCEL_BASE + 0x010))   // gather descriptor for A
#define ACCEL_GB     ((volatile uint32_t *)(ACCEL_BASE + 0x020))   // and for B

#define ACCEL_START    (1u << 8)
#define ACCEL_CLEAR    (1u << 9)
#define ACCEL_GATHER_A (1u << 10)
#define ACCEL_GATHER_B (1u << 11)
#define ACCEL_LAYER    (1u << 12)
#define ACCEL_L      ((volatile uint32_t *)(ACCEL_BASE + 0x030))   // layer engine descriptor
#define ACCEL_BUSY   1u
#define ACCEL_QREADY 2u
#define ACCEL_MAXK   64

// address of a variable as the gather engine sees it
#define ACCEL_ADDR(p) ((uint32_t)(uintptr_t)(p))

// gather descriptor: step k = (i2, i1, i0), i0 innermost, lane i reads
// base + i2*s2 + i1*s1 + i0*s0 + i*sl (see code/accel/matmul_accel.v)
static inline void accel_gather_desc(volatile uint32_t *d, const void *base,
                                     int n0, int n1, int n2, int lanes,
                                     int s0, int s1, int s2, int sl)
{
    d[0] = ACCEL_ADDR(base);
    d[1] = (uint32_t)n0 | (uint32_t)n1 << 8 | (uint32_t)n2 << 16 | (uint32_t)lanes << 24;
    d[2] = (uint32_t)s0 | (uint32_t)s1 << 16;
    d[3] = (uint32_t)s2 | (uint32_t)sl << 16;
}

// A whole 3x3 convolution layer with bias, scale, ReLU and 2x2 max pooling on the layer
// engine. in: (2*PH+2 or more) x W x C, out: PH x PW x F, both INT8, out 4-byte aligned;
// wt: K x F (K = 9*C, order ky, kx, channel). Limits: F a multiple of 4 up to 16,
// 2*PW <= 32, C <= 21.
static inline void accel_conv_layer(const int8_t *in, int W, int C, int F, int PH, int PW,
                                    const int8_t *wt, const int32_t *bias, const int32_t *mult,
                                    int8_t *out)
{
    int rows_per_run = ACCEL_MAXK / (3 * C);
    if (rows_per_run > 3) rows_per_run = 3;
    ACCEL_L[0] = ACCEL_ADDR(in);
    ACCEL_L[1] = ACCEL_ADDR(out);
    ACCEL_L[2] = ACCEL_ADDR(wt);
    ACCEL_L[3] = ACCEL_ADDR(bias);
    ACCEL_L[4] = ACCEL_ADDR(mult);
    ACCEL_L[5] = (uint32_t)W | (uint32_t)C << 8 | (uint32_t)F << 16 | (uint32_t)PH << 24;
    ACCEL_L[6] = (uint32_t)PW | (uint32_t)rows_per_run << 8;
    ACCEL_CTRL = ACCEL_LAYER;
    while (ACCEL_CTRL & ACCEL_BUSY)
        ;
}

static inline void accel_matmul(int m, int n, int k,
                                const int8_t *at,   // K x M, transposed A
                                const int8_t *b,    // K x N
                                int32_t *c)         // M x N
{
    for (int i0 = 0; i0 < m; i0 += 4) {
        // the A tile (rows i0..i0+3) is reused for every column tile, so load it once
        for (int kk = 0; kk < k; kk++)
            ACCEL_A[kk] = *(const uint32_t *)&at[kk * m + i0];

        for (int j0 = 0; j0 < n; j0 += 4) {
            for (int kk = 0; kk < k; kk++)
                ACCEL_B[kk] = *(const uint32_t *)&b[kk * n + j0];

            ACCEL_CTRL = ACCEL_START | ACCEL_CLEAR | (uint32_t)k;
            while (ACCEL_CTRL & ACCEL_BUSY)
                ;

            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    c[(i0 + i) * n + j0 + j] = ACCEL_C[i * 4 + j];
        }
    }
}

#endif
