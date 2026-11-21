// tetris - Tetris on the 2.4" TFT, running on the RV32IM SoC
//
// Controls (any of them):
//   board buttons   btnL / btnR move, btnU rotates, btnD drops faster (hold); btnC restarts
//   laptop keyboard (in the load.py window)  arrows or a / d move, w rotates, s one row down,
//                   space drops, p pauses, r starts a new game
//   USB mouse in the board (optional)  slide left / right to move, left click rotates,
//                   right click drops
// 10 x 20 well, 7 pieces from a shuffled bag, a ghost piece shows where it will land.
// Score: 40 / 100 / 300 / 1200 x (level + 1) for 1 / 2 / 3 / 4 lines, the level goes up every
// 10 lines and the pieces fall faster. The 7-segment display shows the score.

#include "console.h"
#include "perf.h"
#include "tft.h"

#ifdef SIM
#define MS     500u                                     // simulation: everything 100x faster
#else
#define MS     50000u                                   // cycles per millisecond at 50 MHz
#endif
#define W      10
#define H      20
#define CELL   12
#define WX     8                                        // well position on the screen
#define WY     36
#define SX     142                                      // side panel

static uint32_t now(void) { return PERF_CYCLES; }

// the 7 pieces x 4 rotations, each a 4x4 mask: bit 15 = row 0 column 0, row by row
static const uint16_t shapes[7][4] = {
    {0x0F00, 0x2222, 0x00F0, 0x4444},                   // I
    {0x6600, 0x6600, 0x6600, 0x6600},                   // O
    {0x4E00, 0x4640, 0x0E40, 0x4C40},                   // T
    {0x6C00, 0x4620, 0x06C0, 0x8C40},                   // S
    {0xC600, 0x2640, 0x0C60, 0x4C80},                   // Z
    {0x8E00, 0x6440, 0x0E20, 0x44C0},                   // J
    {0x2E00, 0x4460, 0x0E80, 0xC440},                   // L
};
static const uint16_t colour[8] = {
    C_BLACK,
    RGB(40, 210, 230),  RGB(240, 210, 40),  RGB(170, 80, 220), RGB(60, 200, 90),
    RGB(230, 60, 60),   RGB(60, 110, 230),  RGB(240, 140, 40),
};
static const uint16_t shade[8] = {                      // darker edge of each cell
    C_BLACK,
    RGB(20, 120, 140),  RGB(150, 120, 20),  RGB(100, 40, 140), RGB(30, 120, 50),
    RGB(140, 30, 30),   RGB(30, 60, 140),   RGB(150, 80, 20),
};

static uint8_t  well[H][W];                             // 0 empty, 1..7 a piece's colour
static int      cur, rot, px, py, nxt;                  // current piece, rotation, position, next
static int      ghost_y;
static uint32_t score, lines, level;
static int      over, paused;
static uint8_t  bag[7];
static int      bag_n;
static uint32_t rng;

static uint32_t rnd(void)                               // xorshift
{
    rng ^= rng << 13;  rng ^= rng >> 17;  rng ^= rng << 5;
    return rng;
}

static int next_piece(void)                             // 7-bag: each piece once per 7
{
    if (bag_n == 0) {
        for (int i = 0; i < 7; i++) bag[i] = (uint8_t)i;
        for (int i = 6; i > 0; i--) {
            int j = (int)(rnd() % (uint32_t)(i + 1));
            uint8_t t = bag[i]; bag[i] = bag[j]; bag[j] = t;
        }
        bag_n = 7;
    }
    return bag[--bag_n];
}

static int cell_of(int p, int r, int i)                 // cell i (0..15) of piece p, rotation r
{
    return (shapes[p][r] >> (15 - i)) & 1;
}

static int fits(int p, int r, int x, int y)
{
    for (int i = 0; i < 16; i++) {
        if (!cell_of(p, r, i)) continue;
        int cx = x + (i & 3), cy = y + (i >> 2);
        if (cx < 0 || cx >= W || cy >= H) return 0;
        if (cy >= 0 && well[cy][cx]) return 0;
    }
    return 1;
}

// ---------------------------------------------------------------- drawing
static void draw_cell(int x, int y, int c)              // c: 0 empty, 1..7 piece, 8 ghost
{
    int sx = WX + x * CELL, sy = WY + y * CELL;
    if (c == 0) { tft_fill(sx, sy, CELL - 1, CELL - 1, C_BLACK); return; }
    if (c == 8) {                                       // ghost: a dim outline
        tft_fill(sx, sy, CELL - 1, CELL - 1, RGB(70, 70, 80));
        tft_fill(sx + 1, sy + 1, CELL - 3, CELL - 3, C_BLACK);
        return;
    }
    tft_fill(sx, sy, CELL - 1, CELL - 1, shade[c]);
    tft_fill(sx + 1, sy + 1, CELL - 4, CELL - 4, colour[c]);
}

static void draw_piece(int p, int r, int x, int y, int c)
{
    for (int i = 0; i < 16; i++)
        if (cell_of(p, r, i) && y + (i >> 2) >= 0) draw_cell(x + (i & 3), y + (i >> 2), c);
}

// the whole well: clear it (cells and the 1-pixel gaps between them), then the filled cells
static void draw_well(void)
{
    tft_fill(WX, WY, W * CELL, H * CELL, C_BLACK);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            if (well[y][x]) draw_cell(x, y, well[y][x]);
}

static void draw_next(void)
{
    tft_fill(SX + 6, 58, 4 * CELL, 3 * CELL, C_BLACK);
    for (int i = 0; i < 16; i++)
        if (cell_of(nxt, 0, i)) {
            int sx = SX + 6 + (i & 3) * CELL, sy = 58 + (i >> 2) * CELL;
            tft_fill(sx, sy, CELL - 1, CELL - 1, shade[nxt + 1]);
            tft_fill(sx + 1, sy + 1, CELL - 4, CELL - 4, colour[nxt + 1]);
        }
}

static uint32_t to_bcd(uint32_t v)
{
    uint32_t b = 0;
    for (int s = 0; s < 16; s += 4) { b |= (v % 10) << s; v /= 10; }
    return b;
}

static void draw_stats(void)
{
    tft_text(SX, 112, "SCORE", 1, C_GREY, C_BLACK);
    int x = tft_num(SX, 126, score, 1, C_WHITE, C_BLACK);
    tft_fill(x, 126, 236 - x, 12, C_BLACK);
    tft_text(SX, 150, "LINES", 1, C_GREY, C_BLACK);
    x = tft_num(SX, 164, lines, 1, C_WHITE, C_BLACK);
    tft_fill(x, 164, 236 - x, 12, C_BLACK);
    tft_text(SX, 188, "LEVEL", 1, C_GREY, C_BLACK);
    x = tft_num(SX, 202, level, 1, C_WHITE, C_BLACK);
    tft_fill(x, 202, 236 - x, 12, C_BLACK);
    IO_HEX = to_bcd(score > 9999 ? 9999 : score);
}

static void show_piece(void)                            // ghost first, the piece over it
{
    ghost_y = py;
    while (fits(cur, rot, px, ghost_y + 1)) ghost_y++;
    if (ghost_y != py) draw_piece(cur, rot, px, ghost_y, 8);
    draw_piece(cur, rot, px, py, cur + 1);
}

static void hide_piece(void)
{
    draw_piece(cur, rot, px, ghost_y, 0);
    draw_piece(cur, rot, px, py, 0);
}

// ---------------------------------------------------------------- game
static void new_game(void)
{
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) well[y][x] = 0;
    score = lines = level = 0;
    over = paused = 0;
    bag_n = 0;
    tft_fill(0, 0, TFT_W, TFT_H, C_BLACK);
    tft_fill(0, 0, TFT_W, 20, C_BLUE);
    tft_text(4, 4, "TETRIS on my RISC-V", 1, C_WHITE, C_BLUE);
    tft_fill(WX - 2, WY - 2, W * CELL + 3, H * CELL + 3, C_GREY);   // frame
    tft_fill(WX - 1, WY - 1, W * CELL + 1, H * CELL + 1, C_BLACK);
    tft_text(SX, 40, "NEXT", 1, C_GREY, C_BLACK);
    tft_text(SX, 236, "L/R move", 1, C_GREY, C_BLACK);
    tft_text(SX, 250, "U rotate", 1, C_GREY, C_BLACK);
    tft_text(SX, 264, "D faster", 1, C_GREY, C_BLACK);
    tft_text(SX, 278, "C restart", 1, C_GREY, C_BLACK);
    tft_text(SX, 296, "keys: arrows", 1, C_GREY, C_BLACK);
    tft_text(SX, 308, "space drops", 1, C_GREY, C_BLACK);
    draw_well();
    nxt = next_piece();
    draw_stats();
    print_str("tetris: new game\n");
}

// a new piece at the top; game over if it does not fit
static void spawn(void)
{
    cur = nxt;  nxt = next_piece();  rot = 0;  px = 3;  py = (cur == 0) ? -1 : 0;
    draw_next();
    if (!fits(cur, rot, px, py)) {
        over = 1;
        draw_piece(cur, rot, px, py, cur + 1);
        tft_fill(WX + 4, WY + 96, W * CELL - 8, 44, C_DARK);
        tft_text(WX + 24, WY + 102, "GAME OVER", 1, C_RED, C_DARK);
        tft_text(WX + 16, WY + 120, "press a key", 1, C_WHITE, C_DARK);
        print_str("tetris: game over, score "); print_dec((int32_t)score); print_str("\n");
        return;
    }
    show_piece();
}

static uint32_t gravity_ms(void)
{
    uint32_t g = 800u - level * 70u;
    return (level >= 10) ? 80u : g;
}

// fix the piece in the well, clear full rows, score
static void lock_piece(void)
{
    for (int i = 0; i < 16; i++)
        if (cell_of(cur, rot, i) && py + (i >> 2) >= 0)
            well[py + (i >> 2)][px + (i & 3)] = (uint8_t)(cur + 1);
    int full[4], n = 0;
    for (int y = 0; y < H; y++) {
        int k = 0;
        for (int x = 0; x < W; x++) k += well[y][x] != 0;
        if (k == W && n < 4) full[n++] = y;
    }
    if (n) {
        for (int i = 0; i < n; i++)                     // flash the full rows (the cells only)
            for (int x = 0; x < W; x++)
                tft_fill(WX + x * CELL, WY + full[i] * CELL, CELL - 1, CELL - 1, C_WHITE);
        uint32_t t0 = now();
        while (now() - t0 < 120u * MS) ;
        for (int i = 0; i < n; i++)                     // remove them, top to bottom
            for (int y = full[i]; y > 0; y--)
                for (int x = 0; x < W; x++) well[y][x] = well[y - 1][x];
        for (int x = 0; x < W; x++) well[0][x] = 0;
        static const uint32_t pts[5] = {0, 40, 100, 300, 1200};
        score += pts[n] * (level + 1);
        lines += (uint32_t)n;
        level = lines / 10;
        draw_well();
        draw_stats();
    }
    spawn();
}

static int try_move(int dx, int dy, int dr)
{
    int r = (rot + dr) & 3;
    static const int kicks[5] = {0, -1, 1, -2, 2};
    for (int k = 0; k < (dr ? 5 : 1); k++) {
        if (fits(cur, r, px + dx + kicks[k], py + dy)) {
            hide_piece();
            px += dx + kicks[k];  py += dy;  rot = r;
            show_piece();
            return 1;
        }
    }
    return 0;
}

static void hard_drop(void)
{
    hide_piece();
    int d = 0;
    while (fits(cur, rot, px, py + 1)) { py++; d++; }
    score += 2u * (uint32_t)d;
    draw_piece(cur, rot, px, py, cur + 1);
    lock_piece();
    draw_stats();
}

// ---------------------------------------------------------------- the mouse (optional)
#define PS2_RX     (*(volatile uint32_t *)0x40000000)
#define PS2_TX     (*(volatile uint32_t *)0x40000004)
#define PS2_STATUS (*(volatile uint32_t *)0x40000008)
static int m_ok, m_n, m_btn, m_acc;
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
    m_n = m_btn = m_acc = 0;
    print_str(m_ok ? "tetris: mouse found\n" : "tetris: no mouse (buttons and keys work)\n");
}

// ---------------------------------------------------------------- main loop
int main(void)
{
    tft_init(0);
    rng = now() | 1u;
    mouse_init();
    new_game();
    spawn();

    uint32_t last_fall = now(), last_btn = 0, held_since = 0;
    uint32_t prev = IO_BUTTONS & 0xFu;
    for (;;) {
        // the board buttons: bit 0 up, 1 left, 2 right, 3 down
        uint32_t b = IO_BUTTONS & 0xFu, t = now();
        uint32_t pressed = b & ~prev;
        rng ^= t;                                        // the player's timing seeds the bag
        if (over) {
            int c = getchar_nb();
            if (pressed || c == 'r' || c == ' ') { new_game(); spawn(); last_fall = now(); }
            prev = b;
            continue;
        }
        int dx = 0, dr = 0, drop = 0, soft = 0;
        if (pressed & 1u) dr = 1;
        if (pressed & 2u) { dx = -1; held_since = t; }
        if (pressed & 4u) { dx = 1;  held_since = t; }
        // a held left / right repeats after 170 ms, every 50 ms
        if ((b & 6u) && !(pressed & 6u) && t - held_since > 170u * MS && t - last_btn > 50u * MS)
            dx = (b & 2u) ? -1 : 1;
        if (b & 8u) soft = 1;
        prev = b;

        // the laptop keyboard (through load.py)
        int c = getchar_nb();
        if (c == 'a') dx = -1;
        if (c == 'd') dx = 1;
        if (c == 'w') dr = 1;
        if (c == 's') { if (!try_move(0, 1, 0)) lock_piece(); else score++; last_fall = t; }
        if (c == ' ') drop = 1;
        if (c == 'p') {
            paused = !paused;
            tft_text(SX, 222, paused ? "PAUSED" : "      ", 1, C_YELLOW, C_BLACK);
        }
        if (c == 'r') { new_game(); spawn(); last_fall = now(); continue; }
        if (paused) continue;

        // the mouse: about 30 counts of sideways movement = one column
        int pk;
        while (m_ok && (pk = ps2_get(0)) >= 0) {
            if (m_n == 0 && !(pk & 8)) continue;
            m_pk[m_n++] = (uint8_t)pk;
            if (m_n < 3) continue;
            m_n = 0;
            m_acc += m_pk[1] - ((m_pk[0] & 0x10) ? 256 : 0);
            int mb = m_pk[0] & 3;
            if ((mb & 1) && !(m_btn & 1)) dr = 1;
            if ((mb & 2) && !(m_btn & 2)) drop = 1;
            m_btn = mb;
        }
        if (m_acc > 30)  { dx = 1;  m_acc -= 30; }
        if (m_acc < -30) { dx = -1; m_acc += 30; }

        if (dx) { try_move(dx, 0, 0); last_btn = t; }
        if (dr) try_move(0, 0, 1);
        if (drop) { hard_drop(); last_fall = now(); continue; }

        // gravity (faster while btnD is held)
        uint32_t g = soft ? 40u : gravity_ms();
        if (now() - last_fall > g * MS) {
            last_fall = now();
            if (try_move(0, 1, 0)) { if (soft) score++; }
            else { lock_piece(); draw_stats(); }
        }
    }
}
