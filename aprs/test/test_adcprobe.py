"""Run adcprobe.s19 on two emulated boards: one with a strobe-driven model of
the Intel Modular ADC (sequencer CSR + sample store with IER/ISR), and one
where $7FB0-$7FBF reads 00 and ignores writes.

    python test_adcprobe.py [-v]
"""
import os
import sys

from emu_mymensch import Board, load_s19

HERE = os.path.dirname(os.path.abspath(__file__))
S19 = os.path.join(HERE, '..', 'probe', 'adcprobe.s19')
ADC = 0x7FB0
TEMP = 0x0E56


class AdcBoard(Board):
    def __init__(self, image, steps=40):
        super().__init__(image, tx_period=320)
        self.reg = [0] * 4                # SAMD0, SAMD1, SAMADDR, SEQD
        self.ctrl = 0
        self.csr = 0                      # sequencer CSR
        self.store = [0] * 0x42
        self.store[0x40] = 0              # IER off at reset: the probe sets it
        self.left = None
        self.steps = steps
        for i in range(4):
            self.cpu.io_rd[ADC + i] = lambda a: self.reg[a - ADC]
            self.cpu.io_wr[ADC + i] = self._reg_wr
        self.cpu.io_rd[ADC + 4] = lambda a: self.ctrl | (0x80 if self._irq() else 0)
        self.cpu.io_wr[ADC + 4] = self._ctrl_wr

    def _irq(self):
        return self.store[0x41] & self.store[0x40] & 1

    def _reg_wr(self, a, v):
        self.reg[a - ADC] = v & (0x7F if a - ADC >= 2 else 0xFF)

    def _store_wr(self):
        addr = self.reg[2]
        val = self.reg[0] | (self.reg[1] << 8)
        if addr == 0x41:
            self.store[0x41] &= ~val      # write 1 to clear
        elif addr < 0x42:
            self.store[addr] = val

    def _seq_wr(self):
        self.csr = self.reg[3]
        self.left = self.steps if self.csr & 1 else None

    def _ctrl_wr(self, a, v):
        rise = v & ~self.ctrl
        self.ctrl = v & 0x7F
        if rise & 0x10:
            self._store_wr()
        if rise & 0x20 and self.reg[2] < 0x42:
            w = self.store[self.reg[2]]
            self.reg[0], self.reg[1] = w & 0xFF, w >> 8
        if rise & 0x02:
            self._seq_wr()
        if rise & 0x04:
            self.reg[3] = self.csr
        if rise & 0x01:
            self._store_wr()
            self._seq_wr()

    def _hw(self):
        super()._hw()
        if self.left is not None:
            self.left -= 1
            if self.left <= 0:
                for n in range(10):
                    self.store[n] = TEMP if n == 8 else 0x100 * n
                self.store[0x41] |= 1
                self.left = self.steps if (self.csr & 0x0F) == 1 else None
                if (self.csr & 0x0F) == 3:
                    self.csr &= ~1


class DeadBoard(Board):
    def __init__(self, image):
        super().__init__(image, tx_period=320)
        for a in range(ADC, ADC + 16):
            self.cpu.io_rd[a] = lambda a: 0
            self.cpu.io_wr[a] = lambda a, v: None


def run(board, want, label):
    board.keys = list(b'D\x1b')
    reason = board.run(max_steps=30_000_000)
    out = board.cpu.out.replace(b'\x00', b'').decode('latin-1')
    if '-v' in sys.argv:
        print(out)
    missing = [w for w in want if w not in out]
    runs = out.count('MyMENSCH ADC probe')
    ok = reason == 'RESET' and not missing and runs == 2
    print('%-5s exit %s, runs %d, %s' % (label, reason, runs,
                                          'OK' if ok else 'MISSING %r' % missing))
    return ok


def main():
    img = load_s19(S19)
    ok = run(AdcBoard(img), [
        '+0 5A->5A 25->25', '+2 5A->5A 25->25',
        'IER($40)=0000  ISR($41)=0000',
        'IER($40)=0001  ISR($41)=0000',
        '00->00 03->03  CTRL=80 EOP OK  ISR($41)=0001',
        'stop: 00->00',
        '5. autorun single:  CTRL=81 EOP OK',
        'autorun continuous:  CTRL=81 EOP OK',
        'SAMP_RD: 0000 0100 0200 0300 0400 0500 0600 0700 0E56 0900'], 'live')
    ok &= run(DeadBoard(img), [
        '+0 5A->00 25->00', 'NO EOP', 'direct:  0000 0000'], 'dead')
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
