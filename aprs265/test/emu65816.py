"""Small W65C816 emulator with just enough W65C265S hardware to test aprsrx.

Models:
  * the CPU (native and emulation mode, binary arithmetic only)
  * Mensch Monitor entry points PUT_CHR / GET_BYTE_FROM_PC as Python stubs
  * Timer 7 interrupt through the monitor's RAM vector at $011C
  * UART0 receive (UIFR bit 0, ARTD0, ACSR0 overrun flag)
"""

N, V, M, XF, D, I, Z, C = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01

TIFR, TIER, TER, TCR = 0xDF44, 0xDF46, 0xDF43, 0xDF42
UIFR, UIER, ACSR0, ARTD0 = 0xDF48, 0xDF49, 0xDF70, 0xDF71

PUT_CHR = 0xE04B
GET_BYTE_FROM_PC = 0xE033


class Halt(Exception):
    pass


class CPU:
    def __init__(self):
        self.mem = bytearray(1 << 24)
        self.a = self.x = self.y = 0
        self.s = 0x01F0
        self.d = 0
        self.dbr = self.pbr = 0
        self.pc = 0
        self.p = M | XF | I
        self.e = 0
        self.hooks = {}
        self.out = bytearray()
        self.steps = 0

    # ---------------- memory ----------------
    def rd(self, a):
        return self.mem[a & 0xFFFFFF]

    def wr(self, a, v):
        a &= 0xFFFFFF
        v &= 0xFF
        if a in (TIFR, UIFR):           # write 1 to clear
            self.mem[a] &= ~v & 0xFF
            return
        if a == ACSR0:
            keep = self.mem[a] & 0x80 & ~v
            self.mem[a] = (v & 0x7F) | keep
            return
        if 0xE000 <= a <= 0xFFFF:
            raise Halt('write to ROM at %04X' % a)
        self.mem[a] = v

    def rd16(self, a):
        return self.rd(a) | (self.rd(a + 1) << 8)

    def wr16(self, a, v):
        self.wr(a, v)
        self.wr(a + 1, v >> 8)

    def rdn(self, a, wide):
        return self.rd16(a) if wide else self.rd(a)

    def wrn(self, a, v, wide):
        if wide:
            self.wr16(a, v)
        else:
            self.wr(a, v)

    def fetch(self):
        v = self.rd((self.pbr << 16) | self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        return self.fetch() | (self.fetch() << 8)

    def fetch24(self):
        return self.fetch16() | (self.fetch() << 16)

    # ---------------- stack ----------------
    def push(self, v):
        self.wr(self.s, v)
        self.s = (self.s - 1) & 0xFFFF
        if self.e:
            self.s = 0x0100 | (self.s & 0xFF)

    def pull(self):
        self.s = (self.s + 1) & 0xFFFF
        if self.e:
            self.s = 0x0100 | (self.s & 0xFF)
        return self.rd(self.s)

    def push16(self, v):
        self.push(v >> 8)
        self.push(v)

    def pull16(self):
        lo = self.pull()
        return lo | (self.pull() << 8)

    # ---------------- flags ----------------
    @property
    def m16(self):
        return not (self.p & M)

    @property
    def x16(self):
        return not (self.p & XF)

    def setp(self, v):
        self.p = v & 0xFF
        if self.e:
            self.p |= M | XF
        if self.p & XF:
            self.x &= 0xFF
            self.y &= 0xFF

    def nz(self, v, wide):
        if wide:
            v &= 0xFFFF
            neg = v & 0x8000
        else:
            v &= 0xFF
            neg = v & 0x80
        self.p = (self.p & ~(N | Z)) | (N if neg else 0) | (Z if v == 0 else 0)

    def flag(self, f, on):
        self.p = (self.p | f) if on else (self.p & ~f)

    def geta(self):
        return self.a if self.m16 else self.a & 0xFF

    def seta(self, v):
        if self.m16:
            self.a = v & 0xFFFF
        else:
            self.a = (self.a & 0xFF00) | (v & 0xFF)

    # ---------------- addressing ----------------
    def ea(self, mode):
        dbr = self.dbr << 16
        if mode == 'dp':
            return (self.d + self.fetch()) & 0xFFFF
        if mode == 'dpx':
            return (self.d + self.fetch() + self.x) & 0xFFFF
        if mode == 'dpy':
            return (self.d + self.fetch() + self.y) & 0xFFFF
        if mode == 'idp':
            p = self.rd16((self.d + self.fetch()) & 0xFFFF)
            return dbr | p
        if mode == 'idpy':
            p = self.rd16((self.d + self.fetch()) & 0xFFFF)
            return ((dbr | p) + self.y) & 0xFFFFFF
        if mode == 'idpx':
            p = self.rd16((self.d + self.fetch() + self.x) & 0xFFFF)
            return dbr | p
        if mode == 'ildp':
            a = (self.d + self.fetch()) & 0xFFFF
            return self.rd16(a) | (self.rd(a + 2) << 16)
        if mode == 'ildpy':
            a = (self.d + self.fetch()) & 0xFFFF
            return ((self.rd16(a) | (self.rd(a + 2) << 16)) + self.y) & 0xFFFFFF
        if mode == 'abs':
            return dbr | self.fetch16()
        if mode == 'absx':
            return ((dbr | self.fetch16()) + self.x) & 0xFFFFFF
        if mode == 'absy':
            return ((dbr | self.fetch16()) + self.y) & 0xFFFFFF
        if mode == 'long':
            return self.fetch24()
        if mode == 'longx':
            return (self.fetch24() + self.x) & 0xFFFFFF
        if mode == 'sr':
            return (self.s + self.fetch()) & 0xFFFF
        if mode == 'isry':
            p = self.rd16((self.s + self.fetch()) & 0xFFFF)
            return ((dbr | p) + self.y) & 0xFFFFFF
        raise Halt('mode ' + mode)

    # ---------------- interrupts ----------------
    def irq(self, vector):
        if self.e:
            raise Halt('IRQ in emulation mode')
        self.push(self.pbr)
        self.push16(self.pc)
        self.push(self.p)
        self.p = (self.p | I) & ~D
        self.pbr = 0
        self.pc = self.rd16(vector)

    # ---------------- execution ----------------
    def step(self):
        self.steps += 1
        if self.pbr == 0 and self.pc in self.hooks:
            self.hooks[self.pc](self)
            return
        op = self.fetch()
        ent = OPS.get(op)
        if ent is None:
            raise Halt('unimplemented opcode %02X at %02X:%04X' % (op, self.pbr, (self.pc - 1) & 0xFFFF))
        ent[0](self, ent[1])

    def rtl(self):
        self.pc = (self.pull16() + 1) & 0xFFFF
        self.pbr = self.pull()


# ---------------------------------------------------------------- ops
def _imm(cpu, wide):
    return cpu.fetch16() if wide else cpu.fetch()


def _operand(cpu, mode, wide):
    if mode == 'imm':
        return _imm(cpu, wide)
    return cpu.rdn(cpu.ea(mode), wide)


def op_lda(cpu, mode):
    v = _operand(cpu, mode, cpu.m16)
    cpu.seta(v)
    cpu.nz(v, cpu.m16)


def op_ldx(cpu, mode):
    v = _operand(cpu, mode, cpu.x16)
    cpu.x = v
    cpu.nz(v, cpu.x16)


def op_ldy(cpu, mode):
    v = _operand(cpu, mode, cpu.x16)
    cpu.y = v
    cpu.nz(v, cpu.x16)


def op_sta(cpu, mode):
    cpu.wrn(cpu.ea(mode), cpu.geta(), cpu.m16)


def op_stx(cpu, mode):
    cpu.wrn(cpu.ea(mode), cpu.x, cpu.x16)


def op_sty(cpu, mode):
    cpu.wrn(cpu.ea(mode), cpu.y, cpu.x16)


def op_stz(cpu, mode):
    cpu.wrn(cpu.ea(mode), 0, cpu.m16)


def _logic(fn):
    def op(cpu, mode):
        v = fn(cpu.geta(), _operand(cpu, mode, cpu.m16))
        cpu.seta(v)
        cpu.nz(v, cpu.m16)
    return op


op_and = _logic(lambda a, b: a & b)
op_ora = _logic(lambda a, b: a | b)
op_eor = _logic(lambda a, b: a ^ b)


def _adc(cpu, b):
    if cpu.p & D:
        raise Halt('decimal mode not supported')
    wide = cpu.m16
    a = cpu.geta()
    mask, sign = (0xFFFF, 0x8000) if wide else (0xFF, 0x80)
    r = a + b + (cpu.p & C)
    cpu.flag(C, r > mask)
    cpu.flag(V, (~(a ^ b) & (a ^ r)) & sign)
    cpu.seta(r)
    cpu.nz(r, wide)


def op_adc(cpu, mode):
    _adc(cpu, _operand(cpu, mode, cpu.m16))


def op_sbc(cpu, mode):
    b = _operand(cpu, mode, cpu.m16)
    _adc(cpu, b ^ (0xFFFF if cpu.m16 else 0xFF))


def _cmp(cpu, reg, b, wide):
    mask = 0xFFFF if wide else 0xFF
    reg &= mask
    r = (reg - b) & mask
    cpu.flag(C, reg >= b)
    cpu.nz(r, wide)


def op_cmp(cpu, mode):
    _cmp(cpu, cpu.geta(), _operand(cpu, mode, cpu.m16), cpu.m16)


def op_cpx(cpu, mode):
    _cmp(cpu, cpu.x, _operand(cpu, mode, cpu.x16), cpu.x16)


def op_cpy(cpu, mode):
    _cmp(cpu, cpu.y, _operand(cpu, mode, cpu.x16), cpu.x16)


def op_bit(cpu, mode):
    wide = cpu.m16
    v = _operand(cpu, mode, wide)
    cpu.flag(Z, (cpu.geta() & v) == 0)
    if mode != 'imm':
        sign = 0x8000 if wide else 0x80
        cpu.flag(N, v & sign)
        cpu.flag(V, v & (sign >> 1))


def op_tsb(cpu, mode):
    a = cpu.ea(mode)
    v = cpu.rdn(a, cpu.m16)
    cpu.flag(Z, (v & cpu.geta()) == 0)
    cpu.wrn(a, v | cpu.geta(), cpu.m16)


def op_trb(cpu, mode):
    a = cpu.ea(mode)
    v = cpu.rdn(a, cpu.m16)
    cpu.flag(Z, (v & cpu.geta()) == 0)
    cpu.wrn(a, v & ~cpu.geta(), cpu.m16)


def _rmw(fn):
    def op(cpu, mode):
        wide = cpu.m16
        if mode == 'acc':
            r = fn(cpu, cpu.geta(), wide)
            cpu.seta(r)
        else:
            a = cpu.ea(mode)
            r = fn(cpu, cpu.rdn(a, wide), wide)
            cpu.wrn(a, r, wide)
        cpu.nz(r, wide)
    return op


def _sh(kind):
    def f(cpu, v, wide):
        mask, sign = (0xFFFF, 0x8000) if wide else (0xFF, 0x80)
        c = cpu.p & C
        if kind == 'asl':
            cpu.flag(C, v & sign)
            return (v << 1) & mask
        if kind == 'rol':
            cpu.flag(C, v & sign)
            return ((v << 1) | c) & mask
        if kind == 'lsr':
            cpu.flag(C, v & 1)
            return v >> 1
        if kind == 'ror':
            cpu.flag(C, v & 1)
            return (v >> 1) | (sign if c else 0)
    return f


op_asl = _rmw(_sh('asl'))
op_rol = _rmw(_sh('rol'))
op_lsr = _rmw(_sh('lsr'))
op_ror = _rmw(_sh('ror'))
op_inc = _rmw(lambda cpu, v, w: (v + 1) & (0xFFFF if w else 0xFF))
op_dec = _rmw(lambda cpu, v, w: (v - 1) & (0xFFFF if w else 0xFF))


def _idx(reg, delta):
    def op(cpu, mode):
        mask = 0xFFFF if cpu.x16 else 0xFF
        v = (getattr(cpu, reg) + delta) & mask
        setattr(cpu, reg, v)
        cpu.nz(v, cpu.x16)
    return op


def op_branch(cond):
    def op(cpu, mode):
        off = cpu.fetch()
        if off & 0x80:
            off -= 256
        if cond(cpu.p):
            cpu.pc = (cpu.pc + off) & 0xFFFF
    return op


def op_brl(cpu, mode):
    off = cpu.fetch16()
    if off & 0x8000:
        off -= 0x10000
    cpu.pc = (cpu.pc + off) & 0xFFFF


def op_jmp(cpu, mode):
    if mode == 'abs':
        cpu.pc = cpu.fetch16()
    elif mode == 'long':
        t = cpu.fetch24()
        cpu.pc, cpu.pbr = t & 0xFFFF, t >> 16
    elif mode == 'ind':
        cpu.pc = cpu.rd16(cpu.fetch16())
    elif mode == 'indx':
        a = (cpu.fetch16() + cpu.x) & 0xFFFF
        cpu.pc = cpu.rd16((cpu.pbr << 16) | a)
    elif mode == 'indl':
        a = cpu.fetch16()
        cpu.pc, cpu.pbr = cpu.rd16(a), cpu.rd(a + 2)


def op_jsr(cpu, mode):
    if mode == 'abs':
        t = cpu.fetch16()
        cpu.push16((cpu.pc - 1) & 0xFFFF)
        cpu.pc = t
    elif mode == 'long':
        t = cpu.fetch24()
        cpu.push(cpu.pbr)
        cpu.push16((cpu.pc - 1) & 0xFFFF)
        cpu.pc, cpu.pbr = t & 0xFFFF, t >> 16
    elif mode == 'indx':
        a = (cpu.fetch16() + cpu.x) & 0xFFFF
        t = cpu.rd16((cpu.pbr << 16) | a)
        cpu.push16((cpu.pc - 1) & 0xFFFF)
        cpu.pc = t


def op_rts(cpu, mode):
    cpu.pc = (cpu.pull16() + 1) & 0xFFFF


def op_rtl(cpu, mode):
    cpu.rtl()


def op_rti(cpu, mode):
    cpu.setp(cpu.pull())
    cpu.pc = cpu.pull16()
    if not cpu.e:
        cpu.pbr = cpu.pull()


def op_brk(cpu, mode):
    raise Halt('BRK')


def op_push(kind):
    def op(cpu, mode):
        if kind == 'a':
            (cpu.push16 if cpu.m16 else cpu.push)(cpu.geta())
        elif kind in 'xy':
            v = getattr(cpu, kind)
            (cpu.push16 if cpu.x16 else cpu.push)(v)
        elif kind == 'p':
            cpu.push(cpu.p)
        elif kind == 'b':
            cpu.push(cpu.dbr)
        elif kind == 'd':
            cpu.push16(cpu.d)
        elif kind == 'k':
            cpu.push(cpu.pbr)
    return op


def op_pull(kind):
    def op(cpu, mode):
        if kind == 'a':
            v = cpu.pull16() if cpu.m16 else cpu.pull()
            cpu.seta(v)
            cpu.nz(v, cpu.m16)
        elif kind in 'xy':
            v = cpu.pull16() if cpu.x16 else cpu.pull()
            setattr(cpu, kind, v)
            cpu.nz(v, cpu.x16)
        elif kind == 'p':
            cpu.setp(cpu.pull())
        elif kind == 'b':
            cpu.dbr = cpu.pull()
            cpu.nz(cpu.dbr, False)
        elif kind == 'd':
            cpu.d = cpu.pull16()
            cpu.nz(cpu.d, True)
    return op


def op_pea(cpu, mode):
    cpu.push16(cpu.fetch16())


def op_rep(cpu, mode):
    cpu.setp(cpu.p & ~cpu.fetch())


def op_sep(cpu, mode):
    cpu.setp(cpu.p | cpu.fetch())


def op_flag(f, on):
    def op(cpu, mode):
        if f == D and on:
            raise Halt('SED not supported')
        cpu.flag(f, on)
    return op


def op_xce(cpu, mode):
    c = cpu.p & C
    cpu.flag(C, cpu.e)
    cpu.e = 1 if c else 0
    if cpu.e:
        cpu.setp(cpu.p | M | XF)
        cpu.s = 0x0100 | (cpu.s & 0xFF)
    else:
        cpu.setp(cpu.p | M | XF)


def op_xfer(src, dst):
    def op(cpu, mode):
        if dst in ('x', 'y'):
            wide = cpu.x16
            v = (cpu.a if src == 'a' else getattr(cpu, src)) & (0xFFFF if wide else 0xFF)
            if src == 's':
                v = cpu.s & (0xFFFF if wide else 0xFF)
            setattr(cpu, dst, v)
            cpu.nz(v, wide)
        elif dst == 'a':
            v = getattr(cpu, src)
            cpu.seta(v)
            cpu.nz(v, cpu.m16)
        elif dst == 'd':
            cpu.d = cpu.a
            cpu.nz(cpu.d, True)
        elif dst == 'c':           # TDC / TSC
            cpu.a = getattr(cpu, src) & 0xFFFF
            cpu.nz(cpu.a, True)
        elif dst == 's':
            cpu.s = (cpu.a if src == 'a' else cpu.x) & 0xFFFF
            if cpu.e:
                cpu.s = 0x0100 | (cpu.s & 0xFF)
    return op


def op_xba(cpu, mode):
    cpu.a = ((cpu.a >> 8) | (cpu.a << 8)) & 0xFFFF
    cpu.nz(cpu.a & 0xFF, False)


def op_nop(cpu, mode):
    pass


OPS = {}


def _reg(table, fn):
    for op, mode in table.items():
        OPS[op] = (fn, mode)


_reg({0xA9: 'imm', 0xA5: 'dp', 0xB5: 'dpx', 0xAD: 'abs', 0xBD: 'absx', 0xB9: 'absy',
      0xAF: 'long', 0xBF: 'longx', 0xB2: 'idp', 0xB1: 'idpy', 0xA1: 'idpx', 0xA7: 'ildp',
      0xB7: 'ildpy', 0xA3: 'sr', 0xB3: 'isry'}, op_lda)
_reg({0xA2: 'imm', 0xA6: 'dp', 0xB6: 'dpy', 0xAE: 'abs', 0xBE: 'absy'}, op_ldx)
_reg({0xA0: 'imm', 0xA4: 'dp', 0xB4: 'dpx', 0xAC: 'abs', 0xBC: 'absx'}, op_ldy)
_reg({0x85: 'dp', 0x95: 'dpx', 0x8D: 'abs', 0x9D: 'absx', 0x99: 'absy', 0x8F: 'long',
      0x9F: 'longx', 0x92: 'idp', 0x91: 'idpy', 0x81: 'idpx', 0x87: 'ildp', 0x97: 'ildpy',
      0x83: 'sr', 0x93: 'isry'}, op_sta)
_reg({0x86: 'dp', 0x96: 'dpy', 0x8E: 'abs'}, op_stx)
_reg({0x84: 'dp', 0x94: 'dpx', 0x8C: 'abs'}, op_sty)
_reg({0x64: 'dp', 0x74: 'dpx', 0x9C: 'abs', 0x9E: 'absx'}, op_stz)
for base, fn in ((0x20, op_and), (0x00, op_ora), (0x40, op_eor), (0x60, op_adc),
                 (0xE0, op_sbc), (0xC0, op_cmp)):
    _reg({base + 0x09: 'imm', base + 0x05: 'dp', base + 0x15: 'dpx', base + 0x0D: 'abs',
          base + 0x1D: 'absx', base + 0x19: 'absy', base + 0x0F: 'long', base + 0x1F: 'longx',
          base + 0x12: 'idp', base + 0x11: 'idpy', base + 0x01: 'idpx', base + 0x07: 'ildp',
          base + 0x17: 'ildpy', base + 0x03: 'sr', base + 0x13: 'isry'}, fn)
_reg({0xE0: 'imm', 0xE4: 'dp', 0xEC: 'abs'}, op_cpx)
_reg({0xC0: 'imm', 0xC4: 'dp', 0xCC: 'abs'}, op_cpy)
_reg({0x89: 'imm', 0x24: 'dp', 0x34: 'dpx', 0x2C: 'abs', 0x3C: 'absx'}, op_bit)
_reg({0x04: 'dp', 0x0C: 'abs'}, op_tsb)
_reg({0x14: 'dp', 0x1C: 'abs'}, op_trb)
for base, fn in ((0x00, op_asl), (0x20, op_rol), (0x40, op_lsr), (0x60, op_ror)):
    _reg({base + 0x0A: 'acc', base + 0x06: 'dp', base + 0x16: 'dpx', base + 0x0E: 'abs',
          base + 0x1E: 'absx'}, fn)
_reg({0x1A: 'acc', 0xE6: 'dp', 0xF6: 'dpx', 0xEE: 'abs', 0xFE: 'absx'}, op_inc)
_reg({0x3A: 'acc', 0xC6: 'dp', 0xD6: 'dpx', 0xCE: 'abs', 0xDE: 'absx'}, op_dec)
OPS[0xE8] = (_idx('x', 1), None)
OPS[0xCA] = (_idx('x', -1), None)
OPS[0xC8] = (_idx('y', 1), None)
OPS[0x88] = (_idx('y', -1), None)
for op, cond in ((0x10, lambda p: not p & N), (0x30, lambda p: p & N),
                 (0x50, lambda p: not p & V), (0x70, lambda p: p & V),
                 (0x90, lambda p: not p & C), (0xB0, lambda p: p & C),
                 (0xD0, lambda p: not p & Z), (0xF0, lambda p: p & Z),
                 (0x80, lambda p: True)):
    OPS[op] = (op_branch(cond), None)
OPS[0x82] = (op_brl, None)
_reg({0x4C: 'abs', 0x5C: 'long', 0x6C: 'ind', 0x7C: 'indx', 0xDC: 'indl'}, op_jmp)
_reg({0x20: 'abs', 0x22: 'long', 0xFC: 'indx'}, op_jsr)
OPS[0x60] = (op_rts, None)
OPS[0x6B] = (op_rtl, None)
OPS[0x40] = (op_rti, None)
OPS[0x00] = (op_brk, None)
for op, k in ((0x48, 'a'), (0xDA, 'x'), (0x5A, 'y'), (0x08, 'p'), (0x8B, 'b'), (0x0B, 'd'),
              (0x4B, 'k')):
    OPS[op] = (op_push(k), None)
for op, k in ((0x68, 'a'), (0xFA, 'x'), (0x7A, 'y'), (0x28, 'p'), (0xAB, 'b'), (0x2B, 'd')):
    OPS[op] = (op_pull(k), None)
OPS[0xF4] = (op_pea, None)
OPS[0xC2] = (op_rep, None)
OPS[0xE2] = (op_sep, None)
for op, f, on in ((0x18, C, 0), (0x38, C, 1), (0x58, I, 0), (0x78, I, 1), (0xD8, D, 0),
                  (0xF8, D, 1), (0xB8, V, 0)):
    OPS[op] = (op_flag(f, on), None)
OPS[0xFB] = (op_xce, None)
for op, s, d in ((0xAA, 'a', 'x'), (0xA8, 'a', 'y'), (0x8A, 'x', 'a'), (0x98, 'y', 'a'),
                 (0x9B, 'x', 'y'), (0xBB, 'y', 'x'), (0xBA, 's', 'x'), (0x9A, 'x', 's'),
                 (0x5B, 'a', 'd'), (0x7B, 'd', 'c'), (0x1B, 'a', 's'), (0x3B, 's', 'c')):
    OPS[op] = (op_xfer(s, d), None)
OPS[0xEB] = (op_xba, None)
OPS[0xEA] = (op_nop, None)


# ---------------------------------------------------------------- board
class Board:
    """CPU plus monitor stubs, Timer 7, and a UART0 byte source."""

    def __init__(self, image, t7_period=230, byte_period=960):
        self.cpu = cpu = CPU()
        for addr, data in image:
            cpu.mem[addr:addr + len(data)] = data
        # Monitor state at the time a user program starts
        cpu.mem[0x011C:0x0120] = bytes([0x5C, 0xB0, 0xE0, 0x00])   # JML RESET
        cpu.mem[0xFF8E:0xFF90] = bytes([0x1C, 0x01])               # native T7 vector
        cpu.mem[TCR] = 0xB0
        cpu.mem[TER] = 0x1E
        cpu.mem[UIER] = 0xC0
        cpu.mem[0xDFB5] = 2
        cpu.hooks[PUT_CHR] = self._put_chr
        cpu.hooks[GET_BYTE_FROM_PC] = self._get_byte
        self.t7_period = t7_period
        self.byte_period = byte_period
        self.rx = bytearray()
        self.keys = []           # delivered after all serial input is processed
        self.early_keys = []     # delivered on the first console polls
        self.t7_count = 0
        self.byte_count = 0
        self.isr_count = 0
        self.overruns = 0

    def _put_chr(self, cpu):
        cpu.out.append(cpu.a & 0xFF)
        cpu.rtl()

    def _get_byte(self, cpu):
        # keys are only delivered once all serial input has been received
        # and the ring buffer has been drained
        if self.early_keys:
            k = self.early_keys.pop(0)
            cpu.a = (cpu.a & 0xFF00) | k
            cpu.flag(C, 0)
        elif self.keys and not self.rx and self._ring_empty():
            k = self.keys.pop(0)
            cpu.a = (cpu.a & 0xFF00) | k
            cpu.flag(C, 0)
        else:
            cpu.flag(C, 1)
        cpu.rtl()

    def _ring_empty(self):
        m = self.cpu.mem
        return m[0x5B00:0x5B02] == m[0x5B02:0x5B04]

    def _hw(self):
        cpu = self.cpu
        m = cpu.mem
        if m[TER] & 0x80:
            self.t7_count += 1
            if self.t7_count >= self.t7_period:
                self.t7_count = 0
                m[TIFR] |= 0x80
        if self.rx and (m[ACSR0] & 0x20):
            self.byte_count += 1
            if self.byte_count >= self.byte_period:
                self.byte_count = 0
                if m[UIFR] & 0x01:
                    m[ACSR0] |= 0x80
                    self.overruns += 1
                m[ARTD0] = self.rx.pop(0)
                m[UIFR] |= 0x01
        if not (cpu.p & I):
            if m[UIFR] & m[UIER] & 0x03:
                raise Halt('UART0 interrupt enabled - would enter the ROM handler')
            if m[TIFR] & m[TIER] & 0x80:
                self.isr_count += 1
                cpu.irq(0xFF8E)

    def run(self, start=0x2000, max_steps=50_000_000):
        cpu = self.cpu
        # like the monitor's J command: JSL to the program
        cpu.push(0)
        cpu.push16(0x1234)
        cpu.pc, cpu.pbr = start, 0
        reason = None
        try:
            while cpu.steps < max_steps:
                self._hw()
                cpu.step()
            reason = 'step limit'
        except Halt as h:
            reason = str(h)
        return reason


def load_s28(path):
    chunks = []
    for line in open(path):
        line = line.strip()
        if not line.startswith('S2'):
            continue
        n = int(line[2:4], 16)
        addr = int(line[4:10], 16)
        data = bytes.fromhex(line[10:10 + (n - 4) * 2])
        chunks.append((addr, data))
    return chunks
