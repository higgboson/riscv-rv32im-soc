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

#define ACCEL_START  (1u << 8)
#define ACCEL_CLEAR  (1u << 9)
#define ACCEL_BUSY   1u
#define ACCEL_MAXK   64

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
