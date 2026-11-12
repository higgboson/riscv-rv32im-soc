// kernels.c - benchmark kernels. Plain C, no I/O, so the same file also builds on a PC
// (sw/programs/bench/host/host_check.c) to produce the expected checksums.
//
// Each kernel stresses something different:
//   sort    : insertion sort, inner loop with a data-dependent exit
//   matmul  : 16x16 integer matrix multiply, regular loops + multiplies
//   sieve   : prime sieve, simple loops with loads / stores
//   crc32   : bit-by-bit CRC, an unpredictable branch on every data bit
//   fib     : recursive Fibonacci, lots of calls and returns (jal / jalr)
//   collatz : 3n + 1 steps, data-dependent branches that are hard to predict

#include <stdint.h>
#include "kernels.h"

static uint32_t lcg_state;

static uint32_t lcg(void)
{
    lcg_state = lcg_state * 1103515245u + 12345u;
    return lcg_state >> 8;
}

#define SORT_N 200
static int32_t sort_buf[SORT_N];

uint32_t bench_sort(void)
{
    lcg_state = 1;
    for (int i = 0; i < SORT_N; i++)
        sort_buf[i] = (int32_t)(lcg() % 10000) - 5000;

    for (int i = 1; i < SORT_N; i++) {
        int32_t key = sort_buf[i];
        int j = i - 1;
        while (j >= 0 && sort_buf[j] > key) {
            sort_buf[j + 1] = sort_buf[j];
            j--;
        }
        sort_buf[j + 1] = key;
    }

    uint32_t sum = 0;
    for (int i = 0; i < SORT_N; i++) {
        if (i && sort_buf[i - 1] > sort_buf[i])
            return 0;                     // not sorted: the check below will fail
        sum = sum * 31u + (uint32_t)sort_buf[i];
    }
    return sum;
}

#define MAT_N 16
static int32_t ma[MAT_N][MAT_N], mb[MAT_N][MAT_N], mc[MAT_N][MAT_N];

uint32_t bench_matmul(void)
{
    lcg_state = 2;
    for (int i = 0; i < MAT_N; i++)
        for (int j = 0; j < MAT_N; j++) {
            ma[i][j] = (int32_t)(lcg() % 201) - 100;
            mb[i][j] = (int32_t)(lcg() % 201) - 100;
        }

    for (int i = 0; i < MAT_N; i++)
        for (int j = 0; j < MAT_N; j++) {
            int32_t acc = 0;
            for (int k = 0; k < MAT_N; k++)
                acc += ma[i][k] * mb[k][j];
            mc[i][j] = acc;
        }

    uint32_t sum = 0;
    for (int i = 0; i < MAT_N; i++)
        for (int j = 0; j < MAT_N; j++)
            sum = sum * 31u + (uint32_t)mc[i][j];
    return sum;
}

#define SIEVE_N 4096
static uint8_t composite[SIEVE_N];

uint32_t bench_sieve(void)
{
    for (int i = 0; i < SIEVE_N; i++)
        composite[i] = 0;

    uint32_t count = 0;
    for (int i = 2; i < SIEVE_N; i++) {
        if (composite[i])
            continue;
        count++;
        for (int j = i * i; j < SIEVE_N; j += i)
            composite[j] = 1;
    }
    return count;
}

#define CRC_N 256
static uint8_t crc_buf[CRC_N];

uint32_t bench_crc32(void)
{
    lcg_state = 3;
    for (int i = 0; i < CRC_N; i++)
        crc_buf[i] = (uint8_t)lcg();

    uint32_t crc = 0xFFFFFFFFu;
    for (int i = 0; i < CRC_N; i++) {
        crc ^= crc_buf[i];
        for (int b = 0; b < 8; b++) {
            if (crc & 1)
                crc = (crc >> 1) ^ 0xEDB88320u;
            else
                crc >>= 1;
        }
    }
    return ~crc;
}

static uint32_t fib(uint32_t n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

uint32_t bench_fib(void)
{
    return fib(15);
}

uint32_t bench_collatz(void)
{
    uint32_t total = 0;
    for (uint32_t n = 1; n <= 150; n++) {
        uint32_t x = n;
        while (x != 1) {
            x = (x & 1) ? 3 * x + 1 : x / 2;
            total++;
        }
    }
    return total;
}
