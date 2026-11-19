"""Write c02comm.kicad_sch from board.py: every part, every pin labelled with its net.

    python mk_sch.py

Chips are drawn by their DIP pinout (pin 1 top left, as on the board), with
a net label on every pin. KiCad joins equal labels, so the schematic is the
same netlist as the board. Unused pins get a no-connect flag. Parts are
grouped by function on one A2 sheet.
"""
import os
import uuid

import board

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'c02comm.kicad_sch')
G = 2.54
NS = uuid.UUID('6f3f0c9e-1c55-4a5e-9a64-0c02c0de0001')
ROOT = str(uuid.uuid5(NS, 'root'))


def uid(*k):
    return str(uuid.uuid5(NS, '/'.join(map(str, k))))


# ------------------------------------------------------------ pin names
def names(*seq):
    return {i + 1: n for i, n in enumerate(seq)}


PINNAMES = {
    'W65C02S': names('VPB', 'RDY', 'PHI1O', 'IRQB', 'MLB', 'NMIB', 'SYNC', 'VDD',
                     *['A%d' % i for i in range(12)], 'VSS', 'A12', 'A13', 'A14', 'A15',
                     *['D%d' % i for i in range(7, -1, -1)], 'RWB', 'NC', 'BE', 'PHI2', 'SOB',
                     'PHI2O', 'RESB'),
    'RAM': names('A14', 'A12', 'A7', 'A6', 'A5', 'A4', 'A3', 'A2', 'A1', 'A0', 'DQ0', 'DQ1',
                 'DQ2', 'VSS', 'DQ3', 'DQ4', 'DQ5', 'DQ6', 'DQ7', '~{CE}', 'A10', '~{OE}', 'A11',
                 'A9', 'A8', 'A13', '~{WE}', 'VCC'),
    'FLASH': names('NC', 'A16', 'A15', 'A12', 'A7', 'A6', 'A5', 'A4', 'A3', 'A2', 'A1', 'A0',
                   'DQ0', 'DQ1', 'DQ2', 'VSS', 'DQ3', 'DQ4', 'DQ5', 'DQ6', 'DQ7', '~{CE}', 'A10',
                   '~{OE}', 'A11', 'A9', 'A8', 'A13', 'A14', 'NC', '~{WE}', 'VDD'),
    'VIA': names('VSS', *['PA%d' % i for i in range(8)], *['PB%d' % i for i in range(8)], 'CB1',
                 'CB2', 'VDD', 'IRQB', 'RWB', 'CS2B', 'CS1', 'PHI2', *['D%d' % i for i in range(7, -1, -1)],
                 'RESB', 'RS3', 'RS2', 'RS1', 'RS0', 'CA2', 'CA1'),
    'ACIA': names('VSS', 'CS0', 'CS1B', 'RESB', 'RXC', 'XTLI', 'XTLO', 'RTSB', 'CTSB', 'TXD',
                  'DTRB', 'RXD', 'RS0', 'RS1', 'VDD', 'DCDB', 'DSRB', *['D%d' % i for i in range(8)],
                  'IRQB', 'PHI2', 'RWB'),
    '74HC00': names('1A', '1B', '1Y', '2A', '2B', '2Y', 'GND', '3Y', '3A', '3B', '4Y', '4A', '4B', 'VCC'),
    '74HC30': names('A', 'B', 'C', 'D', 'E', 'F', 'GND', 'Y', 'NC', 'NC', 'G', 'H', 'NC', 'VCC'),
    '74HC138': names('A0', 'A1', 'A2', '~{E1}', '~{E2}', 'E3', 'Y7', 'GND', 'Y6', 'Y5', 'Y4', 'Y3',
                     'Y2', 'Y1', 'Y0', 'VCC'),
    'LM393': names('OUTA', '-INA', '+INA', 'GND', '+INB', '-INB', 'OUTB', 'VCC'),
    'OSC': {1: 'EN', 4: 'GND', 5: 'OUT', 8: 'VCC'},
    'DS1813': {1: 'RST', 2: 'VCC', 3: 'GND'},
    'LM7805': {1: 'IN', 2: 'GND', 3: 'OUT'},
    '2N7000': {1: 'S', 2: 'G', 3: 'D'},
    'POT': {1: '1', 2: 'W', 3: '3'},
    'RADIO': names('ANI', 'GND', 'PTT', 'ANO', 'SQC'),
    'LCD': names('VSS', 'VDD', 'V0', 'RS', 'RW', 'E', 'D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'A', 'K'),
    'PS2': names('VCC', 'GND', 'CLK', 'DATA'),
    'FTDI': names('GND', 'CTS', 'VCC', 'TXD', 'RXD', 'RTS'),
    'PWR': names('V+', 'GND'),
}


def kind(p):
    """symbol name, pin names, style ('dip', 'side', 'two')"""
    v, fp, ref = p['value'], p['fp'], p['ref']
    if v.startswith('W65C02'):
        return 'W65C02S', PINNAMES['W65C02S'], 'dip'
    if v.startswith('AS6C'):
        return 'AS6C62256', PINNAMES['RAM'], 'dip'
    if v.startswith('SST39'):
        return 'SST39SF010A', PINNAMES['FLASH'], 'dip'
    if v.startswith('W65C22'):
        return 'W65C22N', PINNAMES['VIA'], 'dip'
    if v.startswith('W65C51'):
        return 'W65C51N', PINNAMES['ACIA'], 'dip'
    if v in ('74HC00', '74HC30', '74HC138', 'LM393'):
        return v, PINNAMES[v], 'dip'
    if fp == 'OSC':
        return 'OSC', PINNAMES['OSC'], 'side'
    if v.startswith('DS1813'):
        return 'DS1813', PINNAMES['DS1813'], 'side'
    if v == 'LM7805':
        return 'LM7805', PINNAMES['LM7805'], 'side'
    if v == '2N7000':
        return '2N7000', PINNAMES['2N7000'], 'side'
    if fp == 'POT':
        return 'POT', PINNAMES['POT'], 'side'
    if fp == 'TB5':
        return 'RADIO_PORT', PINNAMES['RADIO'], 'side'
    if ref == 'J3':
        return 'LCD_HEADER', PINNAMES['LCD'], 'side'
    if ref == 'J4':
        return 'PS2_HEADER', PINNAMES['PS2'], 'side'
    if ref == 'J5':
        return 'USB_SERIAL', PINNAMES['FTDI'], 'side'
    if ref == 'J1':
        return 'POWER_IN', PINNAMES['PWR'], 'side'
    if fp.startswith('H'):
        n = {'H1x2': 2, 'H1x3': 3, 'H1x4': 4, 'H1x6': 6, 'H1x16': 16, 'H2x10': 20}[fp]
        return 'HEADER_%d' % n, {i: str(i) for i in range(1, n + 1)}, 'side'
    if fp == 'SW':
        return 'SWITCH', {1: '', 2: ''}, 'two'
    if fp in ('LED', 'D41'):
        return 'DIODE', {1: 'K', 2: 'A'}, 'two'
    if fp in ('CP5', 'CP8'):
        return 'C_POL', {1: '+', 2: ''}, 'two'
    if fp == 'C':
        return 'C', {1: '', 2: ''}, 'two'
    if fp == 'R':
        return 'R', {1: '', 2: ''}, 'two'
    raise SystemExit('no symbol for ' + ref)


def pin_layout(pn, style):
    """[(number, name, x, y, angle)] in library coordinates (y up); body box."""
    nums = sorted(pn)
    out = []
    if style == 'dip':
        n = len(nums)
        h = n // 2
        for i in range(h):
            out.append((nums[i], pn[nums[i]], -10.16, (h - 1 - i) * G, 0))
            out.append((nums[n - 1 - i], pn[nums[n - 1 - i]], 10.16, (h - 1 - i) * G, 180))
        box = (-7.62, h * G - G / 2 + G, 7.62, -G - G / 2 + G * 0)
        box = (-7.62, (h - 1) * G + G, 7.62, -G)
    elif style == 'side':
        n = len(nums)
        for i, k in enumerate(nums):
            out.append((k, pn[k], -10.16, (n - 1 - i) * G, 0))
        box = (-7.62, (n - 1) * G + G, 7.62, -G)
    else:
        out = [(1, pn[1], 0, 3.81, 270), (2, pn[2], 0, -3.81, 90)]
        box = (-1.016, 2.54, 1.016, -2.54)
    return out, box


def eff(size=1.27, justify=None, hide=False):
    j = ' (justify %s)' % justify if justify else ''
    return '(effects (font (size %g %g))%s)%s' % (size, size, j, ' (hide yes)' if hide else '')


def lib_symbol(name, pn, style):
    pins, (x0, y0, x1, y1) = pin_layout(pn, style)
    s = ['(symbol "c02:%s" (pin_names (offset 0.508)) (exclude_from_sim no) (in_bom yes) (on_board yes)' % name]
    if style == 'two':
        s[0] = s[0].replace('(pin_names (offset 0.508))', '(pin_numbers (hide yes)) (pin_names (offset 0) (hide yes))')
    s.append('(property "Reference" "U" (at 0 %g 0) %s)' % (y0 + 2, eff()))
    s.append('(property "Value" "%s" (at 0 %g 0) %s)' % (name, y0 + 4, eff()))
    s.append('(property "Footprint" "" (at 0 0 0) %s)' % eff(hide=True))
    s.append('(property "Datasheet" "" (at 0 0 0) %s)' % eff(hide=True))
    s.append('(symbol "%s_0_1" (rectangle (start %g %g) (end %g %g) (stroke (width 0.254) (type default)) '
             '(fill (type background))))' % (name, x0, y0, x1, y1))
    s.append('(symbol "%s_1_1"' % name)
    for num, nm, x, y, a in pins:
        length = 1.27 if style == 'two' else 2.54
        s.append('(pin passive line (at %g %g %d) (length %g) (name "%s" %s) (number "%s" %s))' % (
            x, y, a, length, nm, eff(), num, eff()))
    s.append(')')
    s.append('(embedded_fonts no))')
    return '\n'.join(s)


# ------------------------------------------------------------ layout
GROUPS = [
    ('CPU and memory', ['U1', 'U2', 'U3']),
    ('I/O chips', ['U4', 'U5', 'U6', 'X2']),
    ('Address decoding, clock', ['U7', 'U8', 'U9', 'U10', 'X1', 'R44']),
    ('Reset, interrupts, flash bank, write protect, LEDs', ['U11', 'SW1', 'SW2', 'R30', 'C30', 'R31', 'R32',
                                                            'JP1', 'R33', 'R34'] +
     ['D%d' % i for i in range(10, 14)] + ['R%d' % i for i in range(40, 44)]),
    ('Power', ['J1', 'D1', 'C1', 'U12', 'C2', 'C3', 'D2', 'R36', 'C23'] +
     ['C%d' % i for i in range(10, 23)]),
    ('Receive comparators (both radios), I/O header', ['U13', 'R4', 'R5', 'C4', 'J6']),
    ('Radio port 1', None),
    ('Radio port 2', None),
    ('LCD, keyboard, USB serial', ['J3', 'RV3', 'R37', 'J4', 'R38', 'R39', 'J5', 'R35', 'JP2']),
]
for i, (t, refs) in enumerate(GROUPS):
    if refs is None:
        n = 1 if t.endswith('1') else 2
        GROUPS[i] = (t, sorted([p['ref'] for p in board.PARTS
                                if p['ref'] in ('J%d' % (6 + n), 'Q%d' % n, 'RV%d' % n, 'D%d' % (3 + n))
                                or (p['ref'][0] in 'RC' and p['ref'][1:].isdigit() and int(p['ref'][1:]) // 100 == n)],
                               key=lambda r: (r[0] != 'J', r[0], int(''.join(c for c in r if c.isdigit())))))

P = {p['ref']: p for p in board.PARTS}
placed = [r for _, refs in GROUPS for r in refs]
missing = [p['ref'] for p in board.PARTS if p['fp'] != 'HOLE' and p['ref'] not in placed]
if missing:
    raise SystemExit('not in any group: %s' % missing)


def snap(v):
    return round(v / G) * G


def label_w(net):
    return len(net) * 1.05 + 2.0


def size(p):
    name, pn, style = kind(p)
    pins, (x0, y0, x1, y1) = pin_layout(pn, style)
    nets = [p['pins'].get(str(k)) or '' for k in pn]
    lw = max(label_w(n) for n in nets) if nets else 0
    if style == 'two':
        return 10.16, 7.62 + 2 * lw + 6
    return 20.32 + (lw if style == 'side' else 2 * lw) + 4, (y0 - y1) + 12


SHEET_W, SHEET_H = 594.0, 420.0
REGIONS = [  # x, y, width of each group's area
    (12, 16, 190), (212, 16, 180), (402, 16, 180),
    (12, 150, 190), (212, 150, 180), (402, 150, 180),
    (12, 270, 190), (212, 270, 180), (402, 270, 180),
]


def build():
    syms, insts, labels, ncs, texts = {}, [], [], [], []
    for (title, refs), (rx, ry, rw) in zip(GROUPS, REGIONS):
        texts.append('(text "%s" (exclude_from_sim no) (at %g %g 0) %s (uuid "%s"))' % (
            title, rx, ry, eff(2.54, 'left bottom'), uid('t', title)))
        x, y, rowh = rx, ry + 8, 0
        for ref in refs:
            p = P[ref]
            w, h = size(p)
            if x + w > rx + rw and x > rx:
                x, y, rowh = rx, y + rowh + 4, 0
            name, pn, style = kind(p)
            syms[name] = lib_symbol(name, pn, style)
            pins, (bx0, by0, bx1, by1) = pin_layout(pn, style)
            lw = max(label_w(p['pins'].get(str(k)) or '') for k in pn)
            if style == 'two':
                ox, oy = snap(x + w / 2), snap(y + lw + 4.5)
            elif style == 'side':
                ox, oy = snap(x + lw + 11), snap(y + 6 + by0)
            else:
                ox, oy = snap(x + lw + 11), snap(y + 6 + by0)
            sid = uid('s', ref)
            props = ['(property "Reference" "%s" (at %g %g 0) %s)' % (
                         ref, ox + (3 if style == 'two' else 0), oy - by0 - (1 if style == 'two' else 3.5),
                         eff(1.27, 'left' if style == 'two' else None)),
                     '(property "Value" "%s" (at %g %g 0) %s)' % (
                         p['value'], ox + (3 if style == 'two' else 0), oy - by0 + (1.5 if style == 'two' else -1.2),
                         eff(1.27, 'left' if style == 'two' else None)),
                     '(property "Footprint" "%s" (at %g %g 0) %s)' % (board.FP[p['fp']], ox, oy, eff(hide=True)),
                     '(property "Datasheet" "" (at %g %g 0) %s)' % (ox, oy, eff(hide=True))]
            if p['mpn']:
                props.append('(property "MPN" "%s" (at %g %g 0) %s)' % (p['mpn'], ox, oy, eff(hide=True)))
            if p['note']:
                props.append('(property "Note" "%s" (at %g %g 0) %s)' % (p['note'].replace('"', "'"), ox, oy, eff(hide=True)))
            pinl = ' '.join('(pin "%s" (uuid "%s"))' % (k, uid('p', ref, k)) for k in pn)
            insts.append('(symbol (lib_id "c02:%s") (at %g %g 0) (unit 1) (exclude_from_sim no) (in_bom %s) '
                         '(on_board yes) (dnp %s) (uuid "%s") %s %s (instances (project "c02comm" '
                         '(path "/%s" (reference "%s") (unit 1)))))' % (
                             name, ox, oy, 'no' if p['dnp'] else 'yes', 'yes' if p['dnp'] else 'no', sid,
                             ' '.join(props), pinl, ROOT, ref))
            for num, nm, px, py, a in pins:
                ex, ey = ox + px, oy - py
                net = p['pins'].get(str(num))
                if not net:
                    ncs.append('(no_connect (at %g %g) (uuid "%s"))' % (ex, ey, uid('nc', ref, num)))
                    continue
                ang, just = {0: (180, 'right bottom'), 180: (0, 'left bottom'),
                             270: (90, 'left bottom'), 90: (270, 'right bottom')}[a]
                labels.append('(label "%s" (at %g %g %d) %s (uuid "%s"))' % (
                    net, ex, ey, ang, eff(1.27, just), uid('l', ref, num)))
            x += w + 3
            rowh = max(rowh, h)
    head = ('(kicad_sch (version 20250610) (generator "c02board_mk_sch") (generator_version "10.0") '
            '(uuid "%s") (paper "A2") (title_block (title "C02COMM: W65C02S radio board") (rev "A") '
            '(comment 1 "Generated from board.py by mk_sch.py; edit board.py, not this file")) '
            % ROOT)
    body = ['(lib_symbols', *syms.values(), ')', *insts, *labels, *ncs, *texts,
            '(sheet_instances (path "/" (page "1")))', '(embedded_fonts no))']
    with open(OUT, 'w') as f:
        f.write(head + '\n'.join(body) + '\n')
    # the same symbols as a project library, so KiCad finds them
    with open(os.path.join(HERE, 'c02.kicad_sym'), 'w') as f:
        f.write('(kicad_symbol_lib (version 20251024) (generator "c02board_mk_sch") (generator_version "10.0")\n')
        f.write('\n'.join(v.replace('(symbol "c02:', '(symbol "', 1) for v in syms.values()))
        f.write(')\n')
    with open(os.path.join(HERE, 'sym-lib-table'), 'w') as f:
        f.write('(sym_lib_table (version 7)\n  (lib (name "c02")(type "KiCad")(uri "${KIPRJMOD}/c02.kicad_sym")'
                '(options "")(descr "C02COMM symbols, made by mk_sch.py"))\n)\n')
    print('%s: %d symbols, %d labels, %d no-connects' % (os.path.basename(OUT), len(insts), len(labels), len(ncs)))


if __name__ == '__main__':
    build()
