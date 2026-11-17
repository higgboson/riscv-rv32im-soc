// tft.h - driver for the 2.4" 240x320 SPI TFT through code/io/tft_spi.v (RGB565)
#ifndef TFT_DRIVER_H
#define TFT_DRIVER_H

#include <stdint.h>

#define TFT_CTRL   (*(volatile uint32_t *)0x30000000)
#define TFT_STATUS (*(volatile uint32_t *)0x30000004)
#define TFT_CMD    (*(volatile uint32_t *)0x30000008)
#define TFT_DATA   (*(volatile uint32_t *)0x3000000C)
#define TFT_PIX    (*(volatile uint32_t *)0x30000010)
#define TFT_PIX2   (*(volatile uint32_t *)0x30000014)
#define TFT_FILL   (*(volatile uint32_t *)0x30000018)

#define TFT_W 240
#define TFT_H 320

#define RGB(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))
#define C_BLACK  RGB(0, 0, 0)
#define C_WHITE  RGB(255, 255, 255)
#define C_GREY   RGB(120, 120, 120)
#define C_DARK   RGB(24, 28, 36)
#define C_BLUE   RGB(42, 120, 214)
#define C_ORANGE RGB(235, 104, 52)
#define C_GREEN  RGB(27, 175, 122)
#define C_RED    RGB(220, 50, 50)
#define C_YELLOW RGB(240, 200, 60)

// wait until the controller can take another write (it holds one while sending the last)
static inline void tft_wait(void) { while (TFT_STATUS & 1u) ; }
static inline void tft_idle(void) { while (TFT_STATUS & 2u) ; }
static inline void tft_cmd(uint8_t c)  { tft_wait(); TFT_CMD = c; }
static inline void tft_data(uint8_t d) { tft_wait(); TFT_DATA = d; }
static inline void tft_pix(uint16_t c) { tft_wait(); TFT_PIX = c; }
static inline void tft_pix2(uint16_t first, uint16_t second)
{
    tft_wait(); TFT_PIX2 = (uint32_t)first | (uint32_t)second << 16;
}
static inline uint16_t tft_grey(int v)     // v = 0..127
{
    int g = v << 1;
    return RGB(g, g, g);
}

void tft_init(int fast);                   // reset and set up the panel (fast: 25 MHz clock)
void tft_window(int x, int y, int w, int h);
void tft_fill(int x, int y, int w, int h, uint16_t colour);
// a grey image (values 0..127), each pixel drawn as a scale x scale block; stride in bytes
void tft_image(int x, int y, const int8_t *img, int w, int h, int stride, int scale);
void tft_char(int x, int y, char ch, int scale, uint16_t fg, uint16_t bg);
int  tft_text(int x, int y, const char *s, int scale, uint16_t fg, uint16_t bg);   // returns the end x
int  tft_num(int x, int y, uint32_t v, int scale, uint16_t fg, uint16_t bg);
// v / 10^dec with dec decimals, e.g. tft_fixed(.., 754, 2) prints 7.54
int  tft_fixed(int x, int y, uint32_t v, int dec, int scale, uint16_t fg, uint16_t bg);

#endif
