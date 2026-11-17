#include "accel.h"
uint32_t accel_ctrl, ACCEL_A[64], ACCEL_B[64], ACCEL_Q[4], ACCEL_MULT[4];
int32_t  ACCEL_C[16], ACCEL_BIAS[4];

int accel_run(void)
{
    if (!(accel_ctrl & ACCEL_START)) return 0;
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
