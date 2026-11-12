// perf.h - read the hardware performance counters (see code/mmio.v)

#ifndef PERF_H
#define PERF_H

#include <stdint.h>

#define PERF_CYCLES      (*(volatile uint32_t *)0x10000010)
#define PERF_INSTRET     (*(volatile uint32_t *)0x10000014)
#define PERF_BRANCHES    (*(volatile uint32_t *)0x10000018)
#define PERF_JUMPS       (*(volatile uint32_t *)0x1000001C)
#define PERF_MISPREDICTS (*(volatile uint32_t *)0x10000020)

typedef struct {
    uint32_t cycles, instret, branches, jumps, mispredicts;
} perf_t;

static inline void perf_read(perf_t *p)
{
    p->cycles      = PERF_CYCLES;
    p->instret     = PERF_INSTRET;
    p->branches    = PERF_BRANCHES;
    p->jumps       = PERF_JUMPS;
    p->mispredicts = PERF_MISPREDICTS;
}

// counts between two readings (unsigned subtraction also works across a wrap)
static inline void perf_diff(perf_t *d, const perf_t *a, const perf_t *b)
{
    d->cycles      = b->cycles      - a->cycles;
    d->instret     = b->instret     - a->instret;
    d->branches    = b->branches    - a->branches;
    d->jumps       = b->jumps       - a->jumps;
    d->mispredicts = b->mispredicts - a->mispredicts;
}

#endif
