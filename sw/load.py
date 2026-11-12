# load.py - send a compiled program to the Basys 3 over USB, then show what it prints
#
#   python sw/load.py COM5 hello            (Windows; on Linux the port is /dev/ttyUSB1)
#   python sw/load.py COM5 sw/build/bench
#
# A program name is looked up in sw/build/ (your own builds) and then sw/prebuilt/ (hello,
# bench and demo, ready to use without a RISC-V compiler). Needs: pip install pyserial
# The packet format is described in code/io/uart_loader.v. Press Ctrl+C to quit.
#
# --dump FILE writes the packet to a text file instead of sending it (used by the
# testbench verif/tb_basys3.v to check the loader in simulation).

import argparse
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def read_words(path):
    with open(path) as f:
        return [int(line, 16) for line in f if line.strip()]


def trim(words):
    """drop trailing zero words: memory starts at 0 anyway, so they need not be sent"""
    while words and words[-1] == 0:
        words.pop()
    return words


def load_image(build_dir):
    imem = trim(read_words(os.path.join(build_dir, 'imem.hex')))
    lanes = [read_words(os.path.join(build_dir, 'dmem%d.hex' % i)) for i in range(4)]
    dmem = [lanes[0][i] | lanes[1][i] << 8 | lanes[2][i] << 16 | lanes[3][i] << 24
            for i in range(len(lanes[0]))]
    return imem, trim(dmem)


def make_packet(imem, dmem):
    words = imem + dmem
    check = sum(words) & 0xFFFFFFFF
    return (b'RVLD' + struct.pack('<HH', len(imem), len(dmem))
            + b''.join(struct.pack('<I', w) for w in words)
            + struct.pack('<I', check))


def main():
    ap = argparse.ArgumentParser(description='Load a program onto the RV32IM CPU over UART')
    ap.add_argument('port', nargs='?', help='serial port, e.g. COM5 or /dev/ttyUSB1')
    ap.add_argument('program', help='program name (sw/build/<name>) or a build folder')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--dump', help='write the packet to this file instead of sending it')
    args = ap.parse_args()

    # a folder path, or a program name: your own build first, then the prebuilt copy
    build_dir = args.program
    for candidate in (os.path.join(HERE, 'build', args.program),
                      os.path.join(HERE, 'prebuilt', args.program)):
        if not os.path.isdir(build_dir):
            build_dir = candidate
    if not os.path.isfile(os.path.join(build_dir, 'imem.hex')):
        sys.exit('no imem.hex in %s - build it first: make PROG=%s' % (build_dir, args.program))

    imem, dmem = load_image(build_dir)
    packet = make_packet(imem, dmem)
    print('%s: %d code words, %d data words, %d bytes (%.1f s at %d baud)'
          % (args.program, len(imem), len(dmem), len(packet),
             len(packet) * 10 / args.baud, args.baud))

    if args.dump:
        with open(args.dump, 'w') as f:
            f.write('\n'.join('%02x' % b for b in packet) + '\n')
        print('packet written to', args.dump)
        return

    if not args.port:
        sys.exit('give the serial port, e.g. COM5')
    try:
        import serial
    except ImportError:
        sys.exit('pyserial is missing: pip install pyserial')

    with serial.Serial(args.port, args.baud, timeout=0.1) as port:
        port.reset_input_buffer()
        port.write(packet)
        port.flush()

        # wait for the loader's answer: 'K' = loaded and running, 'E' = checksum error
        deadline = time.time() + 3 + len(packet) * 10 / args.baud
        reply = b''
        while not reply and time.time() < deadline:
            reply = port.read(1)
        if reply == b'K':
            print('loaded, program running (Ctrl+C to quit)\n')
        elif reply == b'E':
            sys.exit('checksum error: the program was damaged on the way, try again')
        else:
            sys.exit('no answer from the board: check the port, the bitstream, and press btnC')

        try:
            while True:
                data = port.read(256)
                if data:
                    sys.stdout.write(data.decode('ascii', errors='replace').replace('\r', ''))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            print()


if __name__ == '__main__':
    main()
