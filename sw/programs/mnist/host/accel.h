// accel.h (PC version) - a software stand-in for the accelerator, so cnn_accel.c can be
// checked on the PC. Same registers and behaviour as code/accel/matmul_accel.v: after a
// write to CTRL with "start", the first busy check runs the whole tile.
#ifndef ACCEL_H
#define ACCEL_H
#include <stdint.h>

#define ACCEL_START  (1u << 8)
#define ACCEL_CLEAR  (1u << 9)
#define ACCEL_MAXK   64

extern uint32_t accel_ctrl, ACCEL_A[64], ACCEL_B[64];
extern int32_t  ACCEL_C[16];
int accel_run(void);

#define ACCEL_CTRL   accel_ctrl
#define ACCEL_BUSY   (accel_run(), 0u)
#endif
