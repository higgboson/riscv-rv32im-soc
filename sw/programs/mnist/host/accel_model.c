#include "accel.h"
uint32_t accel_ctrl, ACCEL_A[64], ACCEL_B[64];
int32_t  ACCEL_C[16];

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
    accel_ctrl = 0;
    return 0;
}
