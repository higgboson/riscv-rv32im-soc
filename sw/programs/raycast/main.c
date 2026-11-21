// raycast - a Wolfenstein 3D style first-person maze with ghouls, on the 2.4" TFT, running on
// the RV32IM SoC
//
// The panel is turned to landscape (320 x 240). The top 192 rows are the 3D view, the bottom
// 48 rows a status bar with a minimap that fills in as you see the maze. Find the green exit.
// Ten ghouls lurk in the maze: they wake when they see you, chase you and claw you when they
// get close (100 HP, about 12 per hit). Two shots kill one and leave a bloody corpse.
//
// How it draws: one ray per 2-pixel screen column (160 rays). Each ray walks the 24 x 24 grid
// cell by cell (DDA, all fixed point Q16, no floating point) until it hits a wall; the distance
// gives the wall height, the wall type and side give the colour, and the colour fades with
// distance. A column is then just three solid runs (ceiling, wall, floor), which the TFT
// controller's hardware FILL sends without the CPU touching each pixel. Only what changed since
// the last frame is redrawn: if a column's wall keeps its colour, only the strip between the old
// and new wall edges is sent.
// Ghouls are 16x16 pixel sprites scaled with distance and hidden where the wall in that column
// is nearer. A column with a ghoul in it is put together in memory first (ceiling, wall, floor,
// then the ghouls far to near) and sent once as runs of one colour, so nothing flickers; it is
// redrawn whole on the next frame. Each column of the gun is solid from some row down, so the
// scene is simply never drawn below that row in the gun's columns and the gun is drawn once.
//
// Controls (any of them):
//   board buttons   btnU forward, btnD back, btnL / btnR turn, btnL + btnR together shoot;
//                   btnC restarts the program
//   laptop keyboard (in the load.py window)  w / s or up / down walk, a / d or left / right
//                   turn, q / e step sideways, space or f shoots, r new game, o turns the
//                   picture (if it is upside down or mirrored on your panel)
//   USB mouse in the board (optional)  slide left / right to look around, left click shoots,
//                   hold the right button to walk forward
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
#define MARGIN 16384                                    // the player keeps 0.25 cells from walls
#define EMARGIN 13107                                   // a ghoul 0.2
#define MMX    4                                        // minimap, 2 x 2 pixels per cell
#define MMY    VH
#define TX     60                                       // status text
#define GUN_C  72                                       // gun: columns 72..87, rows 152..191
#define GUN_Y  152
#define NE     10
#define EHP    2

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
#ifdef TEST_ENEMY                                       // simulation test: one in the first corridor
static const uint8_t epos[NE][2] = {{4,1},{11,8},{4,9},{15,5},{22,3},{13,12},{3,16},{18,14},{10,21},{22,22}};
#else
static const uint8_t epos[NE][2] = {{6,5},{11,8},{4,9},{15,5},{22,3},{13,12},{3,16},{18,14},{10,21},{22,22}};
#endif
#define EXIT 5
static const uint8_t base[6][3] = {
    {0, 0, 0}, {70, 100, 210}, {150, 150, 150}, {190, 72, 48}, {165, 112, 60}, {40, 235, 100},
};
static const uint8_t seam[6] = {255, 64, 128, 43, 32, 255};    // block / slab / plank edges

// ---------------------------------------------------------------- sprites ('.' = see-through)
static const char *const ghoul[16] = {
    ".....dggggd.....",
    "....dggggggd....",
    "...dgrrggrrgd...",
    "...dgrrggrrgd...",
    "...dggggggggd...",
    "....dgkwwkgd....",
    "....dgkkkkgd....",
    ".....dgrrgd.....",
    "...bbbrbbbbbb...",
    "..gbbbbrbbbbbg..",
    ".gg.bbrrbbbb.gg.",
    ".gr.bbbbbbbb.rg.",
    "...bbbbrbbbbb...",
    "....bbb..bbb....",
    "....dd....dd....",
    "...ddd....ddd...",
};
static const char *const corpse[16] = {
    "................", "................", "................", "................",
    "................", "................", "................", "................",
    "................", "................",
    "......dggd......",
    "..rr.dgrrgd.rr..",
    ".rrrrbbbrbbrrrr.",
    "rrrrrrrbbrrrrrrr",
    ".rrrrrrrrrrrrrr.",
    "....rrrrrrrr....",
};
static const char *const gun[20] = {
    "......kkkk......",
    "......kmmk......",
    "......kmmk......",
    "......kmmk......",
    ".....kmmmmk.....",
    ".....kmmmmk.....",
    ".....kmkkmk.....",
    "....kmmmmmmk....",
    "....kmmmmmmk....",
    "...hhkmmmmkhh...",
    "..hhhhkmmkhhhh..",
    "..hhhhhkkhhhhh..",
    ".hhhhhhhhhhhhhh.",
    ".hhhhhhhhhhhhhh.",
    "hhhhhhhhhhhhhhhh",
    "hhhhhhhhhhhhhhhh",
    "hhhhhhhhhhhhhhhh",
    "hhhhhhhhhhhhhhhh",
    "hhhhhhhhhhhhhhhh",
    "hhhhhhhhhhhhhhhh",
};
static void art_rgb(char ch, int *r, int *g, int *b)
{
    switch (ch) {
    case 'g': *r = 150; *g = 175; *b = 120; break;      // dead pale skin
    case 'd': *r = 70;  *g = 90;  *b = 60;  break;      // shadow
    case 'r': *r = 200; *g = 10;  *b = 10;  break;      // eyes, blood
    case 'k': *r = 20;  *g = 10;  *b = 10;  break;      // mouth, gun metal edge
    case 'w': *r = 230; *g = 220; *b = 190; break;      // teeth
    case 'b': *r = 90;  *g = 60;  *b = 45;  break;      // rags
    case 'm': *r = 95;  *g = 100; *b = 110; break;      // gun metal
    default:  *r = 185; *g = 140; *b = 110; break;      // 'h' hand
    }
}
static uint16_t art_col(char ch, int s, int white)
{
    int r, g, b;
    if (white) return C_WHITE;
    art_rgb(ch, &r, &g, &b);
    return RGB(r * s >> 8, g * s >> 8, b * s >> 8);
}

// ---------------------------------------------------------------- state
typedef struct { fx x, y; int8_t hp, awake, flash; uint32_t cd; } ghoul_t;
static ghoul_t  en[NE];
static uint8_t  map[MH][MW];                            // 0 open, 1..4 wall, 5 exit
static uint8_t  seen[MH][MW];                           // 1 seen, 2 also on the minimap
static fx       px, py;                                 // player position (cells, Q16)
static int      ang16;                                  // view direction, 16384 per turn
static int16_t  ptop[NCOL], pbot[NCOL];                 // what each column shows now
static uint16_t pcol[NCOL];
static fx       zbuf[NCOL];                             // wall distance of each column
static int16_t  clip[NCOL];                             // the scene stops here (the gun below)
static uint16_t cbuf[VH];                               // one column put together in memory
static uint16_t bg[VH / 8];                             // ceiling / floor colour, 8-row bands
static int      last_cell, won, dead, ori, hp, kills;
static uint32_t game_ms;
static const uint8_t madctl[4] = {0x68, 0xA8, 0x28, 0xE8};     // the 4 landscape turns

// ---------------------------------------------------------------- drawing
static void vfill(int c, int y0, int y1, uint16_t col)  // rows y0..y1-1 of column c
{
    if (y1 > clip[c]) y1 = clip[c];
    if (y1 > y0) tft_fill(c * 2, y0, 2, y1 - y0, col);
}

static void dirty(int c) { ptop[c] = 0; pbot[c] = VH; pcol[c] = 1; }   // redraw whole next time

static void fill_bg(int c, int y0, int y1)              // ceiling / floor rows y0..y1-1
{
    while (y0 < y1) {
        int e = (y0 & ~7) + 8;
        if (e > y1) e = y1;
        vfill(c, y0, e, bg[y0 >> 3]);
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

static int fog(fx dist)                                 // brightness 20..256 at this distance
{
    int s = 256 - (dist >> 12) * 7 / 4;
    return s < 20 ? 20 : s;
}

// ghouls in view, far to near
typedef struct { fx depth; int c0, w, top, hs, s, white; const char *const *art; } spr_t;
static spr_t spr[NE];
static int   nspr;
static void to_view(fx x, fx y, fx *depth, fx *lat);

static void project(void)
{
    nspr = 0;
    for (int i = 0; i < NE; i++) {
        fx depth, lat;
        to_view(en[i].x, en[i].y, &depth, &lat);
        if (depth < 13107) continue;                    // behind or too close (0.2 cells)
        int h = (int)((PROJ << 16) / depth);            // wall height at that distance
        if (h > 900) h = 900;
        spr_t q;
        q.depth = depth;
        q.hs = h * 13 / 16;                             // a ghoul is a bit shorter than a wall
        q.top = HOR + (h >> 1) - q.hs;                  // standing on the floor
        q.w = q.hs / 2 > 0 ? q.hs / 2 : 1;              // columns (2 pixels each)
        q.c0 = NCOL / 2 + (int)(((int64_t)lat * (NCOL / 2)) / fmul(depth, PLANE)) - q.w / 2;
        if (q.c0 >= NCOL || q.c0 + q.w <= 0) continue;
        q.s = fog(depth);
        q.white = en[i].flash;
        q.art = en[i].hp > 0 ? ghoul : corpse;
        en[i].flash = 0;
        int k = nspr++;
        while (k > 0 && spr[k - 1].depth < depth) { spr[k] = spr[k - 1]; k--; }
        spr[k] = q;
    }
}

// a column with a ghoul in it: scene, then the ghouls in front of the wall, sent as runs
static void compose(int c, int top, int bot, uint16_t col, fx perp)
{
    for (int y = 0; y < VH; y++) cbuf[y] = (y >= top && y < bot) ? col : bg[y >> 3];
    for (int k = 0; k < nspr; k++) {
        const spr_t *q = &spr[k];
        if (c < q->c0 || c >= q->c0 + q->w || q->depth >= perp) continue;
        int u = (c - q->c0) * 16 / q->w;
        for (int v = 0; v < 16; v++) {
            char ch = q->art[v][u];
            if (ch == '.') continue;
            int y0 = q->top + v * q->hs / 16, y1 = q->top + (v + 1) * q->hs / 16;
            if (y0 < 0) y0 = 0;
            if (y1 > VH) y1 = VH;
            uint16_t pc = art_col(ch, q->s, q->white);
            for (int y = y0; y < y1; y++) cbuf[y] = pc;
        }
    }
    for (int y = 0; y < clip[c]; ) {
        int e = y + 1;
        while (e < clip[c] && cbuf[e] == cbuf[y]) e++;
        tft_fill(c * 2, y, 2, e - y, cbuf[y]);
        y = e;
    }
    dirty(c);
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
        zbuf[c] = perp;
        int lh = (int)((PROJ << 16) / perp);
        int top = HOR - (lh >> 1), bot = HOR + (lh >> 1);
        if (top < 0) top = 0;
        if (bot > VH) bot = VH;

        // colour: fades to black about 9 cells away (the exit keeps glowing), the y sides a
        // bit darker, and dark seams where blocks / slabs / planks meet
        int s = fog(perp);
        if (t == EXIT && s < 170) s = 170;
        if (side) s = s * 3 / 4;
        fx wx = side ? px + fmul(perp, rx) : py + fmul(perp, ry);
        int f = (wx >> 8) & 0xFF;                       // where across the block it hit
        if (f % seam[t] < 6 || f > 249) s >>= 1;
        uint16_t col = shade(t, s & ~7);

        int k = 0;                                      // a ghoul in front of this wall?
        while (k < nspr && !(c >= spr[k].c0 && c < spr[k].c0 + spr[k].w && spr[k].depth < perp)) k++;
        if (k < nspr) { compose(c, top, bot, col, perp); continue; }

        // send only what changed
        int ot = ptop[c], ob = pbot[c];
        if (col != pcol[c]) vfill(c, top, bot, col);
        else {
            if (top < ot) vfill(c, top, ot, col);
            if (bot > ob) vfill(c, ob, bot, col);
        }
        if (top > ot) fill_bg(c, ot, top);
        if (bot < ob) fill_bg(c, bot, ob);
        ptop[c] = (int16_t)top;  pbot[c] = (int16_t)bot;  pcol[c] = col;
    }
}

// where a point lands in the view: depth along the view direction, sideways offset (Q16)
static void to_view(fx x, fx y, fx *depth, fx *lat)
{
    int a = ang16 >> 4;
    fx dx = fcos(a), dy = fsin(a), rx = x - px, ry = y - py;
    *depth = fmul(rx, dx) + fmul(ry, dy);
    *lat   = fmul(ry, dx) - fmul(rx, dy);
}

static void draw_gun(void)                              // once per redraw (nothing covers it)
{
    for (int c = GUN_C; c < GUN_C + 16; c++) {
        int u = c - GUN_C;
        for (int v = 0; v < 20; ) {
            char ch = gun[v][u];
            int v2 = v + 1;
            while (v2 < 20 && gun[v2][u] == ch) v2++;
            if (ch != '.') tft_fill(c * 2, GUN_Y + v * 2, 2, (v2 - v) * 2, art_col(ch, 256, 0));
            v = v2;
        }
    }
}

static void overlay(int flash)                          // muzzle flash and crosshair, each frame
{
    if (flash) {
        tft_fill(150, 128, 20, 22, C_YELLOW);
        tft_fill(155, 133, 10, 12, C_WHITE);
        for (int c = 75; c < 85; c++) dirty(c);
    }
    tft_fill(159, 89, 2, 14, C_WHITE);
    tft_fill(153, 95, 14, 2, C_WHITE);
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

static void hud_hp(void)
{
    int x = tft_num(TX + 136, 227, (uint32_t)(hp < 0 ? 0 : hp), 1, hp > 30 ? C_WHITE : C_RED, C_DARK);
    tft_fill(x, 227, TX + 168 - x, 12, C_DARK);
}

static void hud_kills(void)
{
    int x = tft_num(TX + 224, 227, (uint32_t)kills, 1, C_WHITE, C_DARK);
    x = tft_text(x, 227, "/", 1, C_GREY, C_DARK);
    tft_num(x, 227, NE, 1, C_GREY, C_DARK);
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
    draw_gun();
    tft_text(TX, 199, "RISC-V 3D  find the exit", 1, C_WHITE, C_DARK);
    tft_text(TX, 213, "FPS", 1, C_GREY, C_DARK);
    tft_text(TX + 72, 213, "FRAME", 1, C_GREY, C_DARK);
    tft_text(TX + 168, 213, "ms", 1, C_GREY, C_DARK);
    tft_text(TX, 227, "TIME", 1, C_GREY, C_DARK);
    tft_text(TX + 112, 227, "HP", 1, C_GREY, C_DARK);
    tft_text(TX + 176, 227, "KILLS", 1, C_GREY, C_DARK);
    hud_hp();
    hud_kills();
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
    for (int i = 0; i < NE; i++) {
        en[i].x = epos[i][0] * ONE + ONE / 2;  en[i].y = epos[i][1] * ONE + ONE / 2;
        en[i].hp = EHP;  en[i].awake = 0;  en[i].flash = 0;  en[i].cd = 0;
    }
    ang16 = 0;                                          // facing east (+x)
    game_ms = 0;
    won = dead = 0;
    hp = 100;
    kills = 0;
    redraw_all();
    print_str("raycast: new game\n");
}

// ---------------------------------------------------------------- moving
static int blocked(fx x, fx y, fx m)                    // a wall under a square of half-size m?
{
    for (int k = 0; k < 4; k++) {
        fx cx = x + ((k & 1) ? m : -m), cy = y + ((k & 2) ? m : -m);
        int v = map[cy >> 16][cx >> 16];
        if (v) return v;
    }
    return 0;
}

static void walk(fx mx, fx my)                          // x and y separately: slide along walls
{
    int v;
    if (mx) { if (!(v = blocked(px + mx, py, MARGIN))) px += mx; else if (v == EXIT) won = 1; }
    if (my) { if (!(v = blocked(px, py + my, MARGIN))) py += my; else if (v == EXIT) won = 1; }
}

static uint32_t isqrt64(uint64_t v)
{
    uint64_t r = 0, bit = (uint64_t)1 << 62;
    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; } else r >>= 1;
        bit >>= 2;
    }
    return (uint32_t)r;
}

static int sight(fx x0, fx y0, fx x1, fx y1)            // no wall on the straight line?
{
    fx sx = (x1 - x0) / 32, sy = (y1 - y0) / 32;
    for (int k = 1; k < 32; k++) {
        x0 += sx;  y0 += sy;
        if (map[y0 >> 16][x0 >> 16]) return 0;
    }
    return 1;
}

static uint32_t hurt_until;
static int      hurt_on;

static void ghouls(int dt, uint32_t t)                  // wake, chase, claw
{
    for (int i = 0; i < NE; i++) {
        ghoul_t *g = &en[i];
        if (g->hp <= 0) continue;
        fx rx = px - g->x, ry = py - g->y;
        fx dist = (fx)isqrt64((uint64_t)((int64_t)rx * rx + (int64_t)ry * ry));   // Q16
        if (!g->awake && dist < 7 * ONE && sight(g->x, g->y, px, py)) {
            g->awake = 1;
            print_str("raycast: a ghoul saw you\n");
        }
        if (!g->awake) continue;
        if (dist > 39322) {                             // 0.6 cells: walk towards the player
            fx step = (fx)dt * 90;                      // 1.4 cells a second
            fx mx = (fx)((int64_t)rx * step / dist), my = (fx)((int64_t)ry * step / dist);
            if (!blocked(g->x + mx, g->y, EMARGIN)) g->x += mx;
            if (!blocked(g->x, g->y + my, EMARGIN)) g->y += my;
        }
        if (dist < 45875 && t - g->cd > 800u * MS) {    // 0.7 cells: claw, every 0.8 s
            g->cd = t;
            hp -= 12;
            hurt_until = t + 200u * MS;
            hud_hp();
            if (hp <= 0) dead = 1;
        }
    }
}

static void shoot(void)                                 // the nearest ghoul under the crosshair
{
    fx wall = zbuf[NCOL / 2 - 1] < zbuf[NCOL / 2] ? zbuf[NCOL / 2 - 1] : zbuf[NCOL / 2];
    int best = -1;
    fx bd = wall;
    for (int i = 0; i < NE; i++) {
        if (en[i].hp <= 0) continue;
        fx d, l;
        to_view(en[i].x, en[i].y, &d, &l);
        if (d > 13107 && d < bd && l > -19661 && l < 19661) { best = i; bd = d; }  // +-0.3 cells
    }
    if (best < 0) return;
    en[best].awake = 1;
    en[best].flash = 1;
    if (--en[best].hp == 0) {
        kills++;
        hud_kills();
        print_str("raycast: ghoul down\n");
    }
}

// ---------------------------------------------------------------- the mouse (optional)
#define PS2_RX     (*(volatile uint32_t *)0x40000000)
#define PS2_TX     (*(volatile uint32_t *)0x40000004)
#define PS2_STATUS (*(volatile uint32_t *)0x40000008)
static int m_ok, m_n, m_btn;
static uint8_t m_pk[3];
static uint32_t m_last;                                 // when the last mouse byte came

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
        // a packet's 3 bytes come about 1 ms apart and packets at least 10 ms apart, so a gap
        // of 4 ms starts a new packet: once out of step, a movement byte read as the button
        // byte would leave the buttons stuck "held"
        uint32_t t = now();
        if (t - m_last > 4u * 50000u) m_n = 0;
        m_last = t;
        if (m_n == 0 && (!(pk & 8) || (pk & 0xC0))) continue;  // bit 3 set, no overflow bits
        m_pk[m_n++] = (uint8_t)pk;
        if (m_n < 3) continue;
        m_n = 0;
        mdx += m_pk[1] - ((m_pk[0] & 0x10) ? 256 : 0);
        m_btn = m_pk[0] & 3;
    }
    return mdx;
}

// ---------------------------------------------------------------- main loop
static void show_end(void)                              // escaped or dead
{
    if (dead) {
        tft_fill(0, 0, 320, VH, RGB(70, 0, 0));
        tft_fill(60, 62, 200, 64, RGB(20, 0, 0));
        tft_text(128, 72, "YOU DIED", 1, C_RED, RGB(20, 0, 0));
        int x = tft_text(96, 90, "kills ", 1, C_WHITE, RGB(20, 0, 0));
        x = tft_num(x, 90, (uint32_t)kills, 1, C_WHITE, RGB(20, 0, 0));
        tft_text(96, 106, "press any key", 1, C_GREY, RGB(20, 0, 0));
        print_str("raycast: you died, kills "); print_dec(kills); print_str("\n");
        return;
    }
    tft_fill(60, 62, 200, 64, C_DARK);
    tft_fill(62, 64, 196, 60, C_BLACK);
    tft_text(112, 72, "YOU ESCAPED!", 1, C_GREEN, C_BLACK);
    int x = tft_text(84, 90, "time ", 1, C_WHITE, C_BLACK);
    x = tft_fixed(x, 90, game_ms / 100u, 1, 1, C_WHITE, C_BLACK);
    x = tft_text(x, 90, " s  kills ", 1, C_WHITE, C_BLACK);
    tft_num(x, 90, (uint32_t)kills, 1, C_WHITE, C_BLACK);
    tft_text(96, 106, "press any key", 1, C_GREY, C_BLACK);
    print_str("raycast: escaped in "); print_dec((int32_t)(game_ms / 1000u));
    print_str("."); print_dec((int32_t)(game_ms / 100u % 10u)); print_str(" s, kills ");
    print_dec(kills); print_str("\n");
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
    for (int c = 0; c < NCOL; c++) {                   // gun columns: solid from this row down
        clip[c] = VH;
        if (c >= GUN_C && c < GUN_C + 16) {
            int v = 0;
            while (gun[v][c - GUN_C] == '.') v++;
            clip[c] = (int16_t)(GUN_Y + v * 2);
        }
    }
    mouse_init();
    new_game();

    // walking keys stay "held" for 150 ms after each key (the PC repeats a held key ~30x / s)
    enum { K_FWD, K_BACK, K_LEFT, K_RIGHT, K_SL, K_SR, NK };
    uint32_t until[NK] = {0};
    uint32_t last = now(), frames = 0, fps_ms = 0, busy = 0, hud_ms = 0;
    uint32_t last_shot = 0, flash_until = 0, prev_b = 0;
    int prev_mb = 0;
    for (;;) {
        uint32_t t = now();
        uint32_t raw = (t - last) / MS;
        last += raw * MS;
        game_ms += raw;  fps_ms += raw;  hud_ms += raw;
        int dt = raw > 100u ? 100 : (int)raw;

        int c = getchar_nb(), mdx = mouse_poll();
        uint32_t b = IO_BUTTONS & 0xFu;
        if (won || dead) {
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
        // keys and board buttons first; the mouse's right button walks when neither is used
        int fwd  = (held[K_FWD] || (b & 1u)) - (held[K_BACK] || (b & 8u));
        if (!fwd && (m_btn & 2)) fwd = 1;
        int turn = (held[K_RIGHT] || (b & 4u)) - (held[K_LEFT] || (b & 2u));
        int strafe = held[K_SR] - held[K_SL];
        int fire = c == ' ' || c == 'f' || ((m_btn & 1) && !(prev_mb & 1))
                || ((b & 6u) == 6u && (prev_b & 6u) != 6u);
        prev_mb = m_btn;  prev_b = b;

        ang16 = (ang16 + turn * dt * 8 + mdx * 10) & 16383;    // 180 degrees a second
        int a = ang16 >> 4;
        fx step = (fx)dt * 160;                                 // 2.4 cells a second
        fx mx = 0, my = 0;
        if (fwd)    { mx += fwd * fmul(fcos(a), step);    my += fwd * fmul(fsin(a), step); }
        if (strafe) { mx -= strafe * fmul(fsin(a), step); my += strafe * fmul(fcos(a), step); }
        walk(mx, my);
        ghouls(dt, t);

        uint32_t f0 = now();
        if (fire && t - last_shot > 300u * MS) {        // 3 shots a second at most (aimed at
            last_shot = t;                              // the walls of the last frame)
            flash_until = t + 80u * MS;
            shoot();
        }
        project();
        render();
        overlay((int32_t)(flash_until - t) > 0);
        minimap();
        busy += now() - f0;
        frames++;
        int hurt = (int32_t)(hurt_until - t) > 0;       // a red bar while being clawed
        if (hurt != hurt_on) { hurt_on = hurt; tft_fill(56, VH, 264, 4, hurt ? C_RED : C_DARK); }
        if (won || dead) { show_end(); continue; }

        if (hud_ms >= 250u) {                           // the clock, 4 times a second
            hud_ms = 0;
            int x = tft_fixed(TX + 40, 227, game_ms / 100u, 1, 1, C_WHITE, C_DARK);
            tft_fill(x, 227, TX + 112 - x, 12, C_DARK);
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
