# Ascon demo on the Basys 3: lock, unlock, tamper, fingerprint

Your RISC-V CPU runs a C program (`sw/programs/ascon_demo`) that uses the Ascon hardware
(`code/ascon/`, at `0x3000_0000`) to encrypt, decrypt and hash what you type. The PC
recomputes every answer with an independent Python model (`sw/ascon_ref.py`, which passes all
1,089 official AEAD and 1,025 official hash test vectors) and shows whether the two agree.

The whole demo has been simulated with typed commands and button presses
(`sh verif/run_ascon_demo.sh`): 3 locks, 3 unlocks, 2 tamper refusals and 4 fingerprints, all
matching the reference.

## What you need

Same as [`basys3_guide.md`](basys3_guide.md): the board, Vivado, Python 3 with
`pip install pyserial`. No RISC-V compiler: the program is already built in
`sw/prebuilt/ascon_demo/`.

## 1. Build the bitstream with the Ascon demo inside (about 5-10 minutes)

From the repository root, in a terminal where Vivado works:

```
vivado -mode batch -source fpga/basys3/build.tcl -tclargs 50 sw/prebuilt/ascon_demo
```

Check the last lines it prints:

- `worst setup slack` must be **zero or positive**. If it is negative, build at a slower clock
  (`-tclargs 40 ...`) and tell me the number; the program's timing text assumes 50 MHz.
- Open `fpga/basys3/build/utilization.rpt`: Slice LUTs should be around 5,000 to 6,500 of 20,800
  (the CPU alone was 1,939; the Ascon peripheral adds roughly 3,800).

Keep `timing.rpt`, `utilization.rpt` and `utilization_hier.rpt`: they are proof that it fits and
meets timing. Save a copy before rebuilding anything.

## 2. Program the board

```
vivado -mode batch -source fpga/basys3/program.tcl
```

The 7-segment display shows `A5C0` when the demo is running.

## 3a. Demo with the PC (recommended)

Close PuTTY if it is open, then:

```
python sw/ascon_demo.py COM5
```

(use your COM port; if the board runs another program, add `--load` to send the demo first)

| Menu | What happens | What the audience sees |
|---|---|---|
| 1 Lock | the FPGA encrypts your message | unreadable bytes and a 16-byte seal; display shows the seal's first digits |
| 2 Unlock | the FPGA decrypts it | your message comes back, `PASS`, display `600d`, all LEDs on |
| 3 Tamper | one bit of the locked message is changed, then unlock | `FAIL`, nothing released, display `0bAd`, LEDs blink |
| 4 Fingerprint | Ascon-Hash256 of a message | a 256-bit fingerprint |
| 5 One letter | fingerprints of e.g. `hello` and `hellp` | about half of the 256 bits change |

After each answer a green line says **MATCHES OFFICIAL ASCON, computed independently on this
PC**. Everything is also written to `ascon_demo_session.txt` in the folder you ran it from.

What to say, in plain words:

1. "I type a secret. The chip I designed scrambles it, and adds a seal."
2. "Only someone with the key can unscramble it." (Unlock: PASS)
3. "Now someone changes one tiny bit on the way." (Tamper: FAIL) "The chip notices and refuses
   to release anything at all. It doesn't just hide the message, it detects tampering."
4. "A fingerprint: change one letter and the whole fingerprint changes."
5. "And my laptop checks each answer with its own separate copy of the standard. They agree."

## 3b. Demo with no PC: the buttons

| Button | Action |
|---|---|
| btnL | lock the built-in message `HELLO FROM THE BASYS 3` (display: seal digits, 8 LEDs) |
| btnU | unlock it (display `600d`, all LEDs) |
| btnD | tamper, then unlock (display `0bAd`, LEDs blink) |
| btnR | fingerprint of the built-in message |
| btnC | reset |

With PuTTY open (115200 8N1) you also see the full output of each button press, and you can
type the commands yourself: `e <text>`, `d`, `t`, `h <text>`.

## 4. Proof to keep (for the ascon-hw README)

1. A 30-60 second phone video: type a message, lock, unlock (`600d`), tamper (`0bAd`, blinking),
   with the laptop screen and the board both in view.
2. Photos of the board showing `600d` and `0bAd`.
3. `ascon_demo_session.txt` from that run.
4. `timing.rpt` and `utilization.rpt` (or screenshots of their summary lines).

Send them to me and I'll add them to the ascon-hw repo's front page.

## Notes

- The key is fixed (`00 01 ... 0f`) and printed, so the PC can check the answers. A real device
  would keep its key secret.
- The nonce changes for every message (message counter + cycle counter), because reusing a nonce
  with the same key breaks AEAD.
- Do not type the text `RVLD`: it is the signal that starts the program loader, which resets the CPU.
- The `hardware` time printed is the cycles the CPU spent in the driver calls, measured with the
  SoC's cycle counter. Most of it is the CPU moving data over the bus, not the Ascon core itself.
