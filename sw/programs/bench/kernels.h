// kernels.h - benchmark kernels, each returns a checksum of its result

#ifndef KERNELS_H
#define KERNELS_H

#include <stdint.h>

uint32_t bench_sort(void);
uint32_t bench_matmul(void);
uint32_t bench_sieve(void);
uint32_t bench_crc32(void);
uint32_t bench_fib(void);
uint32_t bench_collatz(void);

#endif
