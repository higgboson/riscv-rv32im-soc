// riscv_test.h - small test environment so the official riscv-tests run on this CPU
//
// The standard environment needs CSRs, traps and machine mode, which this CPU does not
// have. The tests themselves only need: a start label, a way to say pass / fail,
// and a data section. This file gives exactly that:
//   pass -> write 1 to TOHOST
//   fail -> write (test number << 1) | 1 to TOHOST, so we know which check failed
// TESTNUM (gp) holds the number of the check that is running.

#ifndef RISCV_TEST_H
#define RISCV_TEST_H

#define TOHOST_ADDR 0x10000004

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U .macro init; .endm

#define TESTNUM gp

#define RVTEST_CODE_BEGIN       \
        .section .text.start;   \
        .globl _start;          \
_start:                         \
        li TESTNUM, 0;

#define RVTEST_CODE_END         \
        unimp

#define RVTEST_PASS             \
        fence;                  \
        li a0, 1;               \
        li t0, TOHOST_ADDR;     \
        sw a0, 0(t0);           \
1:      j 1b;

#define RVTEST_FAIL             \
        fence;                  \
        slli a0, TESTNUM, 1;    \
        ori a0, a0, 1;          \
        li t0, TOHOST_ADDR;     \
        sw a0, 0(t0);           \
1:      j 1b;

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN       \
        EXTRA_DATA              \
        .data;                  \
        .align 4;

#define RVTEST_DATA_END

#endif
