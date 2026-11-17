# demo_tool.py - the laptop side of the live demo (sw/programs/nn_demo)
#
#   python sw/demo_tool.py COM6
#
# Loads the demo program onto the board, then opens a window:
#   - draw a digit with the mouse; 0.8 s after you let go it is sent to the board, which recognises
#     it with the CPU alone and with the accelerator and shows both times on the TFT
#   - "Send picture..." sends any photo (made grey and 96x96) for the edge-filter mode
# The board's messages appear at the bottom of the window.
# Needs: pip install pyserial pillow   (tkinter comes with Python on Windows)

import argparse
import os
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import load                                                    # sw/load.py

try:
    import serial
    from PIL import Image, ImageDraw, ImageOps
except ImportError:
    sys.exit('missing packages: pip install pyserial pillow')

ACK = b'\x06'
CANVAS = 280                                                   # drawing area, 10x the MNIST size


def mnist_style(img):
    """280x280 drawing (white on black) -> 784 bytes the way MNIST digits look: the ink fitted
    into a 20x20 box, then centred by its centre of mass in a 28x28 image"""
    box = img.getbbox()
    if not box:
        return None
    digit = img.crop(box)
    w, h = digit.size
    s = 20.0 / max(w, h)
    digit = digit.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    out = Image.new('L', (28, 28), 0)
    px = digit.load()
    tot = sx = sy = 0
    for y in range(digit.size[1]):
        for x in range(digit.size[0]):
            v = px[x, y]; tot += v; sx += v * x; sy += v * y
    cx, cy = (sx / tot, sy / tot) if tot else (digit.size[0] / 2, digit.size[1] / 2)
    out.paste(digit, (round(14 - cx), round(14 - cy)))
    return bytes(out.getdata())


def no_loader_magic(data):
    """the board's program loader listens for the bytes 'RVLD' at all times: make sure a
    picture never contains them (change one byte by 1, invisible on the screen)"""
    b = bytearray(data)
    i = b.find(b'RVLD')
    while i >= 0:
        b[i + 3] ^= 1
        i = b.find(b'RVLD')
    return bytes(b)


class Board:
    def __init__(self, port, on_text):
        self.port = serial.Serial(port, 115200, timeout=0.05, write_timeout=5)
        self.on_text = on_text
        self.acked = threading.Event()
        self.lock = threading.Lock()
        threading.Thread(target=self.reader, daemon=True).start()

    def reader(self):
        line = b''
        while True:
            b = self.port.read(1)
            if not b:
                continue
            if b == ACK:
                self.acked.set()
            elif b == b'\n':
                self.on_text(line.decode('ascii', 'replace'))
                line = b''
            else:
                line += b

    def send(self, cmd, payload):
        with self.lock:
            self.acked.clear()
            self.port.write(cmd)
            if not self.acked.wait(3.0):                       # the board answers between frames
                self.on_text('no answer from the board (is nn_demo running?)')
                return
            self.port.write(no_loader_magic(payload))


def main():
    ap = argparse.ArgumentParser(description='Live demo: draw digits, send pictures')
    ap.add_argument('port', help='serial port, e.g. COM6')
    ap.add_argument('--no-load', action='store_true', help='nn_demo is already running')
    args = ap.parse_args()

    if not args.no_load:                                       # load the demo program first
        build = None
        for d in (os.path.join(HERE, 'build', 'nn_demo'), os.path.join(HERE, 'prebuilt', 'nn_demo')):
            if os.path.isfile(os.path.join(d, 'imem.hex')):
                build = d
                break
        if not build:
            sys.exit('nn_demo is not built: make PROG=nn_demo (or use sw/prebuilt)')
        imem, dmem = load.load_image(build)
        packet = load.make_packet(imem, dmem)
        with serial.Serial(args.port, 115200, timeout=0.1, write_timeout=5) as p:
            p.reset_input_buffer()
            print('loading nn_demo (%d bytes)...' % len(packet), flush=True)
            p.write(packet)
            deadline = time.time() + 3 + len(packet) * 10 / 115200
            reply = b''
            while reply != b'K' and time.time() < deadline:
                reply = p.read(1)
                if reply == b'E':
                    sys.exit('checksum error while loading, try again')
            if reply != b'K':
                sys.exit('no answer from the board: check the port and the bitstream')
        print('loaded')

    root = tk.Tk()
    root.title('RISC-V + accelerator: live demo')
    status = tk.StringVar(value='Draw a digit (big, in the middle). It is sent 0.8 s after you let go.')

    def show(text):
        root.after(0, status.set, text)

    board = Board(args.port, show)

    canvas = tk.Canvas(root, width=CANVAS, height=CANVAS, bg='black', cursor='pencil')
    canvas.grid(row=0, column=0, columnspan=3, padx=8, pady=8)
    ink = Image.new('L', (CANVAS, CANVAS), 0)
    pen = ImageDraw.Draw(ink)
    last = [None]
    R = 11                                                     # pen radius

    pending = [None]
    sent = [False]

    def stroke(e):
        if pending[0]:                                         # still drawing: do not send yet
            root.after_cancel(pending[0])
            pending[0] = None
        if sent[0] and not last[0]:                            # a new digit: start on a clean canvas
            clear()
            sent[0] = False
        if last[0]:
            canvas.create_line(*last[0], e.x, e.y, fill='white', width=2 * R, capstyle=tk.ROUND)
            pen.line([last[0], (e.x, e.y)], fill=255, width=2 * R)
        pen.ellipse([e.x - R, e.y - R, e.x + R, e.y + R], fill=255)
        canvas.create_oval(e.x - R, e.y - R, e.x + R, e.y + R, fill='white', outline='white')
        last[0] = (e.x, e.y)

    def send_digit():
        pending[0] = None
        data = mnist_style(ink)
        if data:
            sent[0] = True
            status.set('sending...')
            threading.Thread(target=board.send, args=(b'D', data), daemon=True).start()

    def release(_):
        last[0] = None
        pending[0] = root.after(800, send_digit)               # 0.8 s: room for a second stroke

    def clear():
        canvas.delete('all')
        pen.rectangle([0, 0, CANVAS, CANVAS], fill=0)

    def picture():
        path = filedialog.askopenfilename(filetypes=[('Pictures', '*.png *.jpg *.jpeg *.bmp'), ('All', '*.*')])
        if not path:
            return
        img = ImageOps.fit(Image.open(path).convert('L'), (96, 96), Image.LANCZOS)
        status.set('sending the picture (about 1 s)...')
        threading.Thread(target=board.send, args=(b'P', bytes(img.getdata())), daemon=True).start()

    canvas.bind('<B1-Motion>', stroke)
    canvas.bind('<Button-1>', stroke)
    canvas.bind('<ButtonRelease-1>', release)
    tk.Button(root, text='Clear', width=12, command=clear).grid(row=1, column=0, pady=4)
    tk.Button(root, text='Send picture...', width=14, command=picture).grid(row=1, column=1)
    tk.Button(root, text='Quit', width=8, command=root.destroy).grid(row=1, column=2)
    tk.Label(root, textvariable=status, wraplength=300, justify='left').grid(
        row=2, column=0, columnspan=3, padx=8, pady=8, sticky='w')
    root.mainloop()


if __name__ == '__main__':
    main()
