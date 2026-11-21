# Architecture figures

`docs/images/arch/soc_architecture.png` (Figure 1) and `accelerator_architecture.png` (Figure 2)
are drawn by these scripts on an HTML canvas: `lib.js` holds the drawing helpers (blocks,
registers, multiplexers, buses with their widths, connector tags), `fig_soc.js` and
`fig_accel.js` the figures. Every name, register offset, width and number in them comes from
the RTL in `code/` or from measurements on the board.

To redraw after a design change (needs Python, Playwright and Chrome):

```
python render.py fig_soc.js   ../images/arch/soc_architecture.png
python render.py fig_accel.js ../images/arch/accelerator_architecture.png
```
