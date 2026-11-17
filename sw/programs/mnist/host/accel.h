// accel.h (PC version) - a software stand-in for the accelerator, so cnn_accel.c can be
// checked on the PC. Same registers and behaviour as code/accel/matmul_accel.v: after a
// write to CTRL with "start", the first busy check runs the whole tile.
#ifndef ACCEL_H
#define ACCEL_H
#include <stdint.h>

#define ACCEL_START    (1u << 8)
#define ACCEL_CLEAR    (1u << 9)
#define ACCEL_GATHER_A (1u << 10)
#define ACCEL_GATHER_B (1u << 11)
#define ACCEL_LAYER    (1u << 12)
#define ACCEL_MAXK   64
#define ACCEL_QREADY 2u

extern uint32_t accel_ctrl, ACCEL_A[64], ACCEL_B[64], ACCEL_Q[4], ACCEL_MULT[4];
extern uint32_t ACCEL_GA[4], ACCEL_GB[4], ACCEL_L[7];
extern char     accel_anchor;              // PC addresses are offsets from this byte
#define ACCEL_ADDR(p) ((uint32_t)((char *)(p) - &accel_anchor))
extern int32_t  ACCEL_C[16], ACCEL_BIAS[4];
int accel_run(void);

#define ACCEL_CTRL   accel_ctrl
#define ACCEL_BUSY   (accel_run(), 0u)

static inline void accel_conv_layer(const int8_t *in, int W, int C, int F, int PH, int PW,
                                    const int8_t *wt, const int32_t *bias, const int32_t *mult,
                                    int8_t *out)
{
    int rows_per_run = ACCEL_MAXK / (3 * C);
    if (rows_per_run > 3) rows_per_run = 3;
    ACCEL_L[0] = ACCEL_ADDR(in);   ACCEL_L[1] = ACCEL_ADDR(out);  ACCEL_L[2] = ACCEL_ADDR(wt);
    ACCEL_L[3] = ACCEL_ADDR(bias); ACCEL_L[4] = ACCEL_ADDR(mult);
    ACCEL_L[5] = (uint32_t)W | (uint32_t)C << 8 | (uint32_t)F << 16 | (uint32_t)PH << 24;
    ACCEL_L[6] = (uint32_t)PW | (uint32_t)rows_per_run << 8;
    accel_ctrl = ACCEL_LAYER;
    while (ACCEL_CTRL & ACCEL_BUSY)
        ;
}

static inline void accel_gather_desc(uint32_t *d, const void *base, int n0, int n1, int n2,
                                     int lanes, int s0, int s1, int s2, int sl)
{
    d[0] = ACCEL_ADDR(base);
    d[1] = (uint32_t)n0 | (uint32_t)n1 << 8 | (uint32_t)n2 << 16 | (uint32_t)lanes << 24;
    d[2] = (uint32_t)s0 | (uint32_t)s1 << 16;
    d[3] = (uint32_t)s2 | (uint32_t)sl << 16;
}
#endif
