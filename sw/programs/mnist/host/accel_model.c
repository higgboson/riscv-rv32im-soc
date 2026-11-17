#include "accel.h"
uint32_t accel_ctrl, ACCEL_A[128], ACCEL_B[128], ACCEL_Q[4], ACCEL_MULT[4];
uint32_t ACCEL_GA[4], ACCEL_GB[4], ACCEL_L[7];
char     accel_anchor;
// read through a volatile so the compiler cannot assume where the addresses point
static char *volatile anchor = &accel_anchor;

static void gather(const uint32_t *d, uint32_t *buf)
{
    int n0 = d[1] & 255, n1 = (d[1] >> 8) & 255, n2 = (d[1] >> 16) & 255, lanes = (d[1] >> 24) & 7;
    int s0 = d[2] & 0xffff, s1 = d[2] >> 16, s2 = d[3] & 0xffff, sl = d[3] >> 16;
    int k = 0;
    for (int i2 = 0; i2 < n2; i2++)
        for (int i1 = 0; i1 < n1; i1++)
            for (int i0 = 0; i0 < n0; i0++, k++) {
                uint32_t w = 0;
                for (int i = 0; i < lanes; i++) {
                    const char *p = anchor + (int32_t)d[0] + i2 * s2 + i1 * s1 + i0 * s0 + i * sl;
                    w |= (uint32_t)(uint8_t)*p << (8 * i);
                }
                buf[k] = w;
            }
}
int32_t  ACCEL_C[16], ACCEL_BIAS[4];

static void tile_run(uint32_t ctrl);

// the layer engine, step for step as in matmul_accel.v (same descriptors, same pieces)
static void layer(void)
{
    char *mem = anchor;
    int W = ACCEL_L[5] & 255, C = (ACCEL_L[5] >> 8) & 255, F = (ACCEL_L[5] >> 16) & 255;
    int PH = ACCEL_L[5] >> 24, PW = ACCEL_L[6] & 255, rpr = (ACCEL_L[6] >> 8) & 255;
    int OW = 2 * PW;
    static uint32_t rowbuf[2][32][4];
    for (int py = 0; py < PH; py++) {
        for (int d = 0; d < 2; d++) {
            int oy = 2 * py + d;
            for (int x0 = 0; x0 < OW; x0 += 4) {
                int lanes = OW - x0 < 4 ? OW - x0 : 4;
                for (int f0 = 0; f0 < F; f0 += 4) {
                    for (int j = 0; j < 4; j++) {
                        ACCEL_BIAS[j] = *(int32_t *)(mem + (int32_t)ACCEL_L[3] + 4 * (f0 + j));
                        ACCEL_MULT[j] = *(uint32_t *)(mem + (int32_t)ACCEL_L[4] + 4 * (f0 + j));
                    }
                    for (int ky0 = 0; ky0 < 3; ) {
                        int nr = rpr < 3 - ky0 ? rpr : 3 - ky0, steps = nr * 3 * C;
                        uint32_t ctrl = ACCEL_START | ACCEL_GATHER_B | (uint32_t)steps;
                        if (rpr < 3 || f0 == 0) {
                            accel_gather_desc(ACCEL_GA, mem + (int32_t)ACCEL_L[0] + ((oy + ky0) * W + x0) * C,
                                              C, 3, nr, lanes, 1, C, W * C, C);
                            ctrl |= ACCEL_GATHER_A;
                        }
                        accel_gather_desc(ACCEL_GB, mem + (int32_t)ACCEL_L[2] + ky0 * 3 * C * F + f0,
                                          steps, 1, 1, 4, F, 0, 0, 1);
                        if (ky0 == 0) ctrl |= ACCEL_CLEAR;
                        tile_run(ctrl);
                        ky0 += nr;
                    }
                    for (int i = 0; i < lanes; i++) rowbuf[d][x0 + i][f0 / 4] = ACCEL_Q[i];
                }
            }
        }
        for (int px = 0; px < PW; px++)
            for (int fg = 0; fg < F / 4; fg++) {
                uint32_t w = 0;
                for (int b = 0; b < 4; b++) {
                    int m = 0;
                    for (int k = 0; k < 4; k++) {
                        int v = (int8_t)(rowbuf[k >> 1][2 * px + (k & 1)][fg] >> (8 * b));
                        if (v > m) m = v;
                    }
                    w |= (uint32_t)m << (8 * b);
                }
                *(uint32_t *)(mem + (int32_t)ACCEL_L[1] + (py * PW + px) * F + 4 * fg) = w;
            }
    }
}

int accel_run(void)
{
    if (accel_ctrl & ACCEL_LAYER) { layer(); accel_ctrl = 0; return 0; }
    tile_run(accel_ctrl);
    return 0;
}

static void tile_run(uint32_t ctrl)
{
    accel_ctrl = ctrl;
    if (accel_ctrl & ACCEL_GATHER_A) gather(ACCEL_GA, ACCEL_A);
    if (accel_ctrl & ACCEL_GATHER_B) gather(ACCEL_GB, ACCEL_B);
    if (!(accel_ctrl & ACCEL_START)) { accel_ctrl = 0; return; }
    int k = accel_ctrl & 0xff;
    if (accel_ctrl & ACCEL_CLEAR)
        for (int i = 0; i < 16; i++) ACCEL_C[i] = 0;
    for (int s = 0; s < k; s++)
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                ACCEL_C[i * 4 + j] += (int8_t)(ACCEL_A[s] >> (8 * i)) * (int8_t)(ACCEL_B[s] >> (8 * j));
    // output stage
    for (int i = 0; i < 4; i++) {
        ACCEL_Q[i] = 0;
        for (int j = 0; j < 4; j++) {
            int64_t r = (((int64_t)ACCEL_C[i * 4 + j] + ACCEL_BIAS[j]) * (int64_t)(ACCEL_MULT[j] & 0x3ffff)
                         + (1 << 23)) >> 24;
            uint32_t y = r < 0 ? 0 : r > 127 ? 127 : (uint32_t)r;
            ACCEL_Q[i] |= y << (8 * j);
        }
    }
    accel_ctrl = ACCEL_QREADY;
}
