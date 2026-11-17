#include "accel.h"
uint32_t accel_ctrl, ACCEL_A[64], ACCEL_B[64], ACCEL_Q[4], ACCEL_MULT[4];
uint32_t ACCEL_GA[4], ACCEL_GB[4];
char     accel_anchor;

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
                    const char *p = &accel_anchor + (int32_t)d[0] + i2 * s2 + i1 * s1 + i0 * s0 + i * sl;
                    w |= (uint32_t)(uint8_t)*p << (8 * i);
                }
                buf[k] = w;
            }
}
int32_t  ACCEL_C[16], ACCEL_BIAS[4];

int accel_run(void)
{
    if (accel_ctrl & ACCEL_GATHER_A) gather(ACCEL_GA, ACCEL_A);
    if (accel_ctrl & ACCEL_GATHER_B) gather(ACCEL_GB, ACCEL_B);
    if (!(accel_ctrl & ACCEL_START)) { accel_ctrl = 0; return 0; }
    int k = accel_ctrl & 0x7f;
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
    return 0;
}
