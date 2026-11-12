// report.h - benchmark table shared by the bench and demo programs

#ifndef REPORT_H
#define REPORT_H

#include "perf.h"

int      run_benchmarks(perf_t *total);      // returns the number of wrong results
uint32_t ratio_x100(uint32_t a, uint32_t b);

#endif
