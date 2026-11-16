"""Run dbgdemo.s19 (the dbg.inc helpers) on the emulator and check the
output and that A, X, Y and the flags survive each call.

    python test_dbgdemo.py [-v]
"""
import os
import sys

from emu_mymensch import Board, load_s19

HERE = os.path.dirname(os.path.abspath(__file__))
S19 = os.path.join(HERE, '..', 'probe', 'dbgdemo.s19')


def main():
    b = Board(load_s19(S19), tx_period=320)
    for a in range(0x7FB0, 0x7FC8):
        b.cpu.io_rd[a] = lambda a: a & 0xFF       # recognisable I/O values
    b.keys = list(b'D\x1b')
    reason = b.run(max_steps=20_000_000)
    out = b.cpu.out.replace(b'\x00', b'').decode('latin-1')
    if '-v' in sys.argv:
        print(out)
    want = ['A=5A X=03 Y=C4 S=FF P=', 'P=B5 Nv-BdIzC', '@8042 ',
            '7FB0: B0 B1 B2 B3 B4 B5 B6 B7 B8 B9 BA BB BC BD BE BF',
            '7FC0: C0 C1 C2 C3 C4 C5 C6 C7',
            'ADC_CTRL=B4 SEQD=B3 ACIA_A_STAT=', 'DATA=-- ']
    missing = [w for w in want if w not in out]
    regs = bytes(b.cpu.mem[0x0300:0x0306])
    ok = reason == 'RESET' and not missing and regs == bytes([0x5A, 3, 0xC4] * 2)
    ok &= out.count('@') == 4                     # 2 runs x 2 dbg_regs
    print('dbg   exit %s, saved regs %s, %s' % (reason, regs.hex(' '),
          'OK' if ok else 'MISSING %r' % missing))
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
