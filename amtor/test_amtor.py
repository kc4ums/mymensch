"""Run the AMTOR station (amtor_ram.s19) on a W65C134SXB model.

The model is the shared 65C02 core (../tools/emu) with cycle counting and:
  - Timer 1 (period = latch + 1), IFR2/IER2, and its interrupt through the
    ROM's stub at $FED9 (JMP ($004A)), as on the real chip;
  - P46 falling-edge interrupt (IFR1/IER1 bit 2) through $FE48
    (JMP ($004C)), driven by a PS/2 keyboard model: 80 us bit cells, data
    changes 5 us after each rising clock edge, so a bit read late is read
    wrong;
  - an HD44780 in 4-bit mode on P40-P45 that flags any byte sent less than
    37 us (1.52 ms after a clear) after the one before;
  - the radio: DAC/PTT on Port 5 captured while keyed; the comparator on
    P57 fed from an fldigi-equivalent SITOR-B signal plus noise.

Checks: the transmitted audio, demodulated and decoded here independently
with fldigi's CCIR 476 table, carries what was typed plus the ID, with
every character's two copies intact; received signals (clean, noisy, and
joined mid-message with no phasing) come out on the LCD; no Timer 1 tick
is lost; keyboard bits are all read inside their window; LCD timing holds.

    python test_amtor.py [-v]
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools', 'emu'))
from emu_mymensch import CPU, Halt, load_s19, M, XF, I   # noqa: E402
import mk_tables as T                                      # noqa: E402

S19 = os.path.join(HERE, 'amtor_ram.s19')
CLK = 3_686_400
US = CLK / 1e6
VERBOSE = '-v' in sys.argv

# W65C134S registers
PD3, PCS3, IFR2, IER2, TCR2, T1LL, T1CH, BCR = 0x03, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x11, 0x1B
PD4, PD5, PDD4, PDD5, PD6, PDD6, IFR1, IER1 = 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x2C, 0x2D
SCR, HIST = 0x0480, 0x4000

# 65C02 base cycle counts (WDC W65C02S datasheet)
CYC = [7, 6, 2, 1, 5, 3, 5, 5, 3, 2, 2, 1, 6, 4, 6, 5,
       2, 5, 5, 1, 5, 4, 6, 5, 2, 4, 2, 1, 6, 4, 6, 5,
       6, 6, 2, 1, 3, 3, 5, 5, 4, 2, 2, 1, 4, 4, 6, 5,
       2, 5, 5, 1, 4, 4, 6, 5, 2, 4, 2, 1, 4, 4, 6, 5,
       6, 6, 2, 1, 3, 3, 5, 5, 3, 2, 2, 1, 3, 4, 6, 5,
       2, 5, 5, 1, 4, 4, 6, 5, 2, 4, 3, 1, 8, 4, 6, 5,
       6, 6, 2, 1, 3, 3, 5, 5, 4, 2, 2, 1, 6, 4, 6, 5,
       2, 5, 5, 1, 4, 4, 6, 5, 2, 4, 4, 1, 6, 4, 6, 5,
       3, 6, 2, 1, 3, 3, 3, 5, 2, 2, 2, 1, 4, 4, 4, 5,
       2, 6, 5, 1, 4, 4, 4, 5, 2, 5, 2, 1, 4, 5, 5, 5,
       2, 6, 2, 1, 3, 3, 3, 5, 2, 2, 2, 1, 4, 4, 4, 5,
       2, 5, 5, 1, 4, 4, 4, 5, 2, 4, 2, 1, 4, 4, 4, 5,
       2, 6, 2, 1, 3, 3, 5, 5, 2, 2, 2, 3, 4, 4, 6, 5,
       2, 5, 5, 1, 4, 4, 6, 5, 2, 4, 3, 3, 4, 4, 7, 5,
       2, 6, 2, 1, 3, 3, 5, 5, 2, 2, 2, 1, 4, 4, 6, 5,
       2, 5, 5, 1, 4, 4, 6, 5, 2, 4, 4, 1, 4, 4, 7, 5]
BRANCH = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0}
ABSX = {0x1D, 0x3D, 0x5D, 0x7D, 0xBD, 0xDD, 0xFD, 0xBC, 0x3C}
ABSY = {0x19, 0x39, 0x59, 0x79, 0xB9, 0xD9, 0xF9, 0xBE}
INDY = {0x11, 0x31, 0x51, 0x71, 0xB1, 0xD1, 0xF1}
ROLLIGAL = {0x07, 0x0F}   # low nibble 7 / F: RMB/SMB/BBR/BBS, not in the core


# ---------------------------------------------------------------- devices
class LCD:
    ROWS = (0x00, 0x40, 0x14, 0x54)

    def __init__(self, bench):
        self.b = bench
        self.e = 0
        self.mode8 = True
        self.pend = None
        self.ram = bytearray(b' ' * 128)
        self.ac = 0
        self.busy_until = 0
        self.errors = []
        self.bytes = 0

    def write(self, v):
        e = v & 0x20
        if self.e and not e:                    # falling edge latches
            nib, rs = v & 0x0F, bool(v & 0x10)
            if self.mode8:
                self.exec(nib << 4, rs)
                if (nib << 4) == 0x20:
                    self.mode8 = False
            elif self.pend is None:
                self.pend = (nib, rs)
            else:
                hi, rs0 = self.pend
                self.pend = None
                self.exec((hi << 4) | nib, rs0)
        self.e = e

    def exec(self, byte, rs):
        now = self.b.cyc
        if now < self.busy_until:
            self.errors.append('byte %02X %.1f us early' % (byte, (self.busy_until - now) / US))
        self.busy_until = now + 37 * US
        self.bytes += 1
        if rs:
            self.ram[self.ac & 0x7F] = byte
            self.ac = (self.ac + 1) & 0x7F
        elif byte == 0x01:
            self.ram[:] = b' ' * 128
            self.ac = 0
            self.busy_until = now + 1520 * US
        elif byte & 0x80:
            self.ac = byte & 0x7F
        elif (byte & 0xF0) == 0x30 and self.mode8:
            self.busy_until = now + 100 * US

    def text(self):
        return [bytes(self.ram[a:a + 20]).decode('latin-1') for a in self.ROWS]


class Keyboard:
    """PS/2 device: 11-bit frames, 80 us cells, clock low 20-60 us."""

    def __init__(self, bench):
        self.b = bench
        self.events = []          # (cycle, kind, value)
        self.level = 1
        self.reads = []           # (cycle, level read, level the bit should be)
        self.t = 0

    def send(self, at, codes):
        t = max(at, self.t)
        for c in codes:
            par = 1 ^ (bin(c).count('1') & 1)
            bits = [0] + [(c >> i) & 1 for i in range(8)] + [par, 1]
            for i, bit in enumerate(bits):
                cell = t + i * 80 * US
                self.events.append((cell - 15 * US, 'data', bit))       # 5 us after the last rise
                self.events.append((cell + 20 * US, 'fall', bit))
            t += 11 * 80 * US + 300 * US
        self.t = t
        self.events.sort(key=lambda e: e[0])

    def tick(self, cyc):
        while self.events and self.events[0][0] <= cyc:
            _, kind, v = self.events.pop(0)
            if kind == 'data':
                self.level = v
            else:
                self.expect = v
                self.b.ifr1 |= 0x04

    def key(self, at, name):
        """Press and release one key: 'F1', 'ENTER', or a character."""
        rev = {v: k for k, v in T.SPECIAL.items()}
        if name in rev:
            code = [rev[name]]
        elif name == 'ENTER':
            code = [0x5A]
        elif name == 'ESC':
            code = [0x76]
        elif name in ('UP', 'DOWN', 'END', 'HOME'):
            c = {'UP': 0x75, 'DOWN': 0x72, 'END': 0x69, 'HOME': 0x6C}[name]
            self.send(at, [0xE0, c, 0xE0, 0xF0, c])
            return
        else:
            plain = [k for k, (a, b) in T.SET2.items() if a == name.lower() and k < 0x70]
            shift = [k for k, (a, b) in T.SET2.items() if b == name and a != b and k < 0x70]
            if plain:
                code = plain
            else:
                assert shift, name
                self.send(at, [0x12, shift[0], 0xF0, shift[0], 0xF0, 0x12])
                return
        self.send(at, [code[0], 0xF0, code[0]])

    def type(self, at, text):
        for ch in text:
            self.key(at, 'ENTER' if ch == '\n' else ch)


class SXB134:
    def __init__(self, image, audio=None):
        self.cpu = cpu = CPU()
        for a, d in image:
            cpu.mem[a:a + len(d)] = d
        m = cpu.mem
        # ROM interrupt stubs and vectors (real JMP (abs) code)
        m[0xFED9:0xFEDC] = bytes([0x6C, 0x4A, 0x00])
        m[0xFE48:0xFE4B] = bytes([0x6C, 0x4C, 0x00])
        m[0xFFF2:0xFFF4] = bytes([0xD9, 0xFE])
        m[0xFFD4:0xFFD6] = bytes([0x48, 0xFE])
        m[0x4A:0x4E] = bytes([0x8F, 0xF0, 0x4B, 0xFE])   # monitor: RESET, PDOWN
        m[0x86] = 3
        cpu.hooks[0xF08F] = lambda c: self._halt('T1 interrupt went to the monitor')
        cpu.hooks[0xFE4B] = lambda c: self._halt('NE46 went to PDOWN')
        cpu.hooks[0xF039] = lambda c: self._halt('MONITOR')
        cpu.e = 1
        cpu.p = M | XF | I
        cpu.s = 0x01FF
        self.cyc = 0
        self.ifr1 = self.ifr2 = self.ier1 = self.ier2 = 0
        self.pd3 = 0xFF
        self.pd5 = 0
        self.t1_latch = 0
        self.t1_next = None
        self.t1_period = None
        self.lost = 0
        self.t1_count = 0
        self.isr_lat = []
        self.dac = []
        self.lcd = LCD(self)
        self.kb = Keyboard(self)
        self.kb_bad = []
        self.audio = audio
        self.leds = []
        r, w = cpu.io_rd, cpu.io_wr
        r[IFR2] = lambda a: self._t1() or self.ifr2
        w[IFR2] = lambda a, v: self._ifr2_w(v)
        r[IER2] = lambda a: self.ier2
        w[IER2] = lambda a, v: setattr(self, 'ier2', v)
        r[IFR1] = lambda a: self.ifr1
        w[IFR1] = lambda a, v: setattr(self, 'ifr1', self.ifr1 & ~v)
        r[IER1] = lambda a: self.ier1
        w[IER1] = lambda a, v: setattr(self, 'ier1', v)
        w[T1LL] = lambda a, v: setattr(self, 't1_latch', (self.t1_latch & 0xFF00) | v)
        w[T1CH] = self._t1ch
        r[PD3] = lambda a: self.pd3
        w[PD3] = self._pd3
        w[PD4] = lambda a, v: self.lcd.write(v)
        r[PD5] = self._pd5_rd
        w[PD5] = self._pd5_wr
        r[PD6] = self._pd6_rd

    def _halt(self, why):
        raise Halt(why)

    def _pd3(self, a, v):
        self.pd3 = v
        self.leds.append((self.cyc, v))

    def _t1ch(self, a, v):
        self.t1_latch = (self.t1_latch & 0xFF) | (v << 8)
        self.t1_period = self.t1_latch + 1
        self.t1_next = self.cyc + self.t1_period
        self.ifr2 &= ~0x10

    def _t1(self):
        while self.t1_next is not None and self.cyc >= self.t1_next:
            if self.ifr2 & 0x10:
                self.lost += 1
            self.ifr2 |= 0x10
            self.t1_set = self.t1_next
            self.t1_next += self.t1_period
            self.t1_count += 1
        return 0

    def _ifr2_w(self, v):
        self._t1()
        self.ifr2 &= ~v

    def _pd5_wr(self, a, v):
        self.pd5 = v
        if v & 0x10:
            self.dac.append((self.cyc, v & 0x0F))

    def _pd5_rd(self, a):
        bit = 0
        if self.audio is not None:
            i = int(self.cyc * 48000 / CLK)
            if i < len(self.audio):
                bit = 0x80 if self.audio[i] > 0 else 0
        return (self.pd5 & 0x7F) | bit

    def _pd6_rd(self, a):
        kb = self.kb
        if getattr(kb, 'expect', None) is not None:
            if kb.level != kb.expect:
                self.kb_bad.append(self.cyc)
            kb.expect = None
        return 0x08 if kb.level else 0

    def run(self, until, pc=None):
        cpu, m = self.cpu, self.cpu.mem
        if pc is not None:
            cpu.pc, cpu.pbr = pc, 0
        kb = self.kb
        try:
            while self.cyc < until:
                if kb.events:
                    kb.tick(self.cyc)
                self._t1()
                if not cpu.p & I:
                    if self.ifr2 & self.ier2 & 0x10:
                        self.isr_lat.append(self.cyc - self.t1_set)
                        cpu.irq(0xFFF2)
                        self.cyc += 7
                    elif self.ifr1 & self.ier1 & 0x04:
                        cpu.irq(0xFFD4)
                        self.cyc += 7
                pc = cpu.pc
                if pc in cpu.hooks:
                    cpu.hooks[pc](cpu)
                    continue
                op = m[pc]
                if (op & 0x0F) == 0x07 or (op & 0x0F) == 0x0F:
                    raise Halt('Rockwell bit opcode %02X at %04X' % (op, pc))
                c = CYC[op]
                if op in ABSX or op in ABSY:
                    base = m[pc + 1] | (m[pc + 2] << 8)
                    idx = cpu.x if op in ABSX else cpu.y
                    if (base & 0xFF) + (idx & 0xFF) > 0xFF:
                        c += 1
                elif op in INDY:
                    zp = m[pc + 1]
                    base = m[zp] | (m[(zp + 1) & 0xFF] << 8)
                    if (base & 0xFF) + (cpu.y & 0xFF) > 0xFF:
                        c += 1
                cpu.step()
                if op in BRANCH:
                    nxt = (pc + 2) & 0xFFFF
                    if cpu.pc != nxt:
                        c += 1 + ((cpu.pc & 0xFF00) != (nxt & 0xFF00))
                self.cyc += c
            return 'time'
        except Halt as h:
            return str(h)


# ---------------------------------------------------------------- signals
def fec_stream(text, phasing=16):
    """fldigi's encode() and create_fec(), with phasing in front."""
    codes, shift = [], False
    for ch in text.upper():
        ch = '\r' if ch == '\n' else ch
        seq = ['\r', '\n'] if ch == '\r' else [ch]
        for c in seq:
            lt = [k for k in range(128) if T.valid(k) and T.LTRS[k] == c]
            fg = [k for k in range(128) if T.valid(k) and T.FIGS[k] == c]
            if (shift and fg) or (not shift and lt):
                codes.append((fg if shift else lt)[0])
            elif fg:
                shift = True
                codes += [T.C_FIGS, fg[0]]
            elif lt:
                shift = False
                codes += [T.C_LTRS, lt[0]]
    out = [T.C_REP, T.C_ALPHA] * phasing
    for i, c in enumerate(codes):
        out += [c, codes[i - 2] if i >= 2 else T.C_ALPHA]
    for i in range(2):
        out += [T.C_CH32, codes[len(codes) - 2 + i]]
    return out


def audio_for(codes, snr_db, lead_s=0.3, seed=1, fc=1700):
    from scipy.signal import butter, sosfilt
    fs = 48000
    bits = [(c >> j) & 1 for c in codes for j in range(7)]
    spb = fs // 100
    f = np.repeat(np.where(np.array(bits) == 1, fc + 85, fc - 85), spb)
    sig = np.sin(2 * np.pi * np.cumsum(f) / fs)
    lead = int(lead_s * fs)
    x = np.concatenate([np.zeros(lead), sig, np.zeros(fs // 2)])
    rng = np.random.default_rng(seed)
    sos = butter(6, [300, 2700], 'bandpass', fs=fs, output='sos')
    nz = sosfilt(sos, rng.standard_normal(len(x) + 4000))[4000:]
    nz *= np.sqrt(0.5 / (np.mean(nz ** 2) * 10 ** (snr_db / 10)))
    return x + nz


def decode_codes(slots, start=0):
    """fldigi-style: DX slot k, its repeat at k+5; returns (text, bad, mismatched)."""
    out, bad, mism, shift = [], 0, 0, False
    k = start
    while k + 5 < len(slots):
        dx, rx = slots[k], slots[k + 5]
        k += 2
        if dx == T.C_REP:
            continue
        if T.valid(dx) and T.valid(rx) and dx != rx:
            mism += 1
        v = dx if T.valid(dx) else (rx if T.valid(rx) else None)
        if v is None:
            bad += 1
            out.append('_')
            continue
        if v == T.C_LTRS:
            shift = False
        elif v == T.C_FIGS:
            shift = True
        elif v in (T.C_ALPHA, T.C_BETA, T.C_CH32):
            pass
        else:
            ch = (T.FIGS if shift else T.LTRS)[v]
            if ch != '_':
                out.append(ch)
    return ''.join(out), bad, mism


def demod_dac(dac):
    """DAC samples (192 cycles apart) -> 7-bit slots, synchronised on phasing."""
    t = np.array([c for c, _ in dac], dtype=np.float64)
    v = np.array([s for _, s in dac], dtype=np.float64) - 7.5
    n = np.arange(len(v))
    d = []
    for f in (1785, 1615):
        ref = np.exp(-2j * np.pi * f * n / 19200)
        d.append(np.abs(np.convolve(v * ref, np.ones(192), 'full')[:len(v)]))
    d = d[0] - d[1]
    best = None
    for off in range(192):
        idx = np.arange(off + 191, len(d), 192)
        score = np.sum(np.abs(d[idx]))
        if best is None or score > best[0]:
            best = (score, idx)
    bits = (d[best[1]] > 0).astype(int)
    for s in range(len(bits) - 28):
        slots = [sum(int(bits[s + 7 * k + j]) << j for j in range(7))
                 for k in range((len(bits) - s) // 7)]
        if slots[:4] == [T.C_REP, T.C_ALPHA, T.C_REP, T.C_ALPHA]:
            return slots, t, v
    return None, t, v


# ---------------------------------------------------------------- runs
ok = True


def check(cond, msg):
    global ok
    print(('  ok   ' if cond else '  FAIL ') + msg)
    ok &= bool(cond)


def screen(b):
    rows = b.lcd.text()
    if VERBOSE:
        print('    +' + '-' * 20 + '+')
        for r in rows:
            print('    |' + r + '|')
        print('    +' + '-' * 20 + '+')
    return rows


def history(b):
    m = b.cpu.mem
    head, n = m[0x060B], m[0x060C]
    lines = []
    for i in range(n):
        a = HIST + ((head - n + i) & 0xFF) * 20
        lines.append(bytes(m[a:a + 20]).decode('latin-1'))
    live = bytes(m[0x0450 + 20:0x0450 + 40]).decode('latin-1')
    return lines + [live]


def common_checks(b, name):
    check(not b.lcd.errors, '%s: LCD timing (%d bytes) %s' % (name, b.lcd.bytes, b.lcd.errors[:2]))
    check(b.lost == 0, '%s: no Timer 1 tick lost (%d ticks, worst entry delay %d cycles)'
          % (name, b.t1_count, max(b.isr_lat) if b.isr_lat else -1))
    check(not b.kb_bad, '%s: every keyboard bit read inside its window' % name)


def run_tx():
    print('transmit:')
    b = SXB134(load_s19(S19))
    ms = CLK // 1000
    msg = 'CQ TEST 1/2? DE KC4UMS'
    b.kb.type(300 * ms, msg)
    b.kb.key(1500 * ms, 'ENTER')
    b.kb.key(1600 * ms, 'F1')
    b.kb.type(4500 * ms, 'RYRY')
    b.kb.key(5000 * ms, 'F2')
    r = b.run(16000 * ms, pc=0x2000)
    rows = screen(b)
    check(r == 'time', 'ran without a crash (%s)' % r)
    keyed = [c for c, _ in b.dac]
    check(len(keyed) > 1000, 'keyed and sent audio (%d samples, %.2f s)' %
          (len(keyed), (keyed[-1] - keyed[0]) / CLK if keyed else 0))
    if len(keyed) < 1000:
        return
    gaps = np.diff(keyed)
    check(abs(np.mean(gaps) - 192) < 0.01 and np.max(np.abs(gaps - 192)) < 40,
          'DAC sample every %.3f cycles (19200/s), jitter %d..%d' % (np.mean(gaps), gaps.min(), gaps.max()))
    slots, t, v = demod_dac(b.dac)
    check(slots is not None, 'phasing found in the transmitted audio')
    if slots is None:
        return
    nph = 0
    while slots[2 * nph:2 * nph + 2] == [T.C_REP, T.C_ALPHA]:
        nph += 1
    text, bad, mism = decode_codes(slots)
    allvalid = all(T.valid(s) for s in slots[:len(slots) - 1])
    check(nph >= 16, '%d phasing pairs (RQ alpha) first' % nph)
    check(allvalid, 'every slot is a valid 4-of-7 code')
    check(bad == 0 and mism == 0, 'every character and its repeat agree (%d bad, %d differ)' % (bad, mism))
    want = msg + '\r\n' + 'RYRY' + '\r\nDE KC4UMS\r\n'
    got = text
    print('    decoded: %r' % got)
    check(got.startswith(want) or got.rstrip('_') == want, 'decodes to what was typed, then the ID')
    # tone check on the longest single-tone run
    for f in (1785, 1615):
        n = np.arange(len(v))
        ref = np.exp(-2j * np.pi * f * n / 19200)
        e = np.abs(np.convolve(v * ref, np.ones(192), 'valid'))
        check(e.max() > 0.9 * 192 * 7 / 2 * 0.95, '%d Hz tone present at full level' % f)
    ptt_off = b.pd5 & 0x10 == 0
    check(ptt_off and b.cpu.mem[0xCF] == 0, 'back to receive with PTT off')
    check('RX' in rows[0], 'status row back to RX: %r' % rows[0])
    common_checks(b, 'tx')


def run_rx(name, text, snr, phasing=16, start_slot=0, max_cer=0.0):
    print('receive (%s):' % name)
    codes = fec_stream(text, phasing)[start_slot:]
    audio = audio_for(codes, snr)
    b = SXB134(load_s19(S19), audio=audio)
    dur = len(audio) / 48000
    r = b.run(int((dur + 0.2) * CLK), pc=0x2000)
    screen(b)
    check(r == 'time', 'ran without a crash (%s)' % r)
    got = ''.join(l.rstrip() + '\n' if len(l.rstrip()) < 20 else l for l in history(b))
    flat = got.replace('\n', ' ').split()
    body = ' '.join(flat)
    want = ' '.join(text.replace('\n', ' ').split())
    # character error rate over the expected text (aligned on the end)
    i = body.find(want[:6]) if start_slot == 0 else 0
    seg = body[i:i + len(want)] if i >= 0 else ''
    errs = sum(1 for a, c in zip(seg, want) if a != c) + abs(len(want) - len(seg))
    cer = errs / len(want)
    if VERBOSE or cer > max_cer:
        print('    printed: %r' % body[-160:])
    if start_slot:
        tail = want[-30:]
        check(tail in body, 'joined mid-message: the end %r came out (%.0f%% CER overall)' % (tail, 100 * cer))
    else:
        check(cer <= max_cer, 'SNR %+d dB: %d of %d characters wrong (%.1f%%, limit %.0f%%)'
              % (snr, errs, len(want), 100 * cer, 100 * max_cer))
    common_checks(b, name)


def main():
    if not os.path.exists(S19):
        sys.exit('build first: mk_amtor.bat')
    run_tx()
    msg = 'RYRYRY CQ CQ DE W1AW W1AW\nTHE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789 /?.,\nDE W1AW K'
    run_rx('clean', msg, 20)
    run_rx('noisy', msg, 0, max_cer=0.05)
    run_rx('joined late', msg, 20, start_slot=120)
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
