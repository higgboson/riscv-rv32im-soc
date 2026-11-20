// nn_demo - live demo of the accelerator on the 2.4" TFT, three modes:
//
//   digit   a digit drawn on the laptop (sw/demo_tool.py) arrives over the UART; the board
//           recognises it with the CPU alone and with the accelerator and shows both times
//   filter  edge detection (four 3x3 Sobel filters, ReLU, 2x2 max pool) on a 66x66 window
//           that pans over a 96x96 picture, frame after frame, on the CPU or on the layer
//           engine, with the frame rate and the time per frame
//   race    the CPU and the accelerator classify the same 24 images; two progress bars
//   draw    a digit drawn on the TFT with a USB mouse plugged into the board (code/io/ps2.v);
//           recognised on both, the answer on the TFT and, with the 28x28 image, on the laptop
//
// Switches: sw[2:1] mode (00 digit, 01 filter, 10 race, 11 draw), sw[3] filter on the CPU instead of
// the accelerator, sw[0] fast display clock (25 MHz instead of 12.5 MHz).
// The laptop tool can also send a digit (mode digit) or a picture (mode filter) at any time.
// The 7-segment display shows the last measured speedup (accelerator over CPU).

#include "console.h"
#include "perf.h"
#include "accel.h"
#include "cnn.h"
#include "tft.h"

extern const int     n_race_images;
extern const uint8_t race_images[], race_labels[];

// ---------------------------------------------------------------- shared buffers
static uint8_t digit_px[784];                                     // from the laptop, 0..255
static int8_t  x[784]          __attribute__((aligned(4)));
static int8_t  p1[13 * 13 * 8] __attribute__((aligned(4)));
static int8_t  p2[400]         __attribute__((aligned(4)));
static int32_t scores[10];

#define PIC 96                                                     // picture for the filter
#define WIN 66                                                     // window: 66x66 -> 32x32
static int8_t  pic[PIC * PIC]  __attribute__((aligned(4)));
static int8_t  fout[2][32 * 16 * 4] __attribute__((aligned(4)));  // two strips of 32x16x4

static uint32_t now(void) { return PERF_CYCLES; }

static uint32_t to_bcd(uint32_t v)
{
    uint32_t bcd = 0;
    for (int shift = 0; shift < 16; shift += 4) { bcd |= (v % 10) << shift; v /= 10; }
    return bcd;
}

// speedup a / b on the 7-segment display with one decimal ("58.4")
static void show_speedup(uint32_t a, uint32_t b)
{
    uint32_t r = (a * 10u + b / 2) / b;
    if (r > 9999) r = 9999;
    IO_HEX = to_bcd(r) | (1u << 17);                               // decimal point after digit 1
}

// ---------------------------------------------------------------- the network
// one image, CPU alone or accelerator (layer engine for the convolutions, gather path for
// the fully connected layer); returns the cycles, scores in scores[]
static uint32_t infer(const uint8_t *px, int accel)
{
    uint32_t t0 = now();
    cnn_input(px, x);
    if (accel) { conv1_engine(x, p1); conv2_engine(p1, p2); fc_gather(p2, scores); }
    else       { conv1_cpu(x, p1);    conv2_cpu(p1, p2);    fc_cpu(p2, scores); }
    return now() - t0;
}

// ---------------------------------------------------------------- the edge filter
// Four filters on one input channel: Sobel x, -x, y, -y (x32 so the 18-bit scale can bring the
// sums back to 0..127). After ReLU the four channels are the edges in four directions.
static const int8_t sobel[9 * 4] __attribute__((aligned(4))) = {
    //  x    -x     y    -y          (ky, kx) order, 4 filters per row
    -32,  32, -32,  32,     0,   0, -64,  64,    32, -32, -32,  32,
    -64,  64,   0,   0,     0,   0,   0,   0,    64, -64,   0,   0,
    -32,  32,  32, -32,     0,   0,  64, -64,    32, -32,  32, -32,
};
static const int32_t sobel_bias[4] __attribute__((aligned(4))) = { 0, 0, 0, 0 };
static const int32_t sobel_mult[4] __attribute__((aligned(4))) = { 262143, 262143, 262143, 262143 };

static inline int8_t requant8(int32_t acc, int32_t m)
{
    int32_t y = (int32_t)(((int64_t)acc * m + (1 << 23)) >> 24);
    return (int8_t)(y < 0 ? 0 : y > 127 ? 127 : y);
}

// the same layer as the engine computes, on the CPU: 3x3 conv, ReLU, 2x2 max pool, written
// as two strips of 16 pooled columns (the engine's row buffer holds 32 conv columns)
static void filter_cpu(const int8_t *in)
{
    for (int s = 0; s < 2; s++)
        for (int py = 0; py < 32; py++)
            for (int px = 0; px < 16; px++)
                for (int f = 0; f < 4; f++) {
                    int8_t best = 0;
                    for (int d = 0; d < 4; d++) {
                        int oy = 2 * py + (d >> 1), ox = 32 * s + 2 * px + (d & 1);
                        int32_t acc = sobel_bias[f];
                        for (int ky = 0; ky < 3; ky++)
                            for (int kx = 0; kx < 3; kx++)
                                acc += in[(oy + ky) * PIC + ox + kx] * sobel[(ky * 3 + kx) * 4 + f];
                        int8_t y = requant8(acc, sobel_mult[f]);
                        if (y > best) best = y;
                    }
                    fout[s][(py * 16 + px) * 4 + f] = best;
                }
}

static void filter_engine(const int8_t *in)
{
    for (int s = 0; s < 2; s++)
        accel_conv_layer(in + 32 * s, PIC, 1, 4, 32, 16, sobel, sobel_bias, sobel_mult, fout[s]);
}

// a default picture, so the filter mode works without the laptop: shapes and a title
// FNV-1a hash of the filter output, to check the CPU and the accelerator agree bit for bit
static uint32_t fout_hash(void)
{
    uint32_t h = 2166136261u;
    for (int s = 0; s < 2; s++)
        for (int i = 0; i < 32 * 16 * 4; i++) h = (h ^ (uint8_t)fout[s][i]) * 16777619u;
    return h;
}

static void default_picture(void)
{
    for (int y = 0; y < PIC; y++)
        for (int x0 = 0; x0 < PIC; x0++) {
            int v = 20 + (x0 + y) / 6;                                    // soft gradient
            int dx = x0 - 30, dy = y - 34;
            if (dx * dx + dy * dy < 18 * 18) v = 110;                      // circle
            if (x0 > 56 && x0 < 86 && y > 14 && y < 40) v = 70;           // rectangle
            if (y > 58 && y < 86 && x0 > 50 && x0 - 50 < (y - 58) * 3 / 2) v = 120;  // triangle
            if ((x0 / 8 + y / 8) % 2 == 0 && y > 66 && x0 < 40) v = 95;   // chequers
            pic[y * PIC + x0] = (int8_t)v;
        }
}

// ---------------------------------------------------------------- screen helpers
static void header(const char *title, uint16_t colour)
{
    tft_fill(0, 0, TFT_W, 20, colour);
    tft_text(4, 4, title, 1, C_WHITE, colour);
}

// a labelled timing bar: "CPU   44.11 ms" over a bar of length len (out of 232)
static void time_bar(int y, const char *name, uint32_t cycles, int len, uint16_t colour)
{
    int x = tft_text(4, y, name, 1, C_WHITE, C_BLACK);
    uint32_t us = cycles / 50u;                                       // 50 MHz
    x = tft_fixed(x, y, us / 10, 2, 1, C_WHITE, C_BLACK);             // ms with 2 decimals
    x = tft_text(x, y, " ms   ", 1, C_WHITE, C_BLACK);
    if (len < 2) len = 2;
    if (len > 232) len = 232;
    tft_fill(4, y + 14, len, 10, colour);
    tft_fill(4 + len, y + 14, 232 - len, 10, C_DARK);
}

static void speedup_text(int x, int y, uint32_t a, uint32_t b, int scale)
{
    uint32_t r = (a * 10u + b / 2) / b;
    x = tft_fixed(x, y, r, 1, scale, C_YELLOW, C_BLACK);
    tft_text(x, y, "x faster ", scale, C_YELLOW, C_BLACK);
}

// ---------------------------------------------------------------- UART from the laptop
// command byte, then ACK (0x06) back, then the payload; returns 0 if a byte did not come in time
static int read_bytes(uint8_t *dst, int n)
{
    for (int i = 0; i < n; i++) {
        uint32_t t0 = now();
        int c;
        while ((c = getchar_nb()) < 0)
            if (now() - t0 > 50000000u) return 0;                      // 1 s without a byte
        dst[i] = (uint8_t)c;
    }
    return 1;
}

// ---------------------------------------------------------------- modes
static void digit_screen(void)
{
    tft_fill(0, 0, TFT_W, TFT_H, C_BLACK);
    header("Digit: draw on the laptop", C_BLUE);
    tft_text(8, 80, "Waiting for a digit", 1, C_GREY, C_BLACK);
    tft_text(8, 96, "from the laptop tool", 1, C_GREY, C_BLACK);
}

static void digit_run(void)
{
    uint32_t t_cpu = infer(digit_px, 0);
    int d_cpu = cnn_argmax(scores);
    int32_t s_cpu[10];
    for (int i = 0; i < 10; i++) s_cpu[i] = scores[i];
    uint32_t t_acc = infer(digit_px, 1);
    int d_acc = cnn_argmax(scores);
    int same = 1;
    for (int i = 0; i < 10; i++) same &= s_cpu[i] == scores[i];

    tft_fill(0, 20, TFT_W, TFT_H - 20, C_BLACK);
    cnn_input(digit_px, x);
    tft_image(8, 28, x, 28, 28, 28, 5);                               // 140 x 140
    tft_text(160, 36, "It is", 1, C_GREY, C_BLACK);
    tft_char(164, 56, (char)('0' + d_acc), 7, C_GREEN, C_BLACK);      // 56 x 84
    time_bar(180, "CPU   ", t_cpu, 232, C_ORANGE);
    time_bar(212, "ACCEL ", t_acc, (int)(232u * t_acc / t_cpu), C_BLUE);
    speedup_text(4, 248, t_cpu, t_acc, 2);
    tft_text(4, 284, same && d_cpu == d_acc ? "CPU = accelerator, bit-exact"
                                            : "CPU and accelerator DIFFER  ", 1,
             same ? C_GREEN : C_RED, C_BLACK);
    tft_text(4, 300, "RV32IM CPU + 4x4 INT8 array", 1, C_GREY, C_BLACK);
    show_speedup(t_cpu, t_acc);

    print_str("digit "); print_dec(d_acc);
    print_str(" cpu "); print_dec(t_cpu / 50); print_str(" us accel "); print_dec(t_acc / 50);
    print_str(same ? " us same\n" : " us DIFFER\n");
}

static uint32_t f_cpu_cycles, f_acc_cycles;                        // last measured of each
static int      f_x, f_y, f_dx = 1, f_dy = 1, f_checked;

static void filter_screen(void)
{
    tft_fill(0, 0, TFT_W, TFT_H, C_BLACK);
    f_checked = 0;
}

// one frame: move the window, filter it, draw the window and the edges
static void filter_frame(int on_cpu)
{
    static uint32_t last_frame;
    static int last_cpu = -1;
    const int8_t *in = pic + f_y * PIC + f_x;

    if (!f_checked) {                                              // once per screen: same results?
        filter_cpu(in);
        uint32_t h_cpu = fout_hash();
        filter_engine(in);
        int same = fout_hash() == h_cpu;
        tft_text(4, 306, same ? "CPU = accelerator, bit-exact" : "CPU and accelerator DIFFER  ",
                 1, same ? C_GREEN : C_RED, C_BLACK);
        f_checked = 1;
    }
    if (on_cpu != last_cpu) {
        header(on_cpu ? "Edges: CPU alone" : "Edges: accelerator",
               on_cpu ? C_ORANGE : C_BLUE);
        last_cpu = on_cpu;
    }

    uint32_t t0 = now();
    if (on_cpu) filter_cpu(in); else filter_engine(in);
    uint32_t t = now() - t0;
    if (on_cpu) f_cpu_cycles = t; else f_acc_cycles = t;

    // window (64x64 of it, x2) and the edges (32x32, the strongest of the 4 directions, x4)
    tft_image(56, 24, in + PIC + 1, 64, 64, PIC, 2);
    tft_window(56, 156, 128, 128);
    for (int py = 0; py < 32; py++)
        for (int rep = 0; rep < 4; rep++)
            for (int s = 0; s < 2; s++)
                for (int px = 0; px < 16; px++) {
                    const int8_t *o = &fout[s][(py * 16 + px) * 4];
                    int v = o[0];
                    if (o[1] > v) v = o[1];
                    if (o[2] > v) v = o[2];
                    if (o[3] > v) v = o[3];
                    uint16_t c = RGB(v, v * 2 > 255 ? 255 : v * 2, v * 2 > 255 ? 255 : v * 2);
                    tft_pix2(c, c);  tft_pix2(c, c);
                }

    // numbers: this frame's filter time, frame rate, and both last measured filter times
    uint32_t t_now = now(), frame = t_now - last_frame;
    last_frame = t_now;
    int xx = tft_text(4, 288, "filter ", 1, C_WHITE, C_BLACK);
    xx = tft_fixed(xx, 288, t / 500, 2, 1, C_WHITE, C_BLACK);        // ms, 2 decimals
    xx = tft_text(xx, 288, " ms  ", 1, C_WHITE, C_BLACK);
    xx = tft_num(xx, 288, 50000000u / frame, 1, C_YELLOW, C_BLACK);
    tft_text(xx, 288, " frames/s  ", 1, C_YELLOW, C_BLACK);
    if (f_cpu_cycles && f_acc_cycles) show_speedup(f_cpu_cycles, f_acc_cycles);

    // bounce the window around the picture
    if (f_x + f_dx < 0 || f_x + f_dx > PIC - WIN) f_dx = -f_dx;
    if (f_y + f_dy < 0 || f_y + f_dy > PIC - WIN) f_dy = -f_dy;
    f_x += f_dx;  f_y += f_dy;
}

#define race_px digit_px                                           // the race reuses the digit buffer
static void unpack_race(int i)
{
    const uint8_t *p = &race_images[i * 392];
    for (int k = 0; k < 392; k++) {
        race_px[2 * k]     = (uint8_t)((p[k] & 15) * 17);
        race_px[2 * k + 1] = (uint8_t)((p[k] >> 4) * 17);
    }
}

#define RACE_N 24
static void race_run(void)
{
    tft_fill(0, 0, TFT_W, TFT_H, C_BLACK);
    header("Race: CPU vs accelerator", C_GREEN);
    // the 12 images, 4 per row, each 28x28 x2 with its label under it
    for (int i = 0; i < n_race_images; i++) {
        unpack_race(i);
        cnn_input(race_px, x);
        tft_image(4 + (i % 4) * 59, 24 + (i / 4) * 60, x, 28, 28, 28, 2);
    }

    // accelerator first: 24 classifications
    int ok_acc = 0, ok_cpu = 0, agree = 1;
    static int pred[RACE_N];
    uint32_t t_acc = 0, t_cpu = 0;
    for (int i = 0; i < RACE_N; i++) {
        unpack_race(i % n_race_images);
        t_acc += infer(race_px, 1);
        pred[i] = cnn_argmax(scores);
        ok_acc += pred[i] == race_labels[i % n_race_images];
    }
    // the CPU, with its bar growing after every image
    int y_cpu = 210, y_acc = 250;
    tft_text(4, y_acc, "ACCEL ", 1, C_WHITE, C_BLACK);
    for (int i = 0; i < RACE_N; i++) {
        unpack_race(i % n_race_images);
        t_cpu += infer(race_px, 0);
        int d = cnn_argmax(scores);
        ok_cpu += d == race_labels[i % n_race_images];
        agree &= d == pred[i];
        if (i < n_race_images)                                        // the predicted digit
            tft_char(4 + (i % 4) * 59 + 44, 24 + (i / 4) * 60 + 42, (char)('0' + d), 1,
                     d == race_labels[i] ? C_GREEN : C_RED, C_BLACK);
        int len = 232 * (i + 1) / RACE_N;
        tft_fill(4, y_cpu + 14, len, 10, C_ORANGE);
        if (i == 0) {                                               // the accelerator finished long ago
            time_bar(y_acc, "ACCEL ", t_acc, 2 + 232 * t_acc / (t_cpu * RACE_N), C_BLUE);
            tft_text(4, y_cpu, "CPU   ...", 1, C_WHITE, C_BLACK);
        }
    }
    time_bar(y_cpu, "CPU   ", t_cpu, 232, C_ORANGE);
    time_bar(y_acc, "ACCEL ", t_acc, (int)(232u * (t_acc / 64) / (t_cpu / 64)), C_BLUE);
    speedup_text(4, 282, t_cpu, t_acc, 2);
    int xx = tft_num(4, 308, (uint32_t)ok_acc, 1, C_WHITE, C_BLACK);
    xx = tft_text(xx, 308, "/24 right, ", 1, C_WHITE, C_BLACK);
    tft_text(xx, 308, agree ? "both agree" : "they DIFFER", 1, agree ? C_GREEN : C_RED, C_BLACK);
    show_speedup(t_cpu, t_acc);
    (void)ok_cpu;
}

// ---------------------------------------------------------------- draw mode (USB mouse)
// The Basys 3's USB host chip turns a USB mouse into a PS/2 mouse (code/io/ps2.v).
#define PS2_RX     (*(volatile uint32_t *)0x40000000)
#define PS2_TX     (*(volatile uint32_t *)0x40000004)
#define PS2_STATUS (*(volatile uint32_t *)0x40000008)

#define PS2_MS 50000u                                               // PS/2 timeouts: real ms always
#ifdef SIM
#define MS 50u                                                      // simulation: short idle wait
#else
#define MS 50000u
#endif

static int ps2_get(uint32_t ms)
{
    uint32_t t0 = now();
    while (!(PS2_STATUS & 1u))
        if (now() - t0 > ms * PS2_MS) return -1;
    int b = (int)(PS2_RX & 0xFFu);
    PS2_RX = 0;                                                     // drop it from the FIFO
    return b;
}

// send a command byte and wait for the mouse's 0xFA; 0 = done
static int mouse_cmd(uint8_t c)
{
    PS2_STATUS = 0;                                                 // clear old error flags
    PS2_TX = c;
    uint32_t t0 = now();
    while (PS2_STATUS & 2u)
        if (now() - t0 > 100u * PS2_MS) return -1;
    if (PS2_STATUS & 4u) return -1;                                 // no acknowledge
    return ps2_get(100) == 0xFA ? 0 : -1;
}

static int mouse_init(void)
{
    while (ps2_get(0) >= 0) ;                                       // empty the FIFO
    if (mouse_cmd(0xFF) < 0) return -1;                             // reset
    if (ps2_get(1000) != 0xAA) return -1;                           // self-test passed
    ps2_get(100);                                                   // device id 0x00
    return mouse_cmd(0xF4);                                         // start sending movement
}

#define CANVAS 96                                                   // drawing, in pic[] (96x96)
#define CV_X   24                                                   // on the TFT: 2x, 192x192
#define CV_Y   24
static int8_t *const canvas = pic;
static int  m_ok = -1, m_x = 48 * 4, m_y = 48 * 4;                  // cursor, 1/4 canvas pixels
static int  m_btn, m_ink, m_done, m_n;                              // buttons, ink, recognised
static uint8_t m_pk[3];
static uint32_t m_idle;
static int  pic_is_canvas;                                          // the filter picture is gone
static int8_t small[20 * 20];

static void canvas_show(int x0, int y0, int x1, int y1)            // canvas pixels x0..x1, y0..y1
{
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > CANVAS - 1) x1 = CANVAS - 1;
    if (y1 > CANVAS - 1) y1 = CANVAS - 1;
    if (x0 > x1 || y0 > y1) return;
    tft_image(CV_X + 2 * x0, CV_Y + 2 * y0, canvas + y0 * CANVAS + x0, x1 - x0 + 1, y1 - y0 + 1, CANVAS, 2);
}

static void cursor_show(void)
{
    tft_fill(CV_X + 2 * (m_x >> 2) - 1, CV_Y + 2 * (m_y >> 2) - 1, 4, 4, C_RED);
}

static void cursor_hide(int x, int y)                               // redraw the canvas under it
{
    canvas_show((x >> 2) - 1, (y >> 2) - 1, (x >> 2) + 1, (y >> 2) + 1);
}

// a soft round brush (radius about 4 canvas pixels) at (x, y) in 1/4 pixels
static void brush(int x, int y)
{
    int cx = x >> 2, cy = y >> 2;
    for (int py = cy - 5; py <= cy + 5; py++)
        for (int px = cx - 5; px <= cx + 5; px++) {
            if (px < 0 || py < 0 || px >= CANVAS || py >= CANVAS) continue;
            int dx = px * 4 + 2 - x, dy = py * 4 + 2 - y;
            int d2 = dx * dx + dy * dy;                             // in 1/16 pixel^2
            int v = d2 <= 12 * 12 ? 127 : d2 >= 18 * 18 ? 0 : 127 * (18 * 18 - d2) / (18 * 18 - 12 * 12);
            if (v > canvas[py * CANVAS + px]) canvas[py * CANVAS + px] = (int8_t)v;
        }
}

static void draw_screen(void)
{
    tft_fill(0, 0, TFT_W, TFT_H, C_BLACK);
    header("Draw a digit with the mouse", C_BLUE);
    tft_fill(CV_X - 2, CV_Y - 2, 196, 196, C_GREY);
    for (int i = 0; i < CANVAS * CANVAS; i++) canvas[i] = 0;
    pic_is_canvas = 1;
    canvas_show(0, 0, CANVAS - 1, CANVAS - 1);
    m_ink = 0;  m_done = 0;  m_n = 0;
    if (m_ok != 0) m_ok = mouse_init();
    if (m_ok != 0) {
        tft_text(4, 230, "No mouse found. Plug a USB", 1, C_RED, C_BLACK);
        tft_text(4, 246, "mouse into the board's USB", 1, C_RED, C_BLACK);
        tft_text(4, 262, "port, then move a switch.", 1, C_RED, C_BLACK);
        print_str("no mouse\n");
        return;
    }
    tft_text(4, 300, "left: draw   right: clear", 1, C_GREY, C_BLACK);
    cursor_show();
}

// MNIST-style 28x28: the ink fitted into 20x20 (area average), centred by its centre of mass
static int canvas_to_mnist(void)
{
    int x0 = CANVAS, y0 = CANVAS, x1 = -1, y1 = -1;
    for (int y = 0; y < CANVAS; y++)
        for (int x = 0; x < CANVAS; x++)
            if (canvas[y * CANVAS + x] > 8) {
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                if (y > y1) y1 = y;
            }
    if (x1 < 0) return 0;
    int w = x1 - x0 + 1, h = y1 - y0 + 1, m = w > h ? w : h;
    int tw = (w * 20 + m / 2) / m, th = (h * 20 + m / 2) / m;
    if (tw < 1) tw = 1;
    if (th < 1) th = 1;
    int sum = 0, sx = 0, sy = 0;
    for (int ty = 0; ty < th; ty++)
        for (int tx = 0; tx < tw; tx++) {
            int ya = y0 + ty * h / th, yb = y0 + (ty + 1) * h / th;
            int xa = x0 + tx * w / tw, xb = x0 + (tx + 1) * w / tw;
            if (yb <= ya) yb = ya + 1;
            if (xb <= xa) xb = xa + 1;
            int s = 0, n = 0;
            for (int y = ya; y < yb; y++)
                for (int x = xa; x < xb; x++) { s += canvas[y * CANVAS + x]; n++; }
            int v = s / n;
            small[ty * 20 + tx] = (int8_t)v;
            sum += v;  sx += v * tx;  sy += v * ty;
        }
    int ox = 14 - (sx + sum / 2) / sum, oy = 14 - (sy + sum / 2) / sum;
    for (int i = 0; i < 784; i++) digit_px[i] = 0;
    for (int ty = 0; ty < th; ty++)
        for (int tx = 0; tx < tw; tx++) {
            int y = ty + oy, x = tx + ox;
            if (x >= 0 && x < 28 && y >= 0 && y < 28) digit_px[y * 28 + x] = (uint8_t)(small[ty * 20 + tx] * 2);
        }
    return 1;
}

static void draw_recognise(void)
{
    if (!canvas_to_mnist()) return;
    uint32_t t_cpu = infer(digit_px, 0);
    int32_t s_cpu[10];
    for (int i = 0; i < 10; i++) s_cpu[i] = scores[i];
    uint32_t t_acc = infer(digit_px, 1);
    int d = cnn_argmax(scores), same = 1;
    for (int i = 0; i < 10; i++) same &= s_cpu[i] == scores[i];

    tft_fill(0, 222, TFT_W, 98, C_BLACK);
    time_bar(222, "CPU   ", t_cpu, 232, C_ORANGE);
    time_bar(250, "ACCEL ", t_acc, (int)(232u * t_acc / t_cpu), C_BLUE);
    int x = tft_text(4, 280, "It is ", 2, C_WHITE, C_BLACK);
    tft_char(x, 280, (char)('0' + d), 2, C_GREEN, C_BLACK);
    speedup_text(x + 32, 288, t_cpu, t_acc, 1);
    tft_text(4, 306, same ? "CPU = accelerator, bit-exact" : "CPU and accelerator DIFFER  ",
             1, same ? C_GREEN : C_RED, C_BLACK);
    show_speedup(t_cpu, t_acc);

    // the same to the laptop, with the 28x28 image the network saw
    static const char hx[] = "0123456789abcdef";
    print_str("draw "); print_dec(d);
    print_str(" cpu "); print_dec(t_cpu / 50); print_str(" accel "); print_dec(t_acc / 50);
    print_str(same ? " same img " : " differ img ");
    for (int i = 0; i < 784; i++) { putchar_(hx[digit_px[i] >> 4]); putchar_(hx[digit_px[i] & 15]); }
    putchar_('\n');
}

// mouse packets: [buttons + signs, dx, dy]; move the cursor, paint while the left button is down
static void draw_poll(void)
{
    if (m_ok != 0) return;
    int b;
    while ((b = ps2_get(0)) >= 0) {
        if (m_n == 0 && !(b & 8)) continue;                         // not a first byte: resync
        m_pk[m_n++] = (uint8_t)b;
        if (m_n < 3) continue;
        m_n = 0;
        int dx = m_pk[1] - ((m_pk[0] & 0x10) ? 256 : 0);
        int dy = m_pk[2] - ((m_pk[0] & 0x20) ? 256 : 0);
        int btn = m_pk[0] & 3;
        int ox = m_x, oy = m_y;
        m_x += dx * 2;  m_y -= dy * 2;                              // PS/2: y grows upwards
        if (m_x < 0) m_x = 0;
        if (m_y < 0) m_y = 0;
        if (m_x > CANVAS * 4 - 1) m_x = CANVAS * 4 - 1;
        if (m_y > CANVAS * 4 - 1) m_y = CANVAS * 4 - 1;
        cursor_hide(ox, oy);

        if ((btn & 2) && !(m_btn & 2)) {                            // right click: clear
            for (int i = 0; i < CANVAS * CANVAS; i++) canvas[i] = 0;
            canvas_show(0, 0, CANVAS - 1, CANVAS - 1);
            tft_fill(0, 222, TFT_W, 76, C_BLACK);
            m_ink = 0;  m_done = 0;
        }
        if (btn & 1) {
            if (!(m_btn & 1) && m_done) {                           // a new digit: clean canvas
                for (int i = 0; i < CANVAS * CANVAS; i++) canvas[i] = 0;
                canvas_show(0, 0, CANVAS - 1, CANVAS - 1);
                m_done = 0;
                ox = m_x;  oy = m_y;
            }
            if (!(m_btn & 1)) { ox = m_x;  oy = m_y; }              // stroke starts here
            int adx = m_x > ox ? m_x - ox : ox - m_x, ady = m_y > oy ? m_y - oy : oy - m_y;
            int steps = (adx > ady ? adx : ady) / 4 + 1;
            for (int s = 1; s <= steps; s++)
                brush(ox + (m_x - ox) * s / steps, oy + (m_y - oy) * s / steps);
            int ax = (ox < m_x ? ox : m_x) >> 2, bx = (ox > m_x ? ox : m_x) >> 2;
            int ay = (oy < m_y ? oy : m_y) >> 2, by = (oy > m_y ? oy : m_y) >> 2;
            canvas_show(ax - 5, ay - 5, bx + 5, by + 5);
            m_ink = 1;
            m_idle = now();
        }
        m_btn = btn;
        cursor_show();
    }
    // 0.8 s after the last stroke (time for a second stroke, as for a 4 or a 7): recognise
    if (m_ink && !m_done && !(m_btn & 1) && now() - m_idle > 800u * MS) {
        draw_recognise();
        m_done = 1;
        cursor_show();
    }
}

// ---------------------------------------------------------------- main loop
int main(void)
{
    uint32_t sw = IO_SWITCHES;
    tft_init(sw & 1u);
    default_picture();
    print_str("nn_demo ready: modes digit / filter / race (sw[2:1])\n");

    int mode = -1, pc_mode = -1;                                   // pc_mode: set by the laptop
    uint32_t last_sw = 0xFFFFFFFFu, race_t = 0;
    for (;;) {
        sw = IO_SWITCHES;
        if (sw != last_sw) {                                       // switches moved: they decide
            if ((sw & 1u) != (last_sw & 1u)) TFT_CTRL = 3u | ((sw & 1u) ? 8u : 0u);
            last_sw = sw;
            pc_mode = -1;
        }
        int want = pc_mode >= 0 ? pc_mode : (int)((sw >> 1) & 3u);

        // a command from the laptop
        int c = getchar_nb();
        if (c == 'D' || c == 'P') {
            putchar_(0x06);                                        // ACK: send the payload
            uart_flush();
            if (c == 'D' && read_bytes(digit_px, 784)) {
                if (mode != 0) { digit_screen(); mode = 0; }
                pc_mode = 0;
                digit_run();
                continue;
            }
            if (c == 'P' && read_bytes((uint8_t *)pic, PIC * PIC)) {
                pic_is_canvas = 0;
                for (int i = 0; i < PIC * PIC; i++) pic[i] = (int8_t)((uint8_t)pic[i] >> 1);
                pc_mode = 1;  mode = -1;
                print_str("picture received\n");
                continue;
            }
            print_str("timeout\n");
        }

        if (want != mode) {
            mode = want;
            if (mode == 0) digit_screen();
            if (mode == 1) { if (pic_is_canvas) { default_picture(); pic_is_canvas = 0; } filter_screen(); }
            if (mode == 3) draw_screen();
            if (mode == 2) race_t = 0;
        }
        if (mode == 1) filter_frame((sw >> 3) & 1u);
        if (mode == 3) draw_poll();
        if (mode == 2 && (race_t == 0 || now() - race_t > 250000000u)) {   // again every 5 s
            race_run();
            race_t = now();
        }
    }
}
