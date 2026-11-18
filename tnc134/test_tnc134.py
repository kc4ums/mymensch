"""Run tnc134.s19 on a W65C134SXB model and check the transmitted audio.

The model is the shared 65C02 core (../tools/emu) with:
  - the ROM monitor's OUTCH ($F00F), RD_CHAR ($F006) and monitor-prompt
    ($F039) entry points stood in for by Python,
  - Port 5 (DAC, PTT, SQC, RX), Port 3 (LEDs), Timer 1 and IFR2,
  - the monitor's crystal code at $86 = 3 (3.6864 MHz).
Cycle counting and the audio checks are the same as ../tnc/test_tnc.py:
sample period, demodulated frame byte for byte, FCS, test tone pitch.

    python test_tnc134.py [-v]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools', 'emu'))
sys.path.insert(0, os.path.join(HERE, '..', 'tnc'))
from emu_mymensch import CPU, Halt, load_s19, M, XF, I, Z, N   # noqa: E402
from test_tnc import (CYC, BRANCH, INDEXED_READ, bursts, tones,   # noqa: E402
                      crc_x25, deframe, addr)

S19 = os.path.join(HERE, 'tnc134.s19')
LST = os.path.join(HERE, 'tnc134.lst')
CLK = 3_686_400
SAMPLE = 192
PD3, IFR2, T1LL, T1LH, T1CL, T1CH, PD5 = 0x03, 0x08, 0x0C, 0x0D, 0x10, 0x11, 0x1D
RD_CHAR, OUTCH, MON_START = 0xF006, 0xF00F, 0xF039
TICK = 36_864

CYC = dict(CYC)
CYC.update({0x24: 3, 0x04: 5, 0x14: 5, 0x58: 2,    # bit zp, tsb zp, trb zp, cli
            0x10: 2, 0x9E: 5})                     # bpl, stz abs,x


def labels():
    out, pending = {}, []
    for line in open(LST, encoding='latin-1'):
        m = re.match(r'\s*\d+\s+00:([0-9A-F]{4}):[0-9A-F ]*?\s([a-z_][a-z0-9_]*):', line)
        if m:
            out[m.group(2)] = int(m.group(1), 16)
        a = re.match(r'\s*\d+\s+00:([0-9A-F]{4}):', line)
        if a:                                   # a label alone on its line takes the next address
            for p in pending:
                out[p] = int(a.group(1), 16)
            pending = []
        else:
            m = re.match(r'\s*\d+\s+([a-z_][a-z0-9_]*):\s*$', line)
            if m:
                pending.append(m.group(1))
    return out


class SXB134:
    def __init__(self, image, script):
        self.cpu = cpu = CPU()
        for a, data in image:
            cpu.mem[a:a + len(data)] = data
        cpu.e = 1
        cpu.p = M | XF | I
        cpu.s = 0x01FF
        cpu.mem[0x86] = 3                       # SPEED: 3.6864 MHz
        self.script = list(script)
        self.stream = bytearray()
        self.mark = 0
        self.ready_at = None
        self.cyc = 0
        self.dac = []
        self.leds = 0xFF                        # ROM leaves PD3 = $FF (all dark)
        self.led_log = []
        self.unknown = set()
        self.t1_latch = 0
        self.t1_period = None
        self.t1_next = None
        self.t1_flag = False
        cpu.hooks[OUTCH] = self._outch
        cpu.hooks[RD_CHAR] = self._rd_char
        cpu.hooks[MON_START] = self._monitor
        cpu.io_wr[PD5] = lambda a, v: self.dac.append((self.cyc, v))
        cpu.io_rd[PD5] = self._pd5_rd
        cpu.io_rd[PD3] = lambda a: self.leds
        cpu.io_wr[PD3] = self._led_wr
        cpu.io_wr[T1LL] = self._t1ll_wr
        cpu.io_wr[T1CL] = self._t1ll_wr
        cpu.io_wr[T1LH] = self._t1lh_wr
        cpu.io_wr[T1CH] = self._t1ch_wr
        cpu.io_rd[IFR2] = self._ifr_rd
        cpu.io_wr[IFR2] = self._ifr_wr

    # ROM monitor stand-ins ------------------------------------------------
    def _rts(self):
        self.cpu.pc = (self.cpu.pull16() + 1) & 0xFFFF
        self.cyc += 6

    def _outch(self, cpu):
        cpu.out.append(cpu.a & 0x7F)
        self._rts()

    def _rd_char(self, cpu):
        if not self.stream and self.script:
            wait, text, *delay = self.script[0]
            out = cpu.out
            if self.ready_at is None and len(out) > self.mark and \
                    bytes(out).endswith(wait.encode()):
                self.ready_at = self.cyc + (delay[0] if delay else 0)
            if self.ready_at is not None and self.cyc >= self.ready_at:
                self.ready_at = None
                self.script.pop(0)
                self.stream = bytearray(text.encode())
        a = 0
        if self.stream:
            a = self.stream.pop(0)
            self.mark = len(cpu.out)
        cpu.a = a
        cpu.flag(Z, a == 0)
        cpu.flag(N, a & 0x80)
        self._rts()

    def _monitor(self, cpu):
        raise Halt('MONITOR')

    # I/O --------------------------------------------------------------------
    RX_AUDIO_UNTIL = 400_000

    def _pd5_rd(self, a):
        if self.cyc < self.RX_AUDIO_UNTIL:
            return ((self.cyc // 1536) & 1) << 7     # 1200 Hz on P57
        return 0

    def _led_wr(self, a, v):
        self.leds = v
        self.led_log.append(v)

    def _t1ll_wr(self, a, v):
        self.t1_latch = (self.t1_latch & 0xFF00) | v

    def _t1lh_wr(self, a, v):
        self.t1_latch = (self.t1_latch & 0xFF) | (v << 8)

    def _t1ch_wr(self, a, v):
        self._t1lh_wr(a, v)
        self.t1_period = self.t1_latch + 1        # assumed: period = latch + 1
        self.t1_next = self.cyc + self.t1_period
        self.t1_flag = False

    def _t1_update(self):
        if self.t1_next is not None and self.cyc >= self.t1_next:
            self.t1_flag = True
            while self.t1_next <= self.cyc:
                self.t1_next += self.t1_period

    def _ifr_rd(self, a):
        self._t1_update()
        return 0x10 if self.t1_flag else 0

    def _ifr_wr(self, a, v):
        self._t1_update()
        if v & 0x10:
            self.t1_flag = False

    # run with cycle counting -----------------------------------------------
    def run(self, max_steps=200_000_000):
        cpu, m = self.cpu, self.cpu.mem
        cpu.pc, cpu.pbr = 0x2000, 0
        try:
            while cpu.steps < max_steps:
                pc = cpu.pc
                if pc in cpu.hooks:
                    cpu.steps += 1
                    cpu.hooks[pc](cpu)
                    continue
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


def main():
    lab = labels()
    img = load_s19(S19)
    lat, lon = '3500.00N', '08500.00W'
    script = [
        ('help\r\n', 'T'),
        ('not transmitted\r\n', 'T'),
        ('test mode off\r\n', 'S'),
        ('min\r\n', 'B'),
        ('done\r\n', '1'),
        ('stops ... ', 'x', 300_000),
        ('done\r\n', '2'),
        ('stops ... ', 'x', 300_000),
        ('done\r\n', '\x1b', 40 * TICK),
    ]
    b = SXB134(img, script)
    m = b.cpu.mem
    m[lab['cfg_ok']] = 1
    m[lab['cfg_txd']] = 8
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
    info = '!' + lat + '/' + lon + '-W65C134SXB software TNC'
    text = me + '>APZ65C,WIDE1-1,WIDE2-1:' + info
    bmin = m[lab['cfg_bmin']]
    check(reason == 'MONITOR', 'ESC returns to the monitor (%s)' % reason)
    check('W65C134SXB software TNC' in out and 'WARNING' not in out, 'banner, no clock warning')
    check('periodic beacon on, every %d min, next in 1 min' % bmin in out, 'status line')
    check('TX ' + text in out, 'console shows ' + text)
    check(not b.unknown, 'cycle table covers every opcode (%s)' % sorted(map(hex, b.unknown)))
    hb = [1 - (v & 1) for v in b.led_log]          # LEDs light on a 0
    flips = sum(1 for i in range(1, len(hb)) if hb[i] != hb[i - 1])
    check(1 in hb and flips >= 2, 'heartbeat LED (P30) blinks while idle (%d changes)' % flips)
    tx = [not v & 2 for v in b.led_log]
    check(any(tx) and not tx[-1], 'TX LED (P31) on while keyed, off after')
    rx = [not v & 4 for v in b.led_log]
    check(any(rx) and not rx[-1], 'RX LED (P32) on with audio on P57, off after the hang time')

    bs = bursts(b.dac)
    check(len(bs) == 3, '3 keyed bursts (beacon, 1200 Hz, 2200 Hz): %d' % len(bs))
    if len(bs) != 3:
        print('FAILED')
        return 1
    for name, burst in zip(('beacon', 'tone1', 'tone2'), bs):
        d = [burst[i + 1][0] - burst[i][0] for i in range(len(burst) - 1)]
        spread = (min(d), max(d))
        mean = sum(d) / len(d)
        check(abs(mean - SAMPLE) / SAMPLE < 0.0005 and spread[1] - spread[0] <= 8,
              '%s: %d samples, period mean %.3f cycles (%.2f samples/s), range %d-%d'
              % (name, len(burst), mean, CLK / mean, *spread))
    lead, frame = deframe(tones([v for _, v in bs[0]]))
    want = (addr('APZ65C', 0, cbit=True) + addr(call, ssid) + addr('WIDE1', 1) +
            addr('WIDE2', 1, last=True) + b'\x03\xF0' + info.encode())
    body, fcs = frame[:-2], frame[-2:]
    check(lead >= 8 - 1, 'TXDELAY flags before the frame: %d of 8 recognised' % lead)
    check(body == want, 'frame bytes match an independent AX.25 encoding (%d bytes)' % len(body))
    check(int.from_bytes(fcs, 'little') == crc_x25(body), 'FCS correct: %s' % fcs.hex())
    for f, burst in zip((1200, 2200), bs[1:]):
        v = [s for _, s in burst]
        t = [c for c, _ in burst]
        ups = [t[i] for i in range(1, len(v)) if v[i - 1] < 8 <= v[i]]
        hz = (len(ups) - 1) * CLK / (ups[-1] - ups[0])
        check(abs(hz - f) < f * 0.003, 'test tone %d Hz measured %.1f Hz' % (f, hz))
    check('test mode on: simulated South GA stations' in out and 'test mode off' in out,
          'T turns test mode on and off')
    ok &= test_sim(lab, check)
    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


def test_sim(lab, check):
    """Call the test-mode routines directly and decode what they print."""
    sys.path.insert(0, os.path.join(HERE, '..', 'tools', 'aprsmap'))
    import aprsmap
    b = SXB134(load_s19(S19), [])
    cpu, m = b.cpu, b.cpu.mem
    ret = 0xFFF0
    good = True

    def chk(cond, msg):
        nonlocal good
        check(cond, msg)
        good &= bool(cond)

    def back(c):
        raise Halt('ret')
    cpu.hooks[ret] = back

    def call(name):
        cpu.push16(ret - 1)
        cpu.pc = lab[name]
        try:
            for _ in range(200_000):
                if cpu.pc in cpu.hooks:
                    cpu.hooks[cpu.pc](cpu)
                else:
                    cpu.step()
        except Halt:
            return
        raise RuntimeError(name + ' did not return')

    m[0xD2] = 1                                     # SIMON
    call('sim_reset')
    m[lab['cfg_simg']] = 3
    cpu.out = bytearray()
    call('sim_tick')                                # SIMT = 1: prints now
    first = len(cpu.out)
    call('sim_tick')
    call('sim_tick')
    quiet = len(cpu.out) == first
    call('sim_tick')                                # 3 s later: the next one
    chk(first > 0 and quiet and len(cpu.out) > first, 'test mode: a packet every cfg_simg = 3 s')
    cpu.out = bytearray()
    for _ in range(20 * 16):                        # 16 rounds: the mobiles drive their routes
        call('sim_one')
    lines = cpu.out.decode('latin-1').split('\r\n')[:-1]
    dec = [aprsmap.decode(x) for x in lines]
    chk(len(lines) == 320 and all(dec), 'test mode: 320 packets printed, every one decodes (%d)' % len(lines))
    calls = {d['call'] for d in dec if d}
    placed = [d for d in dec if d and d['lat'] is not None]
    chk(len(calls) == 20, 'test mode: 20 stations and objects: %s' % ' '.join(sorted(calls)))
    chk(all(30.5 < d['lat'] < 32.2 and -85.2 < d['lon'] < -82.0 for d in placed),
        'test mode: every position is in South Georgia (%d positions)' % len(placed))
    car = [(d['lat'], d['lon']) for d in dec if d and d['call'] == 'SIM11-9']
    truck = [(d['lat'], d['lon']) for d in dec if d and d['call'] == 'SIM12-14']
    chk(len(set(car)) == 9 and len(set(truck)) == 9 and len(car) == 16,
        'test mode: car (I-75, Mic-E) and truck (US-82, compressed) drive 9 stops out and back')
    chk(any(d and d['kind'] == 'msg' for d in dec) and any(d and d['kind'] == 'status' for d in dec),
        'test mode: a message and a status are in the mix')
    return good


if __name__ == '__main__':
    sys.exit(main())
