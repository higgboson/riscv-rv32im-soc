# ascon_demo.py - the PC side of the Basys 3 Ascon demo, for showing it to anyone
#
#   python sw/ascon_demo.py COM5            board already running the demo (built into the bitstream)
#   python sw/ascon_demo.py COM5 --load     send the demo program first (any bitstream of this SoC)
#
# Each answer the board gives is recomputed here with sw/ascon_ref.py, written separately
# from the hardware and tested on the official NIST vectors, and the two are compared on screen.
# Everything shown is also saved to ascon_demo_session.txt.  Needs: pip install pyserial

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'verif'))
import ascon_ref            # noqa: E402
import check_ascon_demo     # noqa: E402

if os.name == 'nt':
    os.system('')           # lets the Windows terminal show colours
GREEN, RED, CYAN, BOLD, END = '\033[92m', '\033[91m', '\033[96m', '\033[1m', '\033[0m'

log = open('ascon_demo_session.txt', 'a', encoding='utf-8')


def show(text=''):
    print(text)
    for code in (GREEN, RED, CYAN, BOLD, END):
        text = text.replace(code, '')
    log.write(text + '\n')
    log.flush()


def read_until_ready(port, timeout=10):
    """everything the board prints up to its READY prompt"""
    buf, end = b'', time.time() + timeout
    while time.time() < end:
        buf += port.read(256)
        if b'READY' in buf:
            buf += port.read(8)
            break
    return buf.decode('ascii', errors='replace').replace('\r', '')


def send(port, line):
    port.reset_input_buffer()
    port.write(line.encode('ascii') + b'\r')
    text = read_until_ready(port)
    # the board echoes the command; show only its answer
    body = text.split('\n', 1)[1] if '\n' in text else text
    body = body.replace('READY', '').replace('> ', '').strip('\n')
    for row in body.split('\n'):
        colour = GREEN if 'PASS' in row else RED if 'FAIL' in row else ''
        show('   ' + colour + row + (END if colour else ''))
    return text


def verify(text):
    blocks = check_ascon_demo.parse(text)
    if not blocks:
        show(RED + '   (no answer from the board)' + END)
        return None
    return blocks[-1]


def verdict(ok, what):
    if ok:
        show(GREEN + BOLD + '   >>> MATCHES OFFICIAL ASCON, computed independently on this PC: '
             + what + END)
    else:
        show(RED + BOLD + '   >>> DOES NOT MATCH THE REFERENCE: ' + what + END)


state = {}


def lock(port, msg):
    b = verify(send(port, 'e ' + msg))
    if not b or b['kind'] != 'lock':
        return
    key, nonce = bytes.fromhex(b['key'].replace(' ', '')), bytes.fromhex(b['nonce'].replace(' ', ''))
    ct, tag = ascon_ref.aead_encrypt(key, nonce, b'', msg.encode())
    state.update(key=key, nonce=nonce, msg=msg.encode(), ct=ct, tag=tag)
    verdict(ct.hex(' ') == b['ciphertext'] and tag.hex(' ') == b['seal (tag)'],
            'same ciphertext and same seal')


def unlock(port, tamper):
    b = verify(send(port, 't' if tamper else 'd'))
    if not b or 'result' not in b:
        return
    received = bytes.fromhex(b['received'].replace(' ', ''))
    ref = ascon_ref.aead_decrypt(state['key'], state['nonce'], b'', received, state['tag'])
    board_pass = b['result'].startswith('PASS')
    verdict(board_pass == (ref is not None), 'the reference also says ' + ('PASS' if ref else 'FAIL'))


def fingerprint(port, msg):
    b = verify(send(port, 'h ' + msg))
    if not b or b['kind'] != 'hash':
        return None
    md = ascon_ref.hash256(msg.encode())
    verdict(md.hex(' ') == b['hash'], 'same 256-bit fingerprint')
    return md


def avalanche(port, msg):
    flip = ord(msg[-1]) ^ 1
    other = msg[:-1] + chr(flip if 32 <= flip < 127 else ord(msg[-1]) ^ 2)
    show(CYAN + '\n   Fingerprints of "%s" and "%s" (one letter, one bit apart):' % (msg, other) + END)
    a, b = fingerprint(port, msg), fingerprint(port, other)
    if a and b:
        diff = sum(bin(x ^ y).count('1') for x, y in zip(a, b))
        show(CYAN + BOLD + '   %d of 256 fingerprint bits changed (about half is ideal: '
             'no way to guess one from the other)' % diff + END)


MENU = '''
  1  Lock (encrypt) a message
  2  Unlock (decrypt) it
  3  Tamper with it on the way, then try to unlock
  4  Fingerprint (hash) a message
  5  Change one letter, compare fingerprints
  6  Watch the board (use its buttons), Ctrl+C to come back
  q  Quit'''


def ask_message(prompt, allow_empty=False):
    while True:
        m = input(prompt)
        if not all(32 <= ord(ch) < 127 for ch in m):
            print('   plain English letters, digits and punctuation only, please')
        elif len(m) > 200:
            print('   at most 200 characters')
        elif 'RVLD' in m:
            print('   "RVLD" is the board\'s program-loading signal, choose other text')
        elif m or allow_empty:
            return m


def main():
    ap = argparse.ArgumentParser(description='Ascon demo on the Basys 3')
    ap.add_argument('port', help='serial port, e.g. COM5 or /dev/ttyUSB1')
    ap.add_argument('--load', action='store_true', help='send the demo program first')
    args = ap.parse_args()
    try:
        import serial
    except ImportError:
        sys.exit('pyserial is missing: pip install pyserial')

    if args.load:
        import load
        build = os.path.join(HERE, 'build', 'ascon_demo')
        if not os.path.isfile(os.path.join(build, 'imem.hex')):
            build = os.path.join(HERE, 'prebuilt', 'ascon_demo')
        packet = load.make_packet(*load.load_image(build))

    with serial.Serial(args.port, 115200, timeout=0.2, write_timeout=5) as port:
        if args.load:
            port.reset_input_buffer()
            port.write(packet)
            reply = port.read(1)
            end = time.time() + 5
            while not reply and time.time() < end:
                reply = port.read(1)
            if reply != b'K':
                sys.exit('the board did not accept the program: check the port and press btnC')
            read_until_ready(port)
        else:
            send(port, '')          # wakes the prompt and checks the board is there

        show(BOLD + '\n Ascon hardware (NIST SP 800-232) on a RISC-V SoC, Basys 3 FPGA' + END)
        show(' Session ' + time.strftime('%Y-%m-%d %H:%M'))
        while True:
            print(MENU)
            choice = input('\n  choose: ').strip().lower()
            show('\n[%s]' % choice)
            if choice == '1':
                lock(port, ask_message('   message to lock: '))
            elif choice in ('2', '3'):
                if 'tag' not in state:
                    print('   lock a message first (1)')
                else:
                    unlock(port, choice == '3')
            elif choice == '4':
                fingerprint(port, ask_message('   message to fingerprint: ', allow_empty=True))
            elif choice == '5':
                avalanche(port, ask_message('   a word or sentence: '))
            elif choice == '6':
                print('   press btnL / btnU / btnD / btnR on the board (Ctrl+C to stop)')
                try:
                    while True:
                        data = port.read(256)
                        if data:
                            sys.stdout.write(data.decode('ascii', errors='replace').replace('\r', ''))
                            sys.stdout.flush()
                except KeyboardInterrupt:
                    print()
                    state.clear()   # a button lock used the board's own message
            elif choice == 'q':
                break


if __name__ == '__main__':
    main()
