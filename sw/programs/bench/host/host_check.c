// host_check.c - builds the benchmark kernels on a normal PC and prints their checksums.
// These are the expected values in ../main.c.
//   gcc -O2 -I.. host_check.c ../kernels.c -o host_check && ./host_check

#include <stdio.h>
#include "kernels.h"

int main(void)
{
    printf("sort    0x%08x\n", bench_sort());
    printf("matmul  0x%08x\n", bench_matmul());
    printf("sieve   %u\n",     bench_sieve());
    printf("crc32   0x%08x\n", bench_crc32());
    printf("fib     %u\n",     bench_fib());
    printf("collatz %u\n",     bench_collatz());
    return 0;
}
