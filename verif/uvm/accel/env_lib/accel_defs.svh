// accel_defs.svh - register map of the accelerator (same as code/accel/matmul_accel.v)

`ifndef ACCEL_DEFS_SVH
`define ACCEL_DEFS_SVH

`define ACCEL_BASE   32'h2000_0000
`define ACCEL_CTRL   (`ACCEL_BASE + 32'h000)
`define ACCEL_A      (`ACCEL_BASE + 32'h100)     // A_COL[k], one word = A[0..3][k]
`define ACCEL_B      (`ACCEL_BASE + 32'h200)     // B_ROW[k], one word = B[k][0..3]
`define ACCEL_C      (`ACCEL_BASE + 32'h300)     // C[i][j], 16 words, row by row

`define ACCEL_START  32'h100
`define ACCEL_CLEAR  32'h200
`define ACCEL_MAXK   64

`endif
