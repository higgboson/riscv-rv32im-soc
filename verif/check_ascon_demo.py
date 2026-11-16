# check_ascon_demo.py - checks every result the Ascon demo printed against the Python
# reference (sw/ascon_ref.py, tested on the official NIST vectors).
#
#   python3 verif/check_ascon_demo.py demo_sim.log
#
# Works on a simulation log or on text captured from the real board. For each LOCKED block
# it recomputes ciphertext and seal; for each UNLOCK block it checks that PASS / FAIL is what
# the reference says and that the released message is the original; for each FINGERPRINT
# block it recomputes the hash.

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sw'))
import ascon_ref  # noqa: E402


def parse(text):
    """blocks of {'kind': ..., field: value} in the order printed"""
    blocks, cur = [], None
    for raw in text.splitlines():
        line = raw.strip()
        for head, kind in (('LOCKED', 'lock'), ('UNLOCKING', 'unlock'),
                           ('TAMPERED', 'tamper'), ('FINGERPRINT', 'hash')):
            if line.startswith(head):
                cur = {'kind': kind}
                blocks.append(cur)
        if cur is not None and ':' in line and not line.startswith(('LOCKED', 'TAMPERED')):
            name, _, value = line.partition(':')
            cur[name.strip()] = value.strip()
    return blocks


def hexbytes(s):
    return bytes.fromhex(s.replace(' ', ''))


def text_field(s):
    # the program prints messages in double quotes
    return s[1:-1].encode() if s.startswith('"') and s.endswith('"') else s.encode()


def check(blocks):
    errors, done = 0, {'lock': 0, 'unlock': 0, 'tamper': 0, 'hash': 0}
    last = None
    for b in blocks:
        kind = b['kind']
        try:
            if kind == 'lock':
                key, nonce = hexbytes(b['key']), hexbytes(b['nonce'])
                msg = text_field(b['message'])
                ct, tag = ascon_ref.aead_encrypt(key, nonce, b'', msg)
                ok = ct == hexbytes(b['ciphertext']) and tag == hexbytes(b['seal (tag)'])
                last = (key, nonce, msg, ct, tag)
                what = 'lock   %-40r ciphertext + seal' % msg.decode()
            elif kind in ('unlock', 'tamper'):
                key, nonce, msg, ct, tag = last
                received = hexbytes(b['received'])
                ref = ascon_ref.aead_decrypt(key, nonce, b'', received, tag)
                board_pass = b['result'].startswith('PASS')
                ok = board_pass == (ref is not None)
                if board_pass:
                    ok &= text_field(b['message']) == ref == msg
                ok &= (kind == 'tamper') == (received != ct)
                what = '%-6s -> board %s, reference %s' % (
                    kind, 'PASS' if board_pass else 'FAIL', 'PASS' if ref is not None else 'FAIL')
            else:
                msg = text_field(b['message'])
                ok = ascon_ref.hash256(msg) == hexbytes(b['hash'])
                what = 'hash   %-40r' % msg.decode()
        except (KeyError, ValueError, TypeError) as e:
            ok, what = False, '%s block incomplete (%s)' % (kind, e)
        done[kind] += 1
        errors += not ok
        print('  %s  %s' % ('MATCH  ' if ok else 'WRONG  ', what))
    return errors, done


if __name__ == '__main__':
    blocks = parse(open(sys.argv[1], errors='replace').read())
    errors, done = check(blocks)
    print('\n%d locks, %d unlocks, %d tampered, %d fingerprints: %s'
          % (done['lock'], done['unlock'], done['tamper'], done['hash'],
             'ALL MATCH THE REFERENCE' if not errors and blocks else '%d WRONG' % errors))
    sys.exit(1 if errors or not blocks or not done['tamper'] else 0)
