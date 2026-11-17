"""Drive mmon.s19 on the MyMENSCH emulator: type commands, paste an S19
file at real 115200-baud speed, hit a BRK, resume, and exit.

    python test_mmon.py [-v]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools', 'emu'))
import emu_mymensch  # noqa: E402
from emu_mymensch import Board, load_s19  # noqa: E402

S19 = os.path.join(HERE, 'mmon.s19')
CHAR = 320              # emulator steps per character at 115200 baud
BRK_STUB = 0xFF00


def op_brk(cpu, mode):
    # real 65C02 BRK (the shared emulator just halts): skip the signature
    # byte, push PC and P with B set, clear D, vector through $FFFE
    cpu.push16((cpu.pc + 1) & 0xFFFF)
    cpu.push(cpu.p | 0x10)
    cpu.p = (cpu.p | emu_mymensch.I) & ~emu_mymensch.D
    cpu.pc = cpu.rd16(0xFFFE)


emu_mymensch.OPS[0x00] = (op_brk, None)


def srec(addr, data, kind='1', bad=False):
    body = bytes([len(data) + 3, addr >> 8, addr & 0xFF]) + bytes(data)
    chk = (~sum(body) & 0xFF) ^ (1 if bad else 0)
    return 'S%s%s%02X\r\n' % (kind, body.hex().upper(), chk)


class MonBoard(Board):
    """Console that types a line after each prompt and pastes at line rate."""

    def __init__(self, image, script):
        super().__init__(image, tx_period=CHAR)
        m = self.cpu.mem
        m[0xFFFE:0x10000] = BRK_STUB.to_bytes(2, 'little')
        m[BRK_STUB:BRK_STUB + 3] = bytes([0x4C, 0x06, 0x80])   # jmp $8006
        self.script = list(script)
        self.stream = bytearray()
        self.paced = False
        self.timer = 0
        self.rxd = None
        self.rx_over = 0
        self.mark = 0

    def _a_stat_rd(self, a):
        if not self.stream and self.rxd is None and self.script:
            wait, text, paced = self.script[0]
            out = self.cpu.out
            if len(out) > self.mark and bytes(out).endswith(wait.encode()):
                self.script.pop(0)
                self.stream = bytearray(text.encode())
                self.paced = paced
                self.timer = CHAR
        if not self.paced and self.rxd is None and self.stream:
            self.rxd = self.stream.pop(0)
            self.mark = len(self.cpu.out)
        tdre = 0x10 if self.tx_hold is None else 0
        return tdre | (0x08 if self.rxd is not None else 0)

    def _a_data_rd(self, a):
        v, self.rxd = self.rxd, None
        return v or 0

    def _hw(self):
        super()._hw()
        if self.paced and self.stream:
            self.timer -= 1
            if self.timer <= 0:
                self.timer = CHAR
                if self.rxd is not None:
                    self.rx_over += 1
                self.rxd = self.stream.pop(0)
                self.mark = len(self.cpu.out)


def main():
    prog = [0xA9, 0x99, 0x60]                   # $0500: lda #$99 / rts
    s19 = ('S00600004844521B\r\n' + srec(0x0500, prog) +
           srec(0x0600, range(32)) +
           srec(0x8100, [0xEA]) +               # monitor memory: refused
           srec(0x0700, [1, 2, 3], bad=True) +  # bad checksum
           srec(0x0500, [], kind='9'))
    P = '\r\n>'
    script = [
        (P, '?\r', False),
        (P, 'e 300 A9 42 A2 07 00 00 A0 09 60\r', False),
        (P, 'G 300\r', False),                  # stops at the BRK
        (P, 'g\r', False),                      # resumes after it
        (P, 'D 300 30A\r', False),
        (P, 'F 400 40F 5A\r', False),
        (P, 'D 3FE 411\r', False),
        (P, 'F 7000 8000 00\r', False),
        (P, 'R 11 22 33 04\r', False),
        (P, 'L\r', False),
        ('(ESC aborts)\r\n', s19, True),
        (P, 'G\r', False),
        (P, 'D 600 61F\r', False),
        (P, 'I\r', False),
        (P, 'Q\r', False),
        (P, 'X\r', False),
    ]
    b = MonBoard(load_s19(S19), script)
    reason = b.run(max_steps=40_000_000)
    out = b.cpu.out.decode('latin-1')
    if '-v' in sys.argv:
        print(out)
    want = [
        'MMON 1.0 for MyMENSCH Rev-C',
        'G [addr]            call; RTS returns here',
        '0300: A9 42 A2 07 00 00 A0 09 60',
        'BRK at 0304\r\n A=42 X=07',
        'calling 0306\r\nreturned:\r\n A=42 X=07 Y=09',
        '03FE: 00 00 5A 5A 5A 5A 5A 5A 5A 5A 5A 5A 5A 5A 5A 5A',
        '040E: 5A 5A 00 00',
        'refused: $8000-$8FFF is the monitor',
        ' A=11 X=22 Y=33 S=FF P=04 nv-bdIzc',
        '...E',
        '0003 records, 0001 bad, 0001 bytes refused, 0000 bytes not written. G = 0500',
        'calling 0500\r\nreturned:\r\n A=99',
        '0600: 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  ................',
        '0610: 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F',
        '7F60: -- ',
        '>Q\r\n?\r\n',
        'restarting',
    ]
    missing = [w for w in want if w not in out]
    ok = reason == 'RESET' and not missing and not b.script and b.rx_over == 0
    ok &= b.cpu.mem[0x8100] != 0xEA        # refused record not written
    print('mmon  exit %s, overruns %d, script left %d, %s' % (
        reason, b.rx_over, len(b.script), 'OK' if ok else 'MISSING %r' % missing))
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
