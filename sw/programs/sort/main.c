// sort - merge sort on the RV32IM SoC, shown on the 2.4" TFT
//
// 1. Animated: 120 random bars, merge-sorted bottom up (runs of 1, 2, 4 ... merged into
//    runs twice as long); every element written back is redrawn, coloured by its value, so the
//    sorted result ends as a smooth rainbow. The run size and the comparisons are shown.
// 2. Benchmark: 2,000 random 32-bit numbers (200 in the simulation build) sorted by merge sort (n log n) and by insertion
//    sort (n^2), timed with the cycle counter; both results checked sorted and identical.
// Results also go to the UART. btnU (or any key in the load.py window) runs it again with new
// numbers; btnC restarts the program.

#include "console.h"
#include "perf.h"
#include "tft.h"

#ifdef SIM
#define MS 500u                                         // simulation: everything 100x faster
#else
#define MS 50000u                                       // cycles per millisecond at 50 MHz
#endif

static uint32_t now(void) { return PERF_CYCLES; }
static uint32_t rng;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

// ---------------------------------------------------------------- 1. the animation
#define NB     120                                      // bars, 2 pixels wide
#define BASE   300                                      // bottom of the bars
#define MAXH   240
static int16_t bar[NB], tmp_bar[NB];

static uint16_t hue(int v)                              // 0..MAXH -> red, yellow, green, cyan, blue, violet
{
    int h = v * 1279 / MAXH, r, g, b;                   // 5 segments of 256
    if (h < 256)       { r = 255;     g = h;       b = 0; }
    else if (h < 512)  { r = 511 - h; g = 255;     b = 0; }
    else if (h < 768)  { r = 0;       g = 255;     b = h - 512; }
    else if (h < 1024) { r = 0;       g = 1023 - h; b = 255; }
    else               { r = h - 1024; g = 0;      b = 255; }
    return RGB(r, g, b);
}

static void draw_bar(int i, uint16_t c)
{
    int h = bar[i];
    tft_fill(i * 2, BASE - MAXH, 2, MAXH - h, C_BLACK);
    tft_fill(i * 2, BASE - h, 2, h, c);
}

static void wait_ms(uint32_t ms) { uint32_t t0 = now(); while (now() - t0 < ms * MS) ; }

static uint32_t anim_cmp;
static void show_status(int run)
{
    int x = tft_text(4, 26, "run size ", 1, C_WHITE, C_BLACK);
    x = tft_num(x, 26, (uint32_t)run, 1, C_YELLOW, C_BLACK);
    x = tft_text(x, 26, "  comparisons ", 1, C_WHITE, C_BLACK);
    x = tft_num(x, 26, anim_cmp, 1, C_YELLOW, C_BLACK);
    tft_fill(x, 26, 240 - x, 12, C_BLACK);
}

static void animate(void)
{
    tft_fill(0, 0, TFT_W, TFT_H, C_BLACK);
    tft_fill(0, 0, TFT_W, 20, C_GREEN);
    tft_text(4, 4, "Merge sort on my RISC-V", 1, C_WHITE, C_GREEN);
    for (int i = 0; i < NB; i++) { bar[i] = (int16_t)(4 + rnd() % (MAXH - 4)); draw_bar(i, C_GREY); }
    anim_cmp = 0;
    show_status(1);
    wait_ms(600);
    for (int run = 1; run < NB; run *= 2) {
        show_status(run * 2);
        for (int lo = 0; lo < NB - run; lo += 2 * run) {
            int mid = lo + run, hi = lo + 2 * run < NB ? lo + 2 * run : NB;
            int i = lo, j = mid, k = 0;
            while (i < mid && j < hi) { anim_cmp++; tmp_bar[k++] = bar[i] <= bar[j] ? bar[i++] : bar[j++]; }
            while (i < mid) tmp_bar[k++] = bar[i++];
            while (j < hi)  tmp_bar[k++] = bar[j++];
            for (int m = 0; m < k; m++) {               // write back, one bar at a time
                bar[lo + m] = tmp_bar[m];
                draw_bar(lo + m, hue(bar[lo + m]));
                wait_ms(3);
            }
        }
    }
    show_status(NB);
    tft_text(4, 306, "sorted: 120 bars", 1, C_GREEN, C_BLACK);
}

// ---------------------------------------------------------------- 2. the benchmark
#ifdef SIM
#define N 200                                           // simulation: a shorter benchmark
#else
#define N 2000
#endif
static uint32_t a[N], b[N], t[N];
static uint32_t cmp_merge, cmp_ins;

static void merge_sort(uint32_t *x, int n)              // bottom up, through t[]
{
    for (int run = 1; run < n; run *= 2) {
        for (int lo = 0; lo < n; lo += 2 * run) {
            int mid = lo + run < n ? lo + run : n, hi = lo + 2 * run < n ? lo + 2 * run : n;
            int i = lo, j = mid, k = lo;
            while (i < mid && j < hi) { cmp_merge++; t[k++] = x[i] <= x[j] ? x[i++] : x[j++]; }
            while (i < mid) t[k++] = x[i++];
            while (j < hi)  t[k++] = x[j++];
        }
        for (int i = 0; i < n; i++) x[i] = t[i];
    }
}

static void insertion_sort(uint32_t *x, int n)
{
    for (int i = 1; i < n; i++) {
        uint32_t v = x[i];
        int j = i - 1;
        while (j >= 0) {
            cmp_ins++;
            if (x[j] <= v) break;
            x[j + 1] = x[j];
            j--;
        }
        x[j + 1] = v;
    }
}

static void ms_text(int x, int y, uint32_t cycles, uint16_t c)   // "12.34 ms" (50 MHz clock)
{
    x = tft_fixed(x, y, cycles / 500u, 2, 1, c, C_BLACK);
    tft_text(x, y, " ms", 1, c, C_BLACK);
}

static void benchmark(void)
{
    tft_fill(0, 20, TFT_W, TFT_H - 20, C_BLACK);
    int x = tft_text(4, 30, "Sorting ", 1, C_WHITE, C_BLACK);
    x = tft_num(x, 30, N, 1, C_WHITE, C_BLACK);
    tft_text(x, 30, " random numbers", 1, C_WHITE, C_BLACK);
    for (int i = 0; i < N; i++) a[i] = b[i] = rnd();

    cmp_merge = cmp_ins = 0;
    uint32_t t0 = now();
    merge_sort(a, N);
    uint32_t t_merge = now() - t0;
    tft_text(4, 60, "Merge sort (n log n)", 1, C_YELLOW, C_BLACK);
    ms_text(4, 76, t_merge, C_WHITE);
    x = tft_num(4, 92, cmp_merge, 1, C_GREY, C_BLACK);
    tft_text(x, 92, " comparisons", 1, C_GREY, C_BLACK);

    tft_text(4, 120, "Insertion sort (n^2)...", 1, C_ORANGE, C_BLACK);
    t0 = now();
    insertion_sort(b, N);
    uint32_t t_ins = now() - t0;
    tft_text(4, 120, "Insertion sort (n^2)   ", 1, C_ORANGE, C_BLACK);
    ms_text(4, 136, t_ins, C_WHITE);
    x = tft_num(4, 152, cmp_ins, 1, C_GREY, C_BLACK);
    tft_text(x, 152, " comparisons", 1, C_GREY, C_BLACK);

    // bars: insertion sort full width, merge sort to scale
    int len = (int)(232u * (t_merge / 64u) / (t_ins / 64u + 1u));
    if (len < 2) len = 2;
    tft_fill(4, 180, 232, 12, C_ORANGE);
    tft_fill(4, 200, len, 12, C_YELLOW);
    tft_fill(4 + len, 200, 232 - len, 12, C_DARK);
    tft_text(4, 218, "top: insertion  bottom: merge", 1, C_GREY, C_BLACK);

    int ok = 1;
    for (int i = 0; i < N; i++) { ok &= a[i] == b[i]; if (i) ok &= a[i - 1] <= a[i]; }
    uint32_t r = (t_ins * 10u + t_merge / 2u) / t_merge;
    x = tft_text(4, 244, "merge sort is ", 2, C_WHITE, C_BLACK);
    x = tft_fixed(4, 266, r, 1, 2, C_YELLOW, C_BLACK);
    tft_text(x, 266, "x faster", 2, C_YELLOW, C_BLACK);
    tft_text(4, 296, ok ? "sorted, results identical" : "RESULTS DIFFER", 1, ok ? C_GREEN : C_RED, C_BLACK);
    tft_text(4, 308, "btnU or a key: again", 1, C_GREY, C_BLACK);

    print_str("sort "); print_dec(N); print_str(" numbers: merge "); print_dec((int32_t)(t_merge / 50u));
    print_str(" us ("); print_dec((int32_t)cmp_merge); print_str(" comparisons), insertion ");
    print_dec((int32_t)(t_ins / 50u)); print_str(" us ("); print_dec((int32_t)cmp_ins);
    print_str(" comparisons), "); print_str(ok ? "results identical\n" : "RESULTS DIFFER\n");
}

int main(void)
{
#ifdef SIM
    tft_init(1);                                        // simulation: the fast display clock
#else
    tft_init(0);
#endif
    rng = now() | 1u;
    for (;;) {
        animate();
        wait_ms(1500);
        benchmark();
        // wait for btnU or a key from the laptop
        while (!(IO_BUTTONS & 1u) && getchar_nb() < 0) rng ^= now();
        while (IO_BUTTONS & 1u) ;
    }
}
