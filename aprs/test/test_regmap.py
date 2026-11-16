"""Run regmap.s19 on two emulated boards: one with working VIA_A, multipliers
and ADC (VIA_B/C plain RAM, so their timers don't count), and one where those
blocks read 00 and ignore writes.

    python test_regmap.py [-v]
"""
import os
import sys

from emu_mymensch import Board, load_s19
from test_probe import ProbeBoard, VIA

HERE = os.path.dirname(os.path.abspath(__file__))
S19 = os.path.join(HERE, '..', 'probe', 'regmap.s19')


class LiveBoard(ProbeBoard):
    def __init__(self, image):
        super().__init__(image)
        self.acr = 0
        self.cpu.io_rd[VIA + 6] = lambda a: self.t1_latch & 0xFF
        self.cpu.io_rd[VIA + 11] = lambda a: self.acr
        self.cpu.io_wr[VIA + 11] = self._acr_wr

    def _acr_wr(self, a, v):
        self.acr = v


class DeadBoard(Board):
    def __init__(self, image):
        super().__init__(image, tx_period=320)
        for a in list(range(0x7F20, 0x7F50)) + list(range(0x7FB0, 0x7FE0)):
            self.cpu.io_rd[a] = lambda a: 0
            self.cpu.io_wr[a] = lambda a, v: None


def run(board, want, label):
    board.keys = list(b'D\x1b')
    reason = board.run(max_steps=20_000_000)
    out = board.cpu.out.replace(b'\x00', b'').decode('latin-1')
    if '-v' in sys.argv:
        print(out)
    missing = [w for w in want if w not in out]
    runs = out.count('register map probe')
    ok = reason == 'RESET' and not missing and runs == 2
    print('%-5s exit %s, runs %d, %s' % (label, reason, runs,
                                          'OK' if ok else 'MISSING %r' % missing))
    return ok


def main():
    img = load_s19(S19)
    ok = run(LiveBoard(img), [
        '7F60: --',
        'VIA_A  latch 5A->5A A5->A5  ACR 40->40', 'counting  IFR 00',
        'VIA_B  latch 5A->5A A5->A5  ACR 40->40', 'STOPPED',
        'unsigned: 2C 01 90 01 C0 D4 01 00',
        'signed:   FD FF D2 04 8A F1 FF FF',
        'end-of-packet OK', 'Chip ID valid', 'loop count (hex): 0',
        'D = run again'], 'live')
    ok &= run(DeadBoard(img), [
        'VIA_A  latch 5A->00 A5->00  ACR 40->00  T1 0000 0000 STOPPED  IFR 00',
        'VIA_C  latch 5A->00',
        'unsigned: 00 00 00 00 00 00 00 00',
        'NO END-OF-PACKET'], 'dead')
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
