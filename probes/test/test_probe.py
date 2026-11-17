"""Run probe.s19 on the emulator with simple VIA Timer 1, multiplier and ADC
models, to check the probe's arithmetic and control flow before using it on
the board.

    python test_probe.py [-v]
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools', 'emu'))
from emu_mymensch import Board, load_s19

S19 = os.path.join(HERE, '..', 'probe.s19')

CPS = 4                 # emulated cycles per instruction
VIA, MUL, ADC = 0x7F20, 0x7FD0, 0x7FB0


class ProbeBoard(Board):
    def __init__(self, image, adc_steps=40):
        super().__init__(image, tx_period=320)    # 1280 cycles per char = 115200 baud
        cpu = self.cpu
        self.t1 = 0xFFFF
        self.t1_latch = 0xFFFF
        self.ifr = 0
        self.mul = bytearray(16)
        self.seq = 0
        self.eop = False
        self.adc_left = None
        self.adc_steps = adc_steps
        self.addr = 0
        self.slots = [2048 + 100 * n for n in range(10)]
        self.rng = random.Random(1)
        cpu.io_rd[VIA + 4] = self._t1cl
        cpu.io_rd[VIA + 5] = lambda a: self.t1 >> 8
        cpu.io_rd[VIA + 13] = lambda a: self.ifr | (0x80 if self.ifr else 0)
        for off in (4, 5, 6, 7, 11, 14):
            cpu.io_wr[VIA + off] = self._via_wr
        for off in range(16):
            cpu.io_wr[MUL + off] = self._mul_wr
            cpu.io_rd[MUL + off] = self._mul_rd
        cpu.io_wr[ADC + 0] = lambda a, v: None
        cpu.io_wr[ADC + 2] = self._addr_wr
        cpu.io_wr[ADC + 3] = self._seq_wr
        cpu.io_wr[ADC + 4] = self._ctrl_wr
        cpu.io_rd[ADC + 4] = lambda a: 0x80 if self.eop else 0
        cpu.io_rd[ADC + 0] = lambda a: self._sample() & 0xFF
        cpu.io_rd[ADC + 1] = lambda a: self._sample() >> 8
        self.cur_sample = 0

    # VIA
    def _t1cl(self, a):
        self.ifr &= ~0x40
        return self.t1 & 0xFF

    def _via_wr(self, a, v):
        off = a - VIA
        if off == 6:
            self.t1_latch = (self.t1_latch & 0xFF00) | v
        elif off == 7:
            self.t1_latch = (self.t1_latch & 0xFF) | (v << 8)
        elif off == 5:
            self.t1_latch = (self.t1_latch & 0xFF) | (v << 8)
            self.t1 = self.t1_latch
            self.ifr &= ~0x40

    # multiplier
    def _mul_wr(self, a, v):
        self.mul[a - MUL] = v

    def _mul_rd(self, a):
        off = a - MUL
        base = 8 if off >= 8 else 0
        x = self.mul[base] | (self.mul[base + 1] << 8)
        y = self.mul[base + 2] | (self.mul[base + 3] << 8)
        if base:
            x = x - 0x10000 if x & 0x8000 else x
            y = y - 0x10000 if y & 0x8000 else y
        r = (x * y) & 0xFFFFFFFF
        k = off - base
        return (r >> (8 * (k - 4))) & 0xFF if k >= 4 else self.mul[off]

    # ADC
    def _addr_wr(self, a, v):
        self.addr = v
        if v < 10:
            self.cur_sample = self.slots[v] + self.rng.randint(-5, 5)

    def _sample(self):
        return self.cur_sample

    def _seq_wr(self, a, v):
        self.seq = v

    def _ctrl_wr(self, a, v):
        if v & 0x01:
            self.adc_left = self.adc_steps if self.seq & 0x01 else None
        if v & 0x10 and self.addr == 0x41:
            self.eop = False
            if self.seq == 0x01:
                self.adc_left = self.adc_steps

    def _hw(self):
        super()._hw()
        self.t1 -= CPS
        if self.t1 < 0:
            self.t1 += self.t1_latch + 2
            self.ifr |= 0x40
        if self.adc_left is not None:
            self.adc_left -= 1
            if self.adc_left <= 0:
                self.eop = True
                self.adc_left = None


def main():
    b = ProbeBoard(load_s19(S19))
    b.keys = list(b'A\x1b')
    reason = b.run(max_steps=20_000_000)
    out = b.cpu.out.replace(b'\x00', b'').decode('latin-1')
    if '-v' in sys.argv:
        print(out)
    want = ['PHI2:   147', '0001D4C0', 'FFFFF18A', 'cycles each', 'sequences in',
            '9   ', 'A = scan ADC again']
    ok = reason == 'RESET' and all(w in out for w in want)
    # PHI2 within 0.5% of 14745600
    hz = int(out.split('PHI2:')[1].split()[0])
    ok &= abs(hz - 14745600) < 74000
    # slot 3 average near 2348
    row = [ln for ln in out.splitlines() if ln.strip().startswith('3 ')][0].split()
    ok &= abs(int(row[4]) - 2348) <= 5
    print('PHI2 measured %d Hz, slot 3 row %s, exit %s' % (hz, row, reason))
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
