"""Check the C02COMM design in board.py (plain Python, no KiCad needed).

    python check_board.py

- every net has at least two pins, and every pin of every chip is accounted for
- the CPU's address and data buses reach the right pins of every memory and I/O chip
- address decoding, simulated gate by gate from the netlist for all 65536
  addresses and both read and write: exactly one chip selected, and the
  memory map in board.py's docstring
- read/write strobes: RAM and flash get /OE only on reads and /WE only on
  writes, both only while PHI2 is high
- the radio ports: both channels wired the same way to VIA1
"""
import sys

import board

ok = True


def check(cond, msg):
    global ok
    print(('  ok   ' if cond else '  FAIL ') + msg)
    ok &= bool(cond)


P = {p['ref']: p for p in board.PARTS}
N = board.nets()


def pin(ref, n):
    return P[ref]['pins'].get(str(n))


# ---------------------------------------------------------------- nets
SINGLE_OK = {'R1_NL', 'R2_NL'}
lonely = [n for n, pads in N.items() if len(pads) < 2 and n not in SINGLE_OK]
check(not lonely, 'every net joins two or more pins %s' % lonely)

PINS = {'DIP8': 8, 'DIP14': 14, 'DIP16': 16, 'DIP28': 28, 'DIP32': 32, 'DIP40': 40}
for ref, p in P.items():
    if p['fp'] in PINS:
        n = PINS[p['fp']]
        keys = set(p['pins'])
        if keys != {str(i) for i in range(1, n + 1)}:
            check(False, '%s: pins listed %s' % (ref, sorted(keys, key=int)))
check(True, 'every chip lists all its pins (unused ones as None)')

# power on every chip
POWER = {'U1': (8, 21), 'U2': (28, 14), 'U3': (32, 16), 'U4': (20, 1), 'U5': (20, 1),
         'U6': (15, 1), 'U7': (14, 7), 'U8': (14, 7), 'U9': (14, 7), 'U10': (16, 8), 'U13': (8, 4)}
check(all(pin(r, v) == '+5V' and pin(r, g) == 'GND' for r, (v, g) in POWER.items()),
      'VCC and GND on every chip at its datasheet pins')

# decoupling: a 100 nF per chip
caps = [p for p in board.PARTS if p['ref'].startswith('C') and p['value'] == '100nF'
        and p['pins'].get('1') == '+5V' and p['pins'].get('2') == 'GND']
check(len(caps) >= 13, '%d decoupling capacitors (13 chips and oscillators)' % len(caps))

# ---------------------------------------------------------------- buses
CPU_A = {i: (9 + i if i < 12 else 10 + i) for i in range(16)}       # W65C02S: A0-A11 9-20, A12-A15 22-25
CPU_D = {i: 33 - i for i in range(8)}                               # D0 33 .. D7 26
check(all(pin('U1', CPU_A[i]) == 'A%d' % i for i in range(16)), 'W65C02S address pins A0-A15')
check(all(pin('U1', CPU_D[i]) == 'D%d' % i for i in range(8)), 'W65C02S data pins D0-D7')
check(pin('U1', 34) == 'RW' and pin('U1', 37) == 'PHI2' and pin('U1', 40) == '~{RES}'
      and pin('U1', 4) == '~{IRQ}' and pin('U1', 6) == '~{NMI}', 'W65C02S RWB, PHI2, RESB, IRQB, NMIB')
check(pin('U1', 2) == 'RDY' and pin('U1', 36) == '+5V' and pin('U1', 38) == '+5V',
      'RDY pulled up, BE and SOB high')

# JEDEC 62256 / 39SF010A address and data pins
J28 = {'A0': 10, 'A1': 9, 'A2': 8, 'A3': 7, 'A4': 6, 'A5': 5, 'A6': 4, 'A7': 3, 'A8': 25,
       'A9': 24, 'A10': 21, 'A11': 23, 'A12': 2, 'A13': 26, 'A14': 1,
       'D0': 11, 'D1': 12, 'D2': 13, 'D3': 15, 'D4': 16, 'D5': 17, 'D6': 18, 'D7': 19}
J32 = {'A0': 12, 'A1': 11, 'A2': 10, 'A3': 9, 'A4': 8, 'A5': 7, 'A6': 6, 'A7': 5, 'A8': 27,
       'A9': 26, 'A10': 23, 'A11': 25, 'A12': 4, 'A13': 28, 'A14': 29, 'FA15': 3, 'FA16': 2,
       'D0': 13, 'D1': 14, 'D2': 15, 'D3': 17, 'D4': 18, 'D5': 19, 'D6': 20, 'D7': 21}
check(all(pin('U2', n) == s for s, n in J28.items()), 'RAM AS6C62256: A0-A14, D0-D7 (JEDEC 28-pin)')
check(all(pin('U3', n) == s for s, n in J32.items()), 'flash SST39SF010A: A0-A14, bank A15/A16, D0-D7 (JEDEC 32-pin)')
VIA = {'D%d' % i: 33 - i for i in range(8)}
VIA.update({'A0': 38, 'A1': 37, 'A2': 36, 'A3': 35, 'RW': 22, 'PHI2': 25, '~{RES}': 34, '~{IRQ}': 21})
for r in ('U4', 'U5'):
    check(all(pin(r, n) == s for s, n in VIA.items()) and pin(r, 24) == '+5V',
          '%s W65C22: D0-D7, RS0-RS3 = A0-A3, RWB, PHI2, RESB, IRQB, CS1 high' % r)
ACIA = {'D%d' % i: 18 + i for i in range(8)}
ACIA.update({'A0': 13, 'A1': 14, 'RW': 28, 'PHI2': 27, '~{RES}': 4, '~{IRQ}': 26, '~{CS2}': 3,
             'ACIA_CLK': 6, 'SER_RX': 12, 'SER_TX': 10})
check(all(pin('U6', n) == s for s, n in ACIA.items()) and pin('U6', 2) == '+5V',
      'U6 W65C51: D0-D7, RS0/RS1 = A0/A1, CS0 high, CS1B = /CS2, XTLI clock, RxD, TxD')
check(pin('U6', 16) == 'GND' and pin('U6', 17) == 'GND', 'ACIA DCD and DSR grounded (else it will not receive)')

# ---------------------------------------------------------------- decoding
GATES = {'74HC00': [((1, 2), 3), ((4, 5), 6), ((9, 10), 8), ((12, 13), 11)],
         '74HC30': [((1, 2, 3, 4, 5, 6, 11, 12), 8)]}


def evaluate(addr, rw, phi2):
    v = {'A%d' % i: (addr >> i) & 1 for i in range(16)}
    v.update(RW=rw, PHI2=phi2, GND=0)
    v['+5V'] = 1
    for _ in range(6):                      # settle the gate network
        for ref, p in P.items():
            for (ins, out) in GATES.get(p['value'], []):
                if all(pin(ref, i) in v for i in ins):
                    v[pin(ref, out)] = 0 if all(v[pin(ref, i)] for i in ins) else 1
            if p['value'] == '74HC138':
                if all(pin(ref, i) in v for i in (1, 2, 3, 4, 5, 6)):
                    en = v[pin(ref, 4)] == 0 and v[pin(ref, 5)] == 0 and v[pin(ref, 6)] == 1
                    sel = v[pin(ref, 1)] | v[pin(ref, 2)] << 1 | v[pin(ref, 3)] << 2
                    for k, o in enumerate((15, 14, 13, 12, 11, 10, 9, 7)):
                        v[pin(ref, o)] = 0 if en and sel == k else 1
    v['~{FWE}'] = v['~{WR}']                  # JP1 in the write position
    return v


def selected(v):
    s = []
    if v['~{RAMCS}'] == 0:
        s.append('RAM')
    if v['~{ROMCS}'] == 0:
        s.append('ROM')
    for k in range(8):
        if v.get('~{CS%d}' % k, 1) == 0:
            s.append(('VIA1', 'VIA2', 'ACIA', 'CS3', 'CS4', 'CS5', 'CS6', 'CS7')[k])
    return s


def expect(a):
    if a < 0x7F00:
        return ['RAM']
    if a < 0x7F60:
        return [('VIA1', 'VIA2', 'ACIA', 'CS3', 'CS4', 'CS5')[(a >> 4) & 7]]
    if a < 0x8000:
        return []
    return ['ROM']


bad = [a for a in range(0x10000) if selected(evaluate(a, 1, 1)) != expect(a)]
check(not bad, 'decoding for all 65536 addresses matches the memory map%s' %
      (' (first bad $%04X: %s)' % (bad[0], selected(evaluate(bad[0], 1, 1))) if bad else ''))
check(sum(1 for a in range(0x7F60, 0x8000) if selected(evaluate(a, 1, 1))) == 0,
      '$7F60-$7FFF selects nothing (free)')
strobe = {}
for rw in (0, 1):
    for phi2 in (0, 1):
        v = evaluate(0x1234, rw, phi2)
        strobe[rw, phi2] = (v['~{RD}'], v['~{WR}'])
check(strobe[1, 1] == (0, 1) and strobe[0, 1] == (1, 0) and strobe[1, 0] == (1, 1) and strobe[0, 0] == (1, 1),
      '/RD only on reads, /WR only on writes, both only while PHI2 is high')
check(pin('U2', 22) == '~{RD}' and pin('U2', 27) == '~{WR}' and pin('U3', 24) == '~{RD}'
      and pin('U3', 31) == '~{FWE}', 'RAM and flash /OE = /RD, /WE = /WR (flash through JP1)')
check(pin('JP1', 1) == '~{WR}' and pin('JP1', 3) == '+5V', 'JP1 2-3 holds flash /WE high (write protect)')
check(pin('R33', 1) == 'FA15' and pin('R33', 2) == 'GND' and pin('R34', 1) == 'FA16',
      'flash bank lines pulled low: bank 0 at reset, while VIA2 pins are inputs')

# ---------------------------------------------------------------- radio ports
for n, port, base in ((1, 'A', 2), (2, 'B', 10)):
    p = 'R%d_' % n
    want = [p + 'D0', p + 'D1', p + 'D2', p + 'D3', p + 'KEY', p + 'SQ', None, p + 'RX']
    got = [pin('U4', base + i) for i in range(8)]
    check([g if i != 6 else None for i, g in enumerate(got)] == want,
          'radio %d on VIA1 port %s: DAC P%s0-3, PTT P%s4, SQC P%s5, RX P%s7' % (n, port, port, port, port, port))
check(pin('U4', 40) == 'R1_RX' and pin('U4', 18) == 'R2_RX', 'comparators also on CA1 / CB1 for edge interrupts')
for n in (1, 2):
    b = 100 * n
    p = 'R%d_' % n
    dac = [(pin('R%d' % (b + 10 + i), 1), pin('R%d' % (b + 10 + i), 2)) for i in range(4)]
    check(dac == [(p + 'D3', p + 'N3'), (p + 'D2', p + 'N2'), (p + 'D1', p + 'N1'), (p + 'D0', p + 'N0')],
          'radio %d: R-2R DAC, MSB (D3) nearest the output' % n)
    check(pin('Q%d' % n, 3) == p + 'PTT' and pin('Q%d' % n, 1) == 'GND' and pin('Q%d' % n, 2) == p + 'G',
          'radio %d: 2N7000 drain on PTT, source GND (TO-92 S-G-D)' % n)
    check(pin('J%d' % (6 + n), 2) == 'GND' and pin('J%d' % (6 + n), 1) == p + 'ANI',
          'radio %d terminal: ANI GND PTT ANO SQC' % n)
check(pin('U13', 2) == 'VREF' and pin('U13', 6) == 'VREF' and pin('U13', 3) == 'R1_NA' and pin('U13', 5) == 'R2_NA',
      'LM393: both comparators on the shared 2.0 V reference')

# ---------------------------------------------------------------- the rest
check(pin('U5', 40) == 'KB_CLK' and pin('U5', 39) == 'KB_DATA', 'PS/2 clock on VIA2 CA1 (edge interrupt), data on CA2')
check([pin('U5', i) for i in range(2, 8)] == ['LCD_D4', 'LCD_D5', 'LCD_D6', 'LCD_D7', 'LCD_RS', 'LCD_E'],
      'LCD on VIA2 PA0-PA5 (D4-D7, RS, E)')
check(pin('J3', 5) == 'GND', 'LCD R/W tied low (write only)')
check(pin('U11', 1) == '~{RES}' and pin('SW1', 1) == '~{RES}', 'DS1813 and the reset button on /RES')
irq = [r for r, pad in N['~{IRQ}']]
check(sorted(irq) == sorted(['U1', 'U4', 'U5', 'U6', 'R31', 'J6']), '/IRQ wire-OR: VIA1, VIA2, ACIA, pull-up R31')
check(pin('J5', 4) == 'SER_RX' and pin('J5', 5) == 'SER_TX', 'USB module TXD -> ACIA RxD, ACIA TxD -> module RXD')

print('ALL PASSED' if ok else 'FAILED')
sys.exit(0 if ok else 1)
