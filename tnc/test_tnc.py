"""Run tnc.s19 on the MyMENSCH emulator and check the transmitted audio.

The emulator is extended with 65C02 cycle counting, so every DAC write
gets a time stamp in CPU cycles. The test then
  - checks the sample period is 768 cycles (19200 samples/s at 14.7456 MHz),
  - demodulates the audio with a Goertzel-style tone detector,
  - undoes NRZI and bit stuffing, checks the AX.25 FCS,
  - compares the frame byte for byte with one built here in Python,
  - and measures the 1200 / 2200 Hz test tones.

    python test_tnc.py [-v]
"""
import cmath
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'aprs', 'test'))
from emu_mymensch import Board, load_s19, Halt  # noqa: E402

S19 = os.path.join(HERE, 'tnc.s19')
LST = os.path.join(HERE, 'tnc.lst')
CLK = 14_745_600
FS = 19_200
SPB = 16
ORA = 0x7F3F
PTT = 0x10

# 65C02 base cycle counts for every opcode the program uses in timed code,
# plus the rest of what it executes (counts outside the TX loop only need
# to be roughly right).
CYC = {
    0x18: 2, 0x38: 2, 0xA5: 3, 0x65: 3, 0x85: 3, 0x4A: 2, 0xAA: 2, 0xBD: 4,
    0x09: 2, 0x8D: 4, 0xC6: 5, 0xF0: 2, 0xA0: 2, 0x88: 2, 0xD0: 2, 0xEA: 2,
    0x80: 3, 0xA9: 2, 0xE6: 5, 0xC5: 3, 0xE5: 3, 0xB0: 2, 0xB2: 5, 0x4C: 3,
    0xAD: 4, 0x29: 2, 0x64: 3, 0x60: 6, 0x20: 6, 0xA2: 2, 0xCA: 2, 0x9D: 5,
    0xE8: 2, 0xC8: 2, 0xE0: 2, 0xC0: 2, 0xC9: 2, 0x90: 2, 0x49: 2, 0x5A: 3,
    0x7A: 4, 0xDA: 3, 0xFA: 4, 0x48: 3, 0x68: 4, 0x8A: 2, 0xA8: 2, 0x98: 2,
    0x0A: 2, 0x46: 5, 0x66: 5, 0x05: 3, 0x45: 3, 0x92: 5, 0x86: 3, 0x84: 3,
    0xB1: 5, 0x91: 6, 0xA6: 3, 0xA4: 3, 0xE4: 3, 0xC4: 3, 0x7C: 6, 0x6C: 6,
    0x0C: 6, 0x1C: 6, 0xDD: 4, 0xE9: 2, 0x69: 2,
    0x78: 2, 0x9A: 2, 0x9C: 4, 0xAE: 4, 0xD8: 2,
    0x00: 7,    # the emulator's reset stub, reached by ESC
}
BRANCH = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80}
INDEXED_READ = {0xBD: 'x', 0xB9: 'y', 0xDD: 'x', 0xB1: 'y'}


def labels():
    """label -> address, from the WDC listing."""
    out = {}
    for line in open(LST, encoding='latin-1'):
        m = re.match(r'\s*\d+\s+00:([0-9A-F]{4}):[0-9A-F ]*?\s([a-z_][a-z0-9_]*):', line)
        if m:
            out[m.group(2)] = int(m.group(1), 16)
    return out


class TncBoard(Board):
    def __init__(self, image, script):
        super().__init__(image, tx_period=1280 // 4)
        self.script = list(script)
        self.stream = bytearray()
        self.rxd = None
        self.mark = 0
        self.cyc = 0
        self.dac = []                       # (cycle, value)
        self.unknown = set()
        self.cpu.io_wr[ORA] = lambda a, v: self.dac.append((self.cyc, v))
        self.cpu.io_rd[ORA] = self._ora_rd  # SQC idle; PA7 = test audio
        self.ready_at = None
        self.leds = 0
        self.led_log = []                   # LED register values written
        self.cpu.io_rd[0x7F08] = lambda a: self.leds
        self.cpu.io_wr[0x7F08] = self._led_wr

    def _led_wr(self, a, v):
        self.leds = v
        self.led_log.append(v)

    RX_AUDIO_UNTIL = 1_500_000          # cycles of 1200 Hz on PA7 (~100 ms)

    def _ora_rd(self, a):
        if self.cyc < self.RX_AUDIO_UNTIL:
            return ((self.cyc // 6144) & 1) << 7     # 1200 Hz square wave
        return 0

    # console: type the next line once the wanted text has been printed
    # (and, if given, after a further delay in CPU cycles)
    def _a_stat_rd(self, a):
        if not self.stream and self.rxd is None and self.script:
            wait, text, *delay = self.script[0]
            out = self.cpu.out
            if self.ready_at is None and len(out) > self.mark and \
                    bytes(out).endswith(wait.encode()):
                self.ready_at = self.cyc + (delay[0] if delay else 0)
            if self.ready_at is not None and self.cyc >= self.ready_at:
                self.ready_at = None
                self.script.pop(0)
                self.stream = bytearray(text.encode())
        if self.rxd is None and self.stream:
            self.rxd = self.stream.pop(0)
            self.mark = len(self.cpu.out)
        tdre = 0x10 if self.tx_hold is None else 0
        return tdre | (0x08 if self.rxd is not None else 0)

    def _a_data_rd(self, a):
        v, self.rxd = self.rxd, None
        return v or 0

    def run(self, max_steps=200_000_000):
        cpu, m = self.cpu, self.cpu.mem
        cpu.pc, cpu.pbr = 0x8000, 0
        try:
            while cpu.steps < max_steps:
                self._hw()
                pc = cpu.pc
                op = m[pc]
                c = CYC.get(op)
                if c is None:
                    self.unknown.add(op)
                    c = 4
                if op in INDEXED_READ:
                    base = m[pc + 1] | (m[pc + 2] << 8) if op != 0xB1 else \
                        m[m[pc + 1]] | (m[(m[pc + 1] + 1) & 0xFF] << 8)
                    idx = cpu.x if INDEXED_READ[op] == 'x' else cpu.y
                    if (base & 0xFF) + (idx & 0xFF) > 0xFF:
                        c += 1
                cpu.step()
                if op in BRANCH:
                    nxt = (pc + 2) & 0xFFFF
                    if op == 0x80 or cpu.pc != nxt:
                        if op != 0x80:
                            c += 1
                        if (cpu.pc & 0xFF00) != (nxt & 0xFF00):
                            c += 1
                self.cyc += c
            return 'step limit'
        except Halt as h:
            return str(h)


def bursts(dac):
    """Split DAC writes into keyed bursts: lists of (cycle, 4-bit value)."""
    out, cur = [], []
    for t, v in dac:
        if v & PTT:
            cur.append((t, v & 0x0F))
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def tones(samples):
    """One tone decision per 16-sample bit: 0 = 1200 Hz, 1 = 2200 Hz."""
    out = []
    for i in range(0, len(samples) - SPB + 1, SPB):
        x = [s - 7.5 for s in samples[i:i + SPB]]
        e = []
        for f in (1200, 2200):
            w = 2 * math.pi * f / FS
            e.append(abs(sum(v * cmath.exp(-1j * w * n) for n, v in enumerate(x))))
        out.append(0 if e[0] > e[1] else 1)
    return out


def crc_x25(data):
    crc = 0xFFFF
    for b in data:
        for i in range(8):
            bit = (b >> i) & 1
            if (crc ^ bit) & 1:
                crc = (crc >> 1) ^ 0x8408
            else:
                crc >>= 1
    return crc ^ 0xFFFF


def deframe(tone_list):
    """NRZI decode, find flags, unstuff. Returns (leading flags, frame bytes)."""
    bits = [1 if tone_list[i] == tone_list[i - 1] else 0 for i in range(1, len(tone_list))]
    s = ''.join(map(str, bits))
    flag = '01111110'
    first = s.find(flag)
    lead = 0
    i = first
    while s.startswith(flag, i):
        lead += 1
        i += 8
    end = s.find(flag, i)
    raw = s[i:end]
    data, ones = [], 0
    for ch in raw:
        if ones == 5:
            assert ch == '0', 'stuffing violation'
            ones = 0
            continue
        data.append(ch)
        ones = ones + 1 if ch == '1' else 0
    assert len(data) % 8 == 0, 'frame not a whole number of bytes'
    out = bytes(int(''.join(reversed(data[k:k + 8])), 2) for k in range(0, len(data), 8))
    return lead, out


def addr(call, ssid, last=False, cbit=False):
    call = call.ljust(6)
    b = bytes(ord(c) << 1 for c in call)
    return b + bytes([0x60 | (ssid << 1) | (0x80 if cbit else 0) | (1 if last else 0)])


def main():
    lab = labels()
    img = load_s19(S19)
    lat, lon = '3500.00N', '08500.00W'
    script = [
        ('help\r\n', 'S'),
        ('min\r\n', 'B'),
        ('done\r\n', '1'),
        ('stops ... ', 'x'),
        ('done\r\n', '2'),
        ('stops ... ', 'x'),
        ('done\r\n', '\x1b', 40 * 147_968),     # 40 idle ticks first
    ]
    b = TncBoard(img, script)
    m = b.cpu.mem
    m[lab['cfg_ok']] = 1
    m[lab['cfg_txd']] = 8                     # shorter TXDELAY: faster test
    m[lab['cfg_lat']:lab['cfg_lat'] + 8] = lat.encode()
    m[lab['cfg_lon']:lab['cfg_lon'] + 9] = lon.encode()
    reason = b.run()
    out = b.cpu.out.decode('latin-1')
    if '-v' in sys.argv:
        print(out)
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(('  ok   ' if cond else '  FAIL ') + msg)
        ok &= bool(cond)

    c0 = lab['cfg_call']
    call = bytes(m[c0:c0 + 6]).decode().strip()
    ssid = m[c0 + 6] & 0x0F
    me = call + ('-%d' % ssid if ssid else '')
    info = '!' + lat + '/' + lon + '-MyMENSCH 65C02 software TNC'
    text = me + '>APZ65C,WIDE1-1,WIDE2-1:' + info
    check(reason == 'RESET', 'program ran and exited with ESC (%s)' % reason)
    bmin = m[lab['cfg_bmin']]
    check('periodic beacon on, every %d min, next in 1 min' % bmin in out, 'status line')
    check('TX ' + text in out, 'console shows ' + text)
    check(not b.unknown, 'cycle table covers every opcode (%s)' % sorted(map(hex, b.unknown)))

    hb = [v & 1 for v in b.led_log]
    flips = sum(1 for i in range(1, len(hb)) if hb[i] != hb[i - 1])
    check(1 in hb and flips >= 2, 'heartbeat LED 0 blinks while idle (%d changes)' % flips)
    tx = [bool(v & 2) for v in b.led_log]
    check(any(tx) and not tx[-1], 'TX LED 1 on while keyed, off after')
    rx = [bool(v & 4) for v in b.led_log]
    check(any(rx) and not rx[-1], 'RX LED 2 on with audio on PA7, off after the hang time')

    bs = bursts(b.dac)
    check(len(bs) == 3, '3 keyed bursts (beacon, 1200 Hz, 2200 Hz): %d' % len(bs))
    if len(bs) != 3:
        print('FAILED')
        return 1

    # timing
    for name, burst in zip(('beacon', 'tone1', 'tone2'), bs):
        d = [burst[i + 1][0] - burst[i][0] for i in range(len(burst) - 1)]
        n768 = sum(1 for x in d if x == 768)
        odd = sorted(set(x for x in d if x != 768))
        mean = sum(d) / len(d)
        check(abs(mean - 768) / 768 < 0.0005 and n768 / len(d) > 0.99,
              '%s: %d samples, period mean %.3f cycles (%.2f samples/s), %.2f%% exactly 768, other %s'
              % (name, len(burst), mean, CLK / mean, 100 * n768 / len(d), odd[:4]))

    # beacon contents
    lead, frame = deframe(tones([v for _, v in bs[0]]))
    want = (addr('APZ65C', 0, cbit=True) + addr(call, ssid) + addr('WIDE1', 1) +
            addr('WIDE2', 1, last=True) + b'\x03\xF0' + info.encode())
    body, fcs = frame[:-2], frame[-2:]
    # NRZI needs one tone before the first bit, so the decoder sees txd - 1
    check(lead >= 8 - 1, 'TXDELAY flags before the frame: %d of 8 recognised' % lead)
    check(body == want, 'frame bytes match an independent AX.25 encoding (%d bytes)' % len(body))
    check(int.from_bytes(fcs, 'little') == crc_x25(body), 'FCS correct: %s' % fcs.hex())

    # test tones: count zero crossings
    for f, burst in zip((1200, 2200), bs[1:]):
        v = [s for _, s in burst]
        ups = sum(1 for i in range(1, len(v)) if v[i - 1] < 8 <= v[i])
        secs = (burst[-1][0] - burst[0][0]) / CLK
        check(abs(ups / secs - f) < f * 0.003, 'test tone %d Hz measured %.1f Hz' % (f, ups / secs))

    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
