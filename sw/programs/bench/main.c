// bench - runs each kernel, checks its result, and prints the hardware counters for it.
// Run it with and without branch prediction to see the difference:
//   make PROG=bench sim
//   make PROG=bench sim VFLAGS=-DNO_BPRED

#include "console.h"
#include "report.h"

int main(void)
{
    perf_t total;
    int errors = run_benchmarks(&total);
    uart_flush();
    return errors;
}
