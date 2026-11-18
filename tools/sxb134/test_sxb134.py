"""Test sxb134.py against a model of the W65C134 ROM monitor's serial side.

The model follows WDC's ROM listing (134iromlist.pdf, MON3.ASM):
  - the prompt is CR LF '.', and command characters are echoed;
  - 'S' starts a record: echo goes off, the record is read and stored as
    it arrives, the checksum is checked (bad: BEL, CR LF "E aaaa  nn"),
    then one more character (the CR) is read and the prompt follows;
  - 'E' prints CR LF "E aaaa  nn" and clears the count;
  - 'W' types a space, reads 4 hex digits, a space, 4 hex digits, waits
    for one more character, then sends S1 records of 16 bytes and an S9;
  - 'G'/'J' type a space, read 4 hex digits and start the program.
A line-noise option corrupts one character in some records, to check that
the uploader notices the monitor's error report and resends.

    python test_sxb134.py
"""
import os
import random
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sxb134  # noqa: E402


class FakeMonitor:
    def __init__(self, noise_every=0, silent=False, eol='\r\n'):
        self.eol = eol
        self.mem = bytearray(65536)
        self.out = bytearray()
        self.inp = bytearray()
        self.errs = 0
        self.lastaddr = 0
        self.noise_every = noise_every
        self.records = 0
        self.started = None
        self.silent = silent
        self.chip = bytearray(b'\xFF' * 0x20000)
        self.flash_ops = []
        self.state = self._cmd()
        next(self.state)

    # serial-port interface used by sxb134.Monitor
    def write(self, data):
        for b in data:
            if self.silent:
                continue
            self.state.send(b)

    def read(self, n=1):
        out, self.out = bytes(self.out[:n]), self.out[n:]
        return out

    def reset_input_buffer(self):
        self.out = bytearray()

    # the monitor
    def _say(self, s):
        b = s.encode('latin-1') if isinstance(s, str) else s
        self.out += b.replace(b'\r\n', self.eol.encode())

    def _cmd(self):
        while True:
            self._say('\r\n.')
            c = yield
            ch = chr(c)
            if ch == 'S':
                self._say('S')
                line = ''
                while True:
                    c = yield
                    if c == 13:
                        break
                    line += chr(c)
                self.records += 1
                if self.noise_every and self.records % self.noise_every == 0:
                    i = random.randrange(4, len(line))
                    line = line[:i] + ('0' if line[i] != '0' else '1') + line[i + 1:]
                self._load(line)
            elif ch == 'E':
                self._say('E')
                self._say('\r\nE %04X  %02X' % (self.lastaddr, self.errs))
                self.errs = 0
            elif ch == 'W':
                self._say('W ')
                a = yield from self._hex4()
                self._say(' ')
                e = yield from self._hex4()
                yield                                   # the final CR
                self._say('\r\n')
                for s in range(a, e + 1, 16):
                    n = min(16, e + 1 - s)
                    raw = bytes([n + 3, s >> 8, s & 0xFF]) + bytes(self.mem[s:s + n])
                    self._say('\r\nS1' + raw.hex().upper() + '%02X' % (~sum(raw) & 0xFF))
                self._say('\r\nS9030000FC')
            elif ch in 'GJ':
                self._say(ch + ' ')
                a = yield from self._hex4()
                if ch == 'J' and a == 0x7000 and self.mem[0x7000] == 0x4C:
                    self._flasher()                    # flash134 runs and returns
                    continue
                self.started = (ch, a)
                while True:                             # the program owns the port now
                    yield
            elif c == 13:
                pass
            else:
                self._say(ch + '?')

    def _flasher(self):
        """What flash134.s19 does, on a flash chip whose bank 3 is visible at $8000."""
        m = self.mem
        op, bank = m[0x7003], m[0x7004]
        dst = m[0x7005] | m[0x7006] << 8
        src = m[0x7007] | m[0x7008] << 8
        n = m[0x7009] | m[0x700A] << 8
        self.flash_ops.append((op, bank, dst, n))
        if op & 4:
            m[src:src + n] = b'\xFF' * n
            st = 0
        else:
            base = bank * 0x8000 + (dst & 0x7FFF)
            if op & 1:
                sb = base & ~0xFFF
                self.chip[sb:sb + 0x1000] = b'\xFF' * 0x1000
            if op & 2:
                for i in range(n):
                    self.chip[base + i] &= m[src + i]
            st = 0 if all(self.chip[base + i] == m[src + i] for i in range(n)) else 4
        m[0x700B] = st
        if bank == 3:                                  # the bank the monitor shows
            m[0x8000:0xF000] = self.chip[0x18000:0x1F000]
        self._say('\r\nFLASH OK' if st == 0 else '\r\nFLASH ERR %02X0000' % st)

    def _hex4(self):
        s = ''
        for _ in range(4):
            c = yield
            s += chr(c)
            self._say(chr(c))
        return int(s, 16)

    def _load(self, line):
        try:
            typ = line[0]
            raw = bytes.fromhex(line[1:])
            alen = 2 if typ in '19' else 3
            a = int.from_bytes(raw[1:1 + alen], 'big') & 0xFFFF
            data = raw[1 + alen:-1]
            for i, b in enumerate(data):                 # stored as it arrives
                self.mem[(a + i) & 0xFFFF] = b
            ok = (sum(raw) & 0xFF) == 0xFF
        except ValueError:
            ok, a = False, self.lastaddr
        if not ok:
            self.errs += 1
            self.lastaddr = a
            self._say(bytes([7]) + b'\r\nE %04X  %02X' % (a, self.errs))


ok = True


def check(cond, msg):
    global ok
    print(('  ok   ' if cond else '  FAIL ') + msg)
    ok &= bool(cond)


def main():
    random.seed(7)
    repo = os.path.join(HERE, '..', '..')
    image = os.path.join(repo, 'amtor', 'amtor_ram.s19')
    if not os.path.exists(image):
        image = os.path.join(repo, 'tnc134', 'tnc134.s19')
    mem = sxb134.read_image(image)
    print('image %s: %d bytes $%04X-$%04X' % (os.path.relpath(image, repo), len(mem), min(mem), max(mem)))

    # file formats agree with each other
    hexf = os.path.join(repo, 'tnc134', 'tnc134.hex')
    s19f = os.path.join(repo, 'tnc134', 'tnc134.s19')
    s28f = os.path.join(repo, 'tnc134', 'tnc134.s28')
    if os.path.exists(hexf):
        a, b, c = (sxb134.read_image(f) for f in (hexf, s19f, s28f))
        check(a == b == c, 'Intel HEX, S19 and S28 of tnc134 read the same (%d bytes)' % len(a))
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'x.bin')
        open(p, 'wb').write(bytes(range(256)) * 3)
        m = sxb134.read_image(p, 0x4000)
        check(m[0x4000] == 0 and m[0x42FF] == 255 and len(m) == 768, '.bin with --addr')

    # clean link
    fake = FakeMonitor()
    mon = sxb134.Monitor(fake)
    mon.sync()
    retried = mon.upload(mem)
    check(all(fake.mem[a] == v for a, v in mem.items()), 'all %d bytes arrive in RAM' % len(mem))
    check(retried == 0, 'no records resent on a clean link')
    check(mon.verify(mem) == [], 'verify by reading back with W')
    mon.run(0x2000)
    check(fake.started == ('G', 0x2000), 'G2000 starts the program (%s)' % (fake.started,))

    # noisy link: every 7th record arrives with one character changed
    fake = FakeMonitor(noise_every=7)
    mon = sxb134.Monitor(fake)
    mon.sync()
    retried = mon.upload(mem)
    check(retried > 0, 'corrupted records noticed and resent (%d)' % retried)
    check(all(fake.mem[a] == v for a, v in mem.items()), 'memory still correct after resends')
    check(mon.verify(mem) == [], 'verify passes')

    # verify catches a byte the load didn't put there
    a0 = min(mem)
    fake.mem[a0 + 5] ^= 0xFF
    bad = mon.verify(mem)
    check(bad == [a0 + 5], 'verify finds a changed byte at $%04X' % (a0 + 5))

    # the real SXB ROM ends lines with CR only (seen on the board: 'E\rE 005A  00\r.')
    fake = FakeMonitor(eol='\r')
    mon = sxb134.Monitor(fake)
    mon.sync()
    check(mon.errors() == (0, 0), 'CR-only prompt: E reply understood')
    mon.upload(mem)
    check(mon.verify(mem) == [], 'CR-only prompt: load and verify')

    # JSR form
    fake = FakeMonitor()
    mon = sxb134.Monitor(fake)
    mon.sync()
    mon.run(0x2000, jsr=True)
    check(fake.started == ('J', 0x2000), 'J2000 for JSR')

    # silent board
    mon = sxb134.Monitor(FakeMonitor(silent=True))
    try:
        mon.sync(wait_reset=0.5)
        check(False, 'a silent board is reported')
    except sxb134.LoadError as e:
        check('not answering' in str(e), 'a silent board is reported')

    # flash: write the AMTOR flash build into bank 3, then remove it again
    rom = os.path.join(repo, 'amtor', 'amtor_rom.s19')
    if os.path.exists(rom):
        img = sxb134.read_image(rom)
        fake = FakeMonitor()
        fake.chip[0x18000:0x18010] = bytes(range(16))          # old contents
        mon = sxb134.Monitor(fake)
        mon.sync()
        sectors = mon.flash(img, 3)
        got = {a: fake.chip[0x18000 + a - 0x8000] for a in img}
        check(got == img, 'flash: %d bytes of amtor_rom in chip bank 3' % len(img))
        check(fake.chip[0x18000:0x18003] == b'WDC', "flash: 'WDC' signature at $8000")
        check(sectors == [0x8000] and [o for o in fake.flash_ops if o[0] == 3] == [(3, 3, 0x8000, 0x1000)],
              'flash: one erase+program of sector $8000 (%s)' % fake.flash_ops)
        check(mon.verify(img) == [], 'flash: read back through W')
        mon.unflash(3)
        check(fake.chip[0x18000:0x19000] == b'\xFF' * 0x1000, "unflash: sector erased, no 'WDC' any more")

    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
