// matmul - INT8 matrix multiply on the CPU alone vs. with the systolic-array accelerator
//
// C (32x32, INT32) = A (32x32, INT8) x B (32x32, INT8), the core operation of neural-network
// layers. Both versions get the same random matrices; the results must match exactly.
// The hardware counters measure each one. On the board the speedup is also shown on the
// 7-segment display, e.g. "13.4" for 13.4x.

#include "console.h"
#include "perf.h"
#include "accel.h"

#define M 32
#define K 32
#define N 32

static int8_t  a[M][K];        // A, row-major (for the CPU version)
static int8_t  at[K][M];       // A transposed (for the accelerator, see accel.h)
static int8_t  b[K][N];
static int32_t c_cpu[M][N];
static int32_t c_acc[M][N];

static uint32_t lcg_state = 12345;
static int8_t rand_int8(void)
{
    lcg_state = lcg_state * 1103515245u + 12345u;
    return (int8_t)(lcg_state >> 16);
}

// plain C: what the CPU would do without the accelerator
static void matmul_cpu(void)
{
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            int32_t sum = 0;
            for (int k = 0; k < K; k++)
                sum += a[i][k] * b[k][j];
            c_cpu[i][j] = sum;
        }
}

// 0..9999 -> 4 BCD digits, so the hex display shows a decimal number
static uint32_t to_bcd(uint32_t v)
{
    uint32_t bcd = 0;
    for (int shift = 0; shift < 16; shift += 4) {
        bcd |= (v % 10) << shift;
        v /= 10;
    }
    return bcd;
}

static void report(const char *name, const perf_t *d)
{
    print_str(name);
    print_dec(d->cycles);
    print_str(" cycles, ");
    print_dec(d->instret);
    print_str(" instructions\n");
}

int main(void)
{
    perf_t t0, t1, cpu, acc;

    for (int i = 0; i < M; i++)
        for (int k = 0; k < K; k++) {
            a[i][k] = rand_int8();
            at[k][i] = a[i][k];
        }
    for (int k = 0; k < K; k++)
        for (int j = 0; j < N; j++)
            b[k][j] = rand_int8();

    print_str("INT8 matrix multiply 32x32x32 (32,768 multiply-adds)\n");

    perf_read(&t0);
    matmul_cpu();
    perf_read(&t1);
    perf_diff(&cpu, &t0, &t1);
    report("CPU only          : ", &cpu);

    perf_read(&t0);
    accel_matmul(M, N, K, &at[0][0], &b[0][0], &c_acc[0][0]);
    perf_read(&t1);
    perf_diff(&acc, &t0, &t1);
    report("CPU + accelerator : ", &acc);

    int errors = 0;
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++)
            if (c_cpu[i][j] != c_acc[i][j])
                errors++;

    // speedup with one decimal, without floating point
    uint32_t x10 = (cpu.cycles * 10 + acc.cycles / 2) / acc.cycles;
    print_str("speedup           : ");
    print_dec(x10 / 10);
    putchar_('.');
    putchar_('0' + x10 % 10);
    print_str("x\n");
    print_str(errors ? "RESULTS DIFFER\n" : "results match exactly\n");

    // display: speedup x10 as decimal with a dot before the last digit, e.g. "13.4"
    IO_HEX = (0x2u << 16) | to_bcd(x10);
    uart_flush();
    return errors;
}
