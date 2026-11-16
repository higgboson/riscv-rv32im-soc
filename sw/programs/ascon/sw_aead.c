// sw_aead.c - Ascon-AEAD128 in software, the baseline the hardware is compared with
//
// The code is the Ascon team's own 32-bit optimised C (ascon-c/aead, unmodified), built
// with the permutation as a loop instead of 12 unrolled rounds: the unrolled build needs
// about 51 KB of code and this CPU has 16 KB of instruction memory.

#define ASCON_INLINE_PERM  0
#define ASCON_UNROLL_LOOPS 0
#include "ascon-c/aead/aead.c"
