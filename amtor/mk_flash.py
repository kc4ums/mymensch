"""Make amtor_flash.bin: a 128 KB image for the W65C134SXB's flash socket.

The SXB maps 32 KB of its 128 KB flash at $8000-$FFFF, with flash A15 and
A16 driven by P34 (FA15) and P35 (FAMS). Which 32 KB bank is visible after
reset depends on how Port 3 comes out of reset (the datasheet's register
table and its text disagree), so the program is written into all four
banks: whichever one is selected, $8000 holds 'WDC' and the ROM monitor
jumps to $8004 at power-up. Unused bytes are $FF (erased flash).

    python mk_flash.py        (reads amtor_rom.s19)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools', 'emu'))
from emu_mymensch import load_s19   # noqa: E402


def main():
    bank = bytearray(b'\xFF' * 0x8000)
    for addr, data in load_s19(os.path.join(HERE, 'amtor_rom.s19')):
        if not (0x8000 <= addr and addr + len(data) <= 0xF000):
            sys.exit('code at %04X is outside the flash window $8000-$EFFF' % addr)
        bank[addr - 0x8000:addr - 0x8000 + len(data)] = data
    if bank[:3] != b'WDC':
        sys.exit("no 'WDC' signature at $8000")
    out = os.path.join(HERE, 'amtor_flash.bin')
    with open(out, 'wb') as f:
        f.write(bytes(bank) * 4)
    print('wrote %s (4 x 32 KB banks, %d bytes of code each)'
          % (out, len(bank.rstrip(b'\xFF'))))


if __name__ == '__main__':
    main()
