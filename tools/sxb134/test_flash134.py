"""Run flash134.s19 on the 65C02 core against a model of the SXB's flash.

The model is an SST39SF010A (128 KB, 4 KB sectors) wired as on the SXB:
CPU $8000-$EFFF = chip A0-A14, chip A15/A16 = P34/P35 (PD3 bits 4/5).
It follows the datasheet's command sequences (chip addresses A14-A0
$5555/$2AAA, A16-A15 don't care), toggles DQ6 while busy, and fails a
command that breaks the sequence. Checks: erase + program into bank 3,
other banks untouched, $FF bytes skipped, the bank lines restored, bad
parameters refused, and a stuck (write-protected) chip reported.

    python test_flash134.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'emu'))
from emu_mymensch import CPU, Halt, load_s19, M, XF, I   # noqa: E402

P = 0x7003          # parameter block


class SST:
    def __init__(self, bench, writable=True):
        self.b = bench
        self.mem = bytearray(b'\xFF' * 0x20000)
        self.seq = []
        self.busy = 0
        self.tog = 0
        self.writable = writable
        self.programs = 0
        self.erases = []
        self.bad = []

    def ca(self, a):
        return (((self.b.pd3 >> 4) & 3) << 15) | (a & 0x7FFF)

    def rd(self, a):
        if self.busy:
            self.busy -= 1
            self.tog ^= 0x40
            return self.tog
        return self.mem[self.ca(a)]

    def wr(self, a, v):
        if not self.writable:
            return
        ca = self.ca(a)
        lo = ca & 0x7FFF
        s = self.seq
        if s == ['A0']:
            self.mem[ca] &= v
            self.programs += 1
            self.busy = 3
            self.seq = []
            return
        if s == ['80', 'AA', '55'] and v == 0x30:
            base = ca & ~0xFFF
            self.mem[base:base + 0x1000] = b'\xFF' * 0x1000
            self.erases.append(base)
            self.busy = 200
            self.seq = []
            return
        step = {(0x5555, 0xAA): 'AA', (0x2AAA, 0x55): '55', (0x5555, 0xA0): 'A0',
                (0x5555, 0x80): '80'}.get((lo, v))
        if step == 'AA' and (not s or s == ['80']):
            self.seq = s + ['AA'] if s == ['80'] else ['AA_']
        elif step == '55' and s and s[-1] in ('AA', 'AA_'):
            self.seq = s[:-1] + (['AA', '55'] if s[-1] == 'AA' else ['55_'])
        elif step in ('A0', '80') and s == ['55_']:
            self.seq = [step]
        else:
            self.bad.append((hex(ca), hex(v), list(s)))
            self.seq = []


class Bench:
    def __init__(self, writable=True):
        self.cpu = cpu = CPU()
        for a, d in load_s19(os.path.join(HERE, 'flash134.s19')):
            cpu.mem[a:a + len(d)] = d
        self.pd3 = 0xFF
        self.chip = SST(self, writable)
        for a in range(0x8000, 0xF000):
            cpu.io_rd[a] = self.chip.rd
            cpu.io_wr[a] = self.chip.wr
        cpu.io_rd[3] = lambda a: self.pd3
        cpu.io_wr[3] = lambda a, v: setattr(self, 'pd3', v)

        def outch(c):
            c.out.append(c.a)
            c.pc = (c.pull16() + 1) & 0xFFFF
        cpu.hooks[0xF00F] = outch

        def back(c):
            raise Halt('rts')
        cpu.hooks[0xF218] = back

    def run(self, op, bank, dst, src, length, data=None):
        cpu, m = self.cpu, self.cpu.mem
        if data is not None:
            m[src:src + len(data)] = data
        m[P] = op
        m[P + 1] = bank
        m[P + 2:P + 4] = dst.to_bytes(2, 'little')
        m[P + 4:P + 6] = src.to_bytes(2, 'little')
        m[P + 6:P + 8] = length.to_bytes(2, 'little')
        m[P + 8] = 0xEE
        cpu.out = bytearray()
        cpu.e = 1
        cpu.p = M | XF | I
        cpu.s = 0x1FF
        cpu.push16(0xF217)                   # J: returns to the monitor's START
        cpu.pc = 0x7000
        try:
            for _ in range(5_000_000):
                cpu.step()
            return 'hung', cpu.out
        except Halt:
            return m[P + 8], cpu.out.decode('latin-1').strip()


ok = True


def check(cond, msg):
    global ok
    print(('  ok   ' if cond else '  FAIL ') + msg)
    ok &= bool(cond)


def main():
    b = Bench()
    chip = b.chip
    chip.mem[0x00000:0x00004] = b'BNK0'
    chip.mem[0x18000:0x18004] = b'OLD!'                 # something there already
    chip.mem[0x19000] = 0x12                            # next sector: must survive
    data = bytearray(b'WDC\x00' + bytes(range(256)) * 15 + b'\xFF' * 252)
    data[100] = 0xFF
    st, out = b.run(3, 3, 0x8000, 0x1000, 0x1000, data)
    check(st == 0 and out == 'FLASH OK', 'erase + program 4 KB into bank 3: %r' % out)
    check(chip.mem[0x18000:0x19000] == data, 'bank 3 $8000-$8FFF holds the data')
    check(chip.erases == [0x18000], 'one sector erased: %s' % [hex(e) for e in chip.erases])
    check(chip.programs == sum(1 for x in data if x != 0xFF), '$FF bytes skipped (%d programmed)' % chip.programs)
    check(chip.mem[0:4] == b'BNK0' and chip.mem[0x19000] == 0x12, 'other banks and sectors untouched')
    check(b.pd3 & 0x30 == 0x30, 'bank lines back to 1 (PD3 = %02X)' % b.pd3)
    check(not chip.bad, 'every command sequence well formed %s' % chip.bad[:2])

    st, out = b.run(3, 3, 0xE000, 0x1000, 0x1000, data)
    check(st == 0, 'last sector below the ROM, $E000-$EFFF')
    st, out = b.run(3, 3, 0xE800, 0x1000, 0x1000, data)
    check(st == 1, 'refuses to run into $F000: %r' % out)
    st, out = b.run(3, 3, 0x7000, 0x1000, 0x100, data)
    check(st == 1, 'refuses an address below $8000')
    st, out = b.run(2, 3, 0x8000, 0x1000, 0x100, bytes([0xAA]) * 0x100)
    check(st == 4 and out.startswith('FLASH ERR 04'), 'program-only over old data (bits cannot go back to 1): verify catches it: %r' % out)
    st, out = b.run(1, 3, 0x8000, 0x1000, 0, None)
    check(st == 0 and chip.mem[0x18000:0x19000] == b'\xFF' * 0x1000, 'erase only (removes the WDC signature)')

    stuck = Bench(writable=False)
    stuck.chip.mem[0x18000] = 0x55
    st, out = stuck.run(3, 3, 0x8000, 0x1000, 0x10, b'\x00' * 16)
    check(st in (2, 3, 4), 'a chip that ignores writes is reported: %r' % out)
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
