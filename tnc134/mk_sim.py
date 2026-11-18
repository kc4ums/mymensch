"""Generate sim_sga.inc: the simulated South Georgia stations for tnc134's
test mode (key T).

Twenty "slots"; tnc134 prints one slot every cfg_simg seconds, round robin.
A slot holds one or more packets and plays the next one each time round,
so the mobiles drive their routes and some stations alternate between a
position and a status or message.

All calls start with SIM so they can't be mistaken for real stations.
Every packet is checked with ../tools/aprsmap/aprsmap.py before it is written.

    python mk_sim.py
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools', 'aprsmap'))
import aprsmap  # noqa: E402


def ddm(v, lat):
    h = ('N' if v >= 0 else 'S') if lat else ('E' if v >= 0 else 'W')
    v = abs(v)
    d = int(v)
    m = round((v - d) * 60, 2)
    if m >= 60:
        d, m = d + 1, 0
    return ('%02d%05.2f%s' if lat else '%03d%05.2f%s') % (d, m, h)


def pos(lat, lon, sym='-', table='/'):
    return ddm(lat, True) + table + ddm(lon, False) + sym


def b91(v):
    return ''.join(chr(33 + (v // 91 ** i) % 91) for i in (3, 2, 1, 0))


def comp(lat, lon, sym, course, knots):
    s = '/' + b91(int(380926 * (90 - lat))) + b91(int(190463 * (180 + lon))) + sym
    return s + chr(33 + course // 4) + chr(33 + round(math.log(knots + 1) / math.log(1.08))) + 'G'


def mice(lat, lon, knots, course, sym='>'):
    """Mic-E, message 'En route'; hundredths nudged so every byte prints."""
    hund = round(abs(lon) % 1 * 6000)          # longitude in 1/100 minutes
    while (hund // 100) < 4 or hund % 100 < 4:
        hund += 1
    lm = round(abs(lat) % 1 * 6000)
    digs = '%02d%02d%02d' % (int(abs(lat)), lm // 100, lm % 100)
    # En route = message bits 1,0,1 (custom off): A digits 0-9 -> P-Y for 1
    dest = ''
    for i, c in enumerate(digs):
        one = (i == 0 or i == 2) or (i == 3 and lat >= 0) or (i == 5 and lon < 0)
        dest += chr(ord(c) + 32) if one else c
    d = int(abs(lon)) + 28
    info = '`' + chr(d) + chr(hund // 100 + 28) + chr(hund % 100 + 28)
    info += chr(knots // 10 + 28) + chr((knots % 10) * 10 + course // 100 + 28) + chr(course % 100 + 28)
    return dest, info + sym + '/'


def route(points, n):
    """n points evenly along a polyline, then back again."""
    seg = [math.dist(points[i], points[i + 1]) for i in range(len(points) - 1)]
    tot = sum(seg)
    out = []
    for k in range(n):
        t = tot * k / (n - 1)
        i = 0
        while i < len(seg) - 1 and t > seg[i]:
            t -= seg[i]
            i += 1
        f = t / seg[i]
        a, b = points[i], points[i + 1]
        out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
    return out + out[-2:0:-1]


def heading(a, b):
    return round(math.degrees(math.atan2((b[1] - a[1]) * math.cos(math.radians(a[0])), b[0] - a[0]))) % 360


# ------------------------------------------------------------------ stations
P1 = 'APRS,WIDE2-1'
P2 = 'APRS,SIM1-10*,WIDE2-1'
P3 = 'APRS,SIM2-10*,SIM1-10*'

slots = [
    ['SIM1-10>APRS,WIDE2-1:!' + pos(31.4505, -83.5085, '#') + 'PHG5360/Tifton digi W2'],
    ['SIM2-10>APRS,WIDE2-1:!' + pos(30.8327, -83.2785, '#') + 'PHG5460/Valdosta digi W2'],
    ['SIM3>%s:!%sAlbany' % (P2, pos(31.5785, -84.1557))],
    ['SIM4>%s:!%sThomasville' % (P3, pos(30.8366, -83.9788))],
    ['SIM5>%s:!%sMoultrie, 3.975 LSB nightly' % (P2, pos(31.1799, -83.7891))],
    ['SIM6-13>%s:@181200z%s270/005g012t074r000p002h68b10162 Waycross WX' % (P1, pos(31.2135, -82.3540, '_'))],
    ['SIM7-13>%s:@181200z%s180/003g008t076r000p000h61b10158 Cordele WX' % (P2, pos(31.9635, -83.7824, '_'))],
    ['SIM8>%s:!%sDouglas' % (P1, pos(31.5088, -82.8499))],
    ['SIM9>%s:!%sFitzgerald' % (P2, pos(31.7149, -83.2527))],
    ['SIM10>%s:!%sBainbridge' % (P3, pos(30.9038, -84.5755))],
    [],                                         # SIM11-9 car, I-75 (Mic-E)
    [],                                         # SIM12-14 truck, US-82 (compressed)
    ['SIM13-7>%s:!%sQuitman HT' % (P3, pos(30.7849, -83.5599, '['))],
    ['SIM1-10>%s:;SHELTER  *181200z%sRed Cross shelter, Nashville' % (P1, pos(31.2074, -83.2502, ';'))],
    ['SIM2-10>%s:)WATER!%sWater point, Adel' % (P1, pos(31.1371, -83.4243, 'w'))],
    ['SIM16>%s:!%sHomerville' % (P1, pos(31.0366, -82.7471)),
     'SIM16>%s:>South GA ARES net tonight 2000 on 3.975' % P1],
    ['SIM17>%s:!%sLakeland' % (P2, pos(31.0410, -83.0749)),
     'SIM17>%s::KC4UMS   :Copy your beacon, test from SIM17{01' % P2],
    ['SIM18-5>%s:!%sPHG2360Blakely' % (P1, pos(31.3774, -84.9341))],
    ['SIM19>%s:!%sAmericus' % (P2, pos(32.0724, -84.2327))],
    ['SIM20>%s:!%sAshburn' % (P2, pos(31.7060, -83.6532))],
]

# I-75: Valdosta -> Adel -> Tifton -> Cordele, 9 stops up and back
i75 = route([(30.86, -83.29), (31.14, -83.42), (31.45, -83.51), (31.96, -83.78)], 9)
for k, p in enumerate(i75):
    q = i75[(k + 1) % len(i75)]
    dest, info = mice(p[0], p[1], 65, heading(p, q))
    slots[10].append('SIM11-9>%s,WIDE1-1,WIDE2-1:%s' % (dest, info))

# US-82: Albany -> Sylvester -> Tifton -> Alapaha -> Waycross, 9 stops up and back
us82 = route([(31.58, -84.16), (31.53, -83.84), (31.45, -83.51), (31.30, -83.21), (31.21, -82.36)], 9)
for k, p in enumerate(us82):
    q = us82[(k + 1) % len(us82)]
    slots[11].append('SIM12-14>%s:!%s55 mph US-82' % (P1, comp(p[0], p[1], 'k', heading(p, q), 48)))

# ------------------------------------------------------------------ check
calls = set()
for s in slots:
    for line in s:
        assert all(32 <= ord(c) < 127 for c in line), repr(line)
        d = aprsmap.decode(line)
        assert d, line
        calls.add(d['call'])
        if d['lat'] is not None:
            assert 30.5 < d['lat'] < 32.2 and -85.2 < d['lon'] < -82.0, (line, d['lat'], d['lon'])
car = [aprsmap.decode(x) for x in slots[10]]
for c, p in zip(car, i75):
    assert abs(c['lat'] - p[0]) < 0.001 and abs(c['lon'] - p[1]) < 0.002, (c, p)


# ------------------------------------------------------------------ write
def db(line):
    """db statement; quotes and backslash as numbers."""
    parts, run = [], ''
    for c in line:
        if c in '\'"\\':
            if run:
                parts.append("'%s'" % run)
                run = ''
            parts.append('$%02X' % ord(c))
        else:
            run += c
    if run:
        parts.append("'%s'" % run)
    return '        db      ' + ','.join(parts + ['0'])


out = ['; sim_sga.inc: generated by mk_sim.py, do not edit',
       '; %d slots, %d packets, %d stations/objects' % (len(slots), sum(map(len, slots)), len(calls)),
       'SIM_N           EQU     %d' % len(slots), '',
       'sim_cnt:        db      ' + ','.join(str(len(s)) for s in slots),
       'sim_tab:']
for i in range(len(slots)):
    out.append('        dw      sim_s%d' % i)
for i, s in enumerate(slots):
    out.append('sim_s%d:  dw      %s' % (i, ','.join('sim_p%d_%d' % (i, j) for j in range(len(s)))))
for i, s in enumerate(slots):
    for j, line in enumerate(s):
        out.append('sim_p%d_%d:' % (i, j))
        out.append(db(line))
open(os.path.join(HERE, 'sim_sga.inc'), 'w', newline='\r\n').write('\n'.join(out) + '\n')
print('sim_sga.inc: %d slots, %d packets, %d stations/objects, %d bytes of text' % (
    len(slots), sum(map(len, slots)), len(calls), sum(len(x) + 1 for s in slots for x in s)))
