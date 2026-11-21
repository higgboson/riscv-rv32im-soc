// raycast - a Wolfenstein 3D style first-person maze on the 2.4" TFT, running on the RV32IM SoC
//
// The panel is turned to landscape (320 x 240). The top 192 rows are the 3D view, the bottom
// 48 rows a status bar with a minimap that fills in as you see the maze. Find the green exit.
//
// How it draws: one ray per 2-pixel screen column (160 rays). Each ray walks the 24 x 24 grid
// cell by cell (DDA, all fixed point Q16, no floating point) until it hits a wall; the distance
// gives the wall height, the wall type and side give the colour, and the colour fades with
// distance. A column is then just three solid runs (ceiling, wall, floor), which the TFT
// controller's hardware FILL sends without the CPU touching each pixel. Only what changed since
// the last frame is redrawn: if a column's wall keeps its colour, only the strip between the old
// and new wall edges is sent.
//
// Controls (any of them):
//   board buttons   btnU forward, btnD back, btnL / btnR turn; btnC restarts the program
//   laptop keyboard (in the load.py window)  w / s or up / down walk, a / d or left / right
//                   turn, q / e step sideways, r new game, o turns the picture (if it is
//                   upside down or mirrored on your panel)
//   USB mouse in the board (optional)  slide left / right to look around, hold the left button
//                   to walk forward, the right button to walk back
// Switches: sw[0] fast display clock (25 MHz), sw[1] starts with the picture turned 180 degrees.

#include "console.h"
#include "perf.h"
#include "tft.h"
#include "sintab.h"

#ifdef SIM
#define MS     500u                                     // simulation: 1 "ms" = 500 cycles
#else
#define MS     50000u                                   // cycles per millisecond at 50 MHz
#endif

#define VH     192                                      // 3D view: rows 0..191
#define HOR    (VH / 2)                                 // horizon
#define NCOL   160                                      // rays, 2 pixels wide each
#define MW     24
#define MH     24
#define ONE    65536                                    // 1.0 in Q16
#define PLANE  43254                                    // 0.66: a 66 degree field of view
#define PROJ   240                                      // wall height in pixels 1 cell away
#define MARGIN 16384                                    // keep 0.25 cells away from walls
#define MMX    4                                        // minimap, 2 x 2 pixels per cell
#define MMY    VH
#define TX     60                                       // status text

typedef int32_t fx;                                     // Q16 fixed point
static inline fx fmul(fx a, fx b) { return (fx)(((int64_t)a * b) >> 16); }
static inline fx fsin(int a) { return (fx)sintab[a & 1023] * 4; }   // a: 1024 per turn
static inline fx fcos(int a) { return fsin(a + 256); }
static uint32_t now(void) { return PERF_CYCLES; }

// 1..4 walls (blue stone, grey stone, red brick, wood), X the exit, P the start
static const char *const level[MH] = {
    "111111111111111111111111",
    "1P....1.......2........1",
    "1.11..1..222..2..333...1",
    "1.1...1..2.2.....3.3...1",
    "1.1..11..2.2..2..3.3...1",
    "1........2....2........1",
    "1111.1.11112222.4444.441",
    "1....1......2.....4....1",
    "1.3333..44..2.11..4..4.1",
    "1.3..3..44.....1.......1",
    "1.3..3......1111..2222.1",
    "1.3..33333..1.....2....1",
    "1...........1.33..2.22.1",
    "1222222.2222..3...2..2.1",
    "1.......2.....3333...2.1",
    "1.444...2.11.......4.2.1",
    "1.4.4...2.1..222...4...1",
    "1.4.4.222.1....2...44441",
    "1...4.....1111.2.......1",
    "1.444.33.......2222..1.1",
    "1.....3..4444......2.1.1",
    "13333.3..4..4..33..2.1.1",
    "1........4.........2...X",
    "111111111111111111111111",
};
#define EXIT 5
static const uint8_t base[6][3] = {
    {0, 0, 0}, {70, 100, 210}, {150, 150, 150}, {190, 72, 48}, {165, 112, 60}, {40, 235, 100},
};
static const uint8_t seam[6] = {255, 64, 128, 43, 32, 255};    // block / slab / plank edges

static uint8_t  map[MH][MW];                            // 0 open, 1..4 wall, 5 exit
static uint8_t  seen[MH][MW];                           // 1 seen, 2 also on the minimap
static fx       px, py;                                 // player position (cells, Q16)
static int      ang16;                                  // view direction, 16384 per turn
static int16_t  ptop[NCOL], pbot[NCOL];                 // what each column shows now
static uint16_t pcol[NCOL];
static uint16_t bg[VH / 8];                             // ceiling / floor colour, 8-row bands
static int      last_cell, won, ori;
static uint32_t game_ms;
static const uint8_t madctl[4] = {0x68, 0xA8, 0x28, 0xE8};     // the 4 landscape turns

// ---------------------------------------------------------------- drawing
static void fill_bg(int x, int y0, int y1)              // ceiling / floor rows y0..y1-1
{
    while (y0 < y1) {
        int e = (y0 & ~7) + 8;
        if (e > y1) e = y1;
        tft_fill(x, y0, 2, e - y0, bg[y0 >> 3]);
        y0 = e;
    }
}

static uint16_t shade(int t, int s)                     // wall colour t at brightness s / 256
{
    return RGB(base[t][0] * s >> 8, base[t][1] * s >> 8, base[t][2] * s >> 8);
}

// 1/|r| in Q16, capped at 64 cells
static fx inv(fx r)
{
    uint32_t a = (uint32_t)(r < 0 ? -r : r);
    if (a < 1024u) return 64 * ONE;
    uint32_t v = 0xFFFFFFFFu / a;
    return (fx)(v > 64u * ONE ? 64u * ONE : v);
}

static void render(void)
{
    int a = ang16 >> 4;
    fx dx = fcos(a), dy = fsin(a);
    fx plx = fmul(-dy, PLANE), ply = fmul(dx, PLANE);
    int cx = px >> 16, cy = py >> 16;
    fx fxr = px & 0xFFFF, fyr = py & 0xFFFF;
    seen[cy][cx] |= 1;

    for (int c = 0; c < NCOL; c++) {
        fx cam = (fx)((2 * c + 1 - NCOL) * ONE / NCOL);         // -1 (left) .. 1 (right)
        fx rx = dx + fmul(plx, cam), ry = dy + fmul(ply, cam);
        fx ddx = inv(rx), ddy = inv(ry), sdx, sdy;
        int stx, sty, mx = cx, my = cy, side = 0, t = 0;
        if (rx < 0) { stx = -1; sdx = fmul(fxr, ddx); } else { stx = 1; sdx = fmul(ONE - fxr, ddx); }
        if (ry < 0) { sty = -1; sdy = fmul(fyr, ddy); } else { sty = 1; sdy = fmul(ONE - fyr, ddy); }
        for (int n = 0; n < 48; n++) {                  // walk the grid to the first wall
            if (sdx < sdy) { sdx += ddx; mx += stx; side = 0; }
            else           { sdy += ddy; my += sty; side = 1; }
            seen[my][mx] |= 1;
            if ((t = map[my][mx]) != 0) break;
        }
        fx perp = side ? sdy - ddy : sdx - ddx;         // distance along the view direction
        if (perp < 2048) perp = 2048;
        int lh = (int)((PROJ << 16) / perp);
        int top = HOR - (lh >> 1), bot = HOR + (lh >> 1);
        if (top < 0) top = 0;
        if (bot > VH) bot = VH;

        // colour: fades to black about 9 cells away (the exit keeps glowing), the y sides a
        // bit darker, and dark seams where blocks / slabs / planks meet
        int s = 256 - (perp >> 12) * 7 / 4;
        if (t == EXIT && s < 170) s = 170;
        if (s < 20) s = 20;
        if (side) s = s * 3 / 4;
        fx wx = side ? px + fmul(perp, rx) : py + fmul(perp, ry);
        int f = (wx >> 8) & 0xFF;                       // where across the block it hit
        if (f % seam[t] < 6 || f > 249) s >>= 1;
        uint16_t col = shade(t, s & ~7);

        // send only what changed
        int x = c * 2, ot = ptop[c], ob = pbot[c];
        if (col != pcol[c]) tft_fill(x, top, 2, bot - top, col);
        else {
            if (top < ot) tft_fill(x, top, 2, ot - top, col);
            if (bot > ob) tft_fill(x, ob, 2, bot - ob, col);
        }
        if (top > ot) fill_bg(x, ot, top);
        if (bot < ob) fill_bg(x, bot, ob);
        ptop[c] = (int16_t)top;  pbot[c] = (int16_t)bot;  pcol[c] = col;
    }
}

static void mm_cell(int x, int y)
{
    int t = map[y][x];
    uint16_t c = t == 0 ? RGB(55, 55, 60) : t == EXIT ? shade(EXIT, 256) : shade(t, 140);
    tft_fill(MMX + x * 2, MMY + y * 2, 2, 2, c);
}

static void minimap(void)
{
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++)
            if (seen[y][x] == 1) { seen[y][x] = 2; mm_cell(x, y); }
    int cell = (py >> 16) * MW + (px >> 16);
    if (cell != last_cell) {
        if (last_cell >= 0) mm_cell(last_cell % MW, last_cell / MW);
        last_cell = cell;
        tft_fill(MMX + (cell % MW) * 2, MMY + (cell / MW) * 2, 2, 2, C_RED);
    }
}

static void redraw_all(void)                            // the whole screen from the game state
{
    tft_cmd(0x36); tft_data(madctl[ori]);
    for (int b = 0; b < VH / 8; b++) tft_fill(0, b * 8, 320, 8, bg[b]);
    tft_fill(0, VH, 320, 240 - VH, C_DARK);
    tft_fill(MMX, MMY, MW * 2, MH * 2, C_BLACK);
    for (int c = 0; c < NCOL; c++) { ptop[c] = pbot[c] = HOR; pcol[c] = 1; }
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++) if (seen[y][x]) seen[y][x] = 1;
    last_cell = -1;
    tft_text(TX, 199, "RISC-V 3D  find the exit", 1, C_WHITE, C_DARK);
    tft_text(TX, 213, "FPS", 1, C_GREY, C_DARK);
    tft_text(TX + 72, 213, "FRAME", 1, C_GREY, C_DARK);
    tft_text(TX + 168, 213, "ms", 1, C_GREY, C_DARK);
    tft_text(TX, 227, "TIME", 1, C_GREY, C_DARK);
}

static void new_game(void)
{
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++) {
            char ch = level[y][x];
            map[y][x] = ch >= '1' && ch <= '4' ? (uint8_t)(ch - '0') : ch == 'X' ? EXIT : 0;
            seen[y][x] = 0;
            if (ch == 'P') { px = x * ONE + ONE / 2; py = y * ONE + ONE / 2; }
        }
    ang16 = 0;                                          // facing east (+x)
    game_ms = 0;
    won = 0;
    redraw_all();
    print_str("raycast: new game\n");
}

// ---------------------------------------------------------------- moving
static int blocked(fx x, fx y)                          // a wall under the player's square?
{
    for (int k = 0; k < 4; k++) {
        fx cx = x + ((k & 1) ? MARGIN : -MARGIN), cy = y + ((k & 2) ? MARGIN : -MARGIN);
        int v = map[cy >> 16][cx >> 16];
        if (v) return v;
    }
    return 0;
}

static void walk(fx mx, fx my)                          // x and y separately: slide along walls
{
    int v;
    if (mx) { if (!(v = blocked(px + mx, py))) px += mx; else if (v == EXIT) won = 1; }
    if (my) { if (!(v = blocked(px, py + my))) py += my; else if (v == EXIT) won = 1; }
}

// ---------------------------------------------------------------- the mouse (optional)
#define PS2_RX     (*(volatile uint32_t *)0x40000000)
#define PS2_TX     (*(volatile uint32_t *)0x40000004)
#define PS2_STATUS (*(volatile uint32_t *)0x40000008)
static int m_ok, m_n, m_btn;
static uint8_t m_pk[3];

static int ps2_get(uint32_t ms)
{
    uint32_t t0 = now();
    while (!(PS2_STATUS & 1u)) if (now() - t0 > ms * MS) return -1;
    int b = (int)(PS2_RX & 0xFFu);
    PS2_RX = 0;
    return b;
}

static int mouse_cmd(uint8_t c)
{
    PS2_STATUS = 0;
    PS2_TX = c;
    uint32_t t0 = now();
    while (PS2_STATUS & 2u) if (now() - t0 > 100u * MS) return -1;
    if (PS2_STATUS & 4u) return -1;
    return ps2_get(100) == 0xFA ? 0 : -1;
}

static void mouse_init(void)
{
    while (ps2_get(0) >= 0) ;
    m_ok = mouse_cmd(0xFF) == 0 && ps2_get(1000) == 0xAA;
    if (m_ok) { ps2_get(100); m_ok = mouse_cmd(0xF4) == 0; }
    m_n = m_btn = 0;
    print_str(m_ok ? "raycast: mouse found\n" : "raycast: no mouse (buttons and keys work)\n");
}

static int mouse_poll(void)                             // sideways movement since last time
{
    int pk, mdx = 0;
    while (m_ok && (pk = ps2_get(0)) >= 0) {
        if (m_n == 0 && !(pk & 8)) continue;            // resync on the first byte's bit 3
        m_pk[m_n++] = (uint8_t)pk;
        if (m_n < 3) continue;
        m_n = 0;
        mdx += m_pk[1] - ((m_pk[0] & 0x10) ? 256 : 0);
        m_btn = m_pk[0] & 3;
    }
    return mdx;
}

// ---------------------------------------------------------------- main loop
static void show_win(void)
{
    tft_fill(60, 62, 200, 64, C_DARK);
    tft_fill(62, 64, 196, 60, C_BLACK);
    tft_text(112, 72, "YOU ESCAPED!", 1, C_GREEN, C_BLACK);
    int x = tft_text(96, 90, "time ", 1, C_WHITE, C_BLACK);
    x = tft_fixed(x, 90, game_ms / 100u, 1, 1, C_WHITE, C_BLACK);
    tft_text(x, 90, " s", 1, C_WHITE, C_BLACK);
    tft_text(96, 106, "press any key", 1, C_GREY, C_BLACK);
    print_str("raycast: escaped in "); print_dec((int32_t)(game_ms / 1000u));
    print_str("."); print_dec((int32_t)(game_ms / 100u % 10u)); print_str(" s\n");
}

int main(void)
{
    uint32_t sw = IO_SWITCHES;
    tft_init(sw & 1u);
    ori = (sw & 2u) ? 1 : 0;
    for (int b = 0; b < VH / 8; b++) {                  // ceiling darkens towards the horizon,
        int k = b < VH / 16 ? VH / 16 - 1 - b : b - VH / 16;  // the floor lightens towards you
        bg[b] = b < VH / 16 ? RGB(14 + k * 4, 14 + k * 4, 18 + k * 4)
                            : RGB(12 + k * 5, 10 + k * 4, 8 + k * 3);
    }
    mouse_init();
    new_game();

    // walking keys stay "held" for 150 ms after each key (the PC repeats a held key ~30x / s)
    enum { K_FWD, K_BACK, K_LEFT, K_RIGHT, K_SL, K_SR, NK };
    uint32_t until[NK] = {0};
    uint32_t last = now(), frames = 0, fps_ms = 0, busy = 0, hud_ms = 0;
    for (;;) {
        uint32_t t = now();
        uint32_t raw = (t - last) / MS;
        last += raw * MS;
        game_ms += raw;  fps_ms += raw;  hud_ms += raw;
        int dt = raw > 100u ? 100 : (int)raw;

        int c = getchar_nb(), mdx = mouse_poll();
        uint32_t b = IO_BUTTONS & 0xFu;
        if (won) {
            if (c >= 0 || b || (m_btn & 3)) {
                while (IO_BUTTONS & 0xFu) ;
                new_game();
            }
            continue;
        }
        if (c == 'w') until[K_FWD]   = t + 150u * MS;
        if (c == 's') until[K_BACK]  = t + 150u * MS;
        if (c == 'a') until[K_LEFT]  = t + 150u * MS;
        if (c == 'd') until[K_RIGHT] = t + 150u * MS;
        if (c == 'q') until[K_SL]    = t + 150u * MS;
        if (c == 'e') until[K_SR]    = t + 150u * MS;
        if (c == 'r') { new_game(); continue; }
        if (c == 'o') {
            ori = (ori + 1) & 3;
            print_str("raycast: picture turn "); print_dec(ori); print_str("\n");
            redraw_all();
            continue;
        }
        int held[NK];
        for (int k = 0; k < NK; k++) held[k] = (int32_t)(until[k] - t) > 0;
        int fwd  = (held[K_FWD] || (b & 1u) || (m_btn & 1)) - (held[K_BACK] || (b & 8u) || (m_btn & 2));
        int turn = (held[K_RIGHT] || (b & 4u)) - (held[K_LEFT] || (b & 2u));
        int strafe = held[K_SR] - held[K_SL];

        ang16 = (ang16 + turn * dt * 8 + mdx * 10) & 16383;    // 180 degrees a second
        int a = ang16 >> 4;
        fx step = (fx)dt * 160;                                 // 2.4 cells a second
        fx mx = 0, my = 0;
        if (fwd)    { mx += fwd * fmul(fcos(a), step);    my += fwd * fmul(fsin(a), step); }
        if (strafe) { mx -= strafe * fmul(fsin(a), step); my += strafe * fmul(fcos(a), step); }
        walk(mx, my);

        uint32_t f0 = now();
        render();
        minimap();
        busy += now() - f0;
        frames++;
        if (won) { show_win(); continue; }

        if (hud_ms >= 250u) {                           // the clock, 4 times a second
            hud_ms = 0;
            int x = tft_fixed(TX + 40, 227, game_ms / 100u, 1, 1, C_WHITE, C_DARK);
            tft_text(x, 227, " s  ", 1, C_WHITE, C_DARK);
        }
        if (fps_ms >= 1000u) {                          // frames per second, frame time
            uint32_t ms = busy / frames / MS;
            int x = tft_num(TX + 32, 213, frames, 1, C_WHITE, C_DARK);
            tft_fill(x, 213, TX + 72 - x, 12, C_DARK);
            x = tft_num(TX + 120, 213, ms, 1, C_WHITE, C_DARK);
            tft_fill(x, 213, TX + 168 - x, 12, C_DARK);
            print_str("raycast: "); print_dec((int32_t)frames); print_str(" fps, ");
            print_dec((int32_t)ms); print_str(" ms per frame\n");
            frames = 0;  fps_ms = 0;  busy = 0;
        }
    }
}
