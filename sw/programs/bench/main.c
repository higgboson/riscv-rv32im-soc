// bench - runs each kernel, checks its result, and prints the hardware counters for it.
// Run it with and without branch prediction to see the difference:
//   make PROG=bench sim
//   make PROG=bench sim VFLAGS=-DNO_BPRED

#include "console.h"
#include "perf.h"
#include "kernels.h"

typedef struct {
    const char *name;
    uint32_t (*run)(void);
    uint32_t expected;        // from host/host_check.c, compiled and run on a PC
} bench_t;

static const bench_t benches[] = {
    { "sort   ", bench_sort,    0xcab0f8f4u },
    { "matmul ", bench_matmul,  0xe8662574u },
    { "sieve  ", bench_sieve,   564u        },
    { "crc32  ", bench_crc32,   0x34ed998eu },
    { "fib    ", bench_fib,     610u        },
    { "collatz", bench_collatz, 5742u       },
};

#define NUM_BENCH (sizeof(benches) / sizeof(benches[0]))

// print a / b with two decimals, e.g. 1.37 (no floating point on this CPU)
static void print_ratio(uint32_t a, uint32_t b)
{
    uint32_t x100 = (uint32_t)(((uint64_t)a * 100 + b / 2) / b);
    print_dec(x100 / 100);
    putchar_('.');
    putchar_('0' + (x100 / 10) % 10);
    putchar_('0' + x100 % 10);
}

static void pad(uint32_t v, int width)
{
    int digits = 1;
    for (uint32_t t = v; t >= 10; t /= 10)
        digits++;
    while (digits++ < width)
        putchar_(' ');
    print_dec(v);
}

int main(void)
{
    int errors = 0;
    perf_t before, after, d, total = {0, 0, 0, 0, 0};

    print_str("bench      cycles   instrs   CPI  branches  jumps  mispred  result\n");

    for (unsigned i = 0; i < NUM_BENCH; i++) {
        perf_read(&before);
        uint32_t got = benches[i].run();
        perf_read(&after);
        perf_diff(&d, &before, &after);

        total.cycles += d.cycles;           total.instret += d.instret;
        total.branches += d.branches;       total.jumps += d.jumps;
        total.mispredicts += d.mispredicts;

        print_str(benches[i].name);
        pad(d.cycles, 10);  pad(d.instret, 9);
        print_str("  ");    print_ratio(d.cycles, d.instret);
        pad(d.branches, 9); pad(d.jumps, 7); pad(d.mispredicts, 9);
        if (got == benches[i].expected) {
            print_str("  ok\n");
        } else {
            print_str("  WRONG ");
            print_hex(got);
            print_str("\n");
            errors++;
        }
    }

    print_str("total  ");
    pad(total.cycles, 10);  pad(total.instret, 9);
    print_str("  ");        print_ratio(total.cycles, total.instret);
    pad(total.branches, 9); pad(total.jumps, 7); pad(total.mispredicts, 9);
    print_str("\n");

    return errors;
}
