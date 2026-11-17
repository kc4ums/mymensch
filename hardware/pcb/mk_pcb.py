"""MyMENSCH software-TNC radio interface: single-sided PCB for a hobby CNC.

Generates GRBL G-code (isolation milling, drilling, board outline), checks
the layout (clearances, net connectivity, ground fill), and draws previews.

    python mk_pcb.py            writes the .nc and .svg files next to this script

Layout: through-hole parts on the top (component) side, copper on the
bottom. All copper not used by a signal is left as ground fill, so ground
needs no traces. Coordinates below are in 0.1 inch grid units, seen from
the COMPONENT side, x to the right, y down. The G-code is mirrored so it
cuts the copper side, which is face up on the machine.
"""
import math
import os
import sys

import numpy as np
from contourpy import contour_generator
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
U = 2.54                       # grid unit, mm

# ----------------------------------------------------------------- machining
SPINDLE = 10000                # S word (rpm or PWM value, machine specific)
Z_SAFE = 2.0                   # travel height, mm
ISO_DEPTH = -0.08              # V-bit cut depth into copper (0.035 mm copper)
ISO_FEED = 150                 # mm/min
ISO_PLUNGE = 30
VBIT_TIP = 0.10                # 30 degree V-bit, 0.1 mm tip
VBIT_ANGLE = 30
ISO_PASSES = 3                 # isolation passes per net
ISO_STEP = 0.12                # mm between passes
DRILL_DEPTH = -1.9             # through 1.6 mm FR-4 plus a little
DRILL_FEED = 60
OUTLINE_TOOL = 1.5875          # 1/16 inch end mill
OUTLINE_DEPTH = -1.75
OUTLINE_STEP = 0.4
OUTLINE_FEED = 120
TAB_LEN = 4.0                  # holding tabs on the last pass
TAB_TOP = -1.2

# ----------------------------------------------------------------- design rules
TRACE_W = 0.8
PAD_D = 1.9                    # 0.8 mm holes
PAD_D_BIG = 2.4                # radio wire pads
DRILL_SMALL = 0.8
DRILL_BIG = 1.0                # header pins and radio wires
MIN_CLEAR = 0.45               # copper to copper between different nets

BOARD_W = 35.5 * U
BOARD_H = 26.5 * U

# ----------------------------------------------------------------- parts
# (ref, value, footprint, [(pin, x, y, net), ...]); x, y in grid units
PARTS = [
    # radio side wire pads (6-pin mini-DIN data cable)
    ('J1', 'TM-V71A DATA', 'WIRES', [
        ('PR1', 1, 4, 'RXAUD'), ('SQC', 1, 8, 'SQCIN'), ('PKS', 1, 15, 'PKS'),
        ('GND', 1, 19, 'GND'), ('PKD', 1, 23, 'NP')]),
    # MyMENSCH J3 jumper header (VIA_A port A; J3 pin 49 = +3V3, 50 = GND)
    ('J2', 'to MyMENSCH J3', 'HDR', [
        ('PA7 J3-29', 34, 10, 'OUT'), ('+3V3 J3-49', 34, 11, 'V33'),
        ('PA5 J3-33', 34, 12, 'NS'), ('PA4 J3-35', 34, 13, 'PTT'),
        ('PA3 J3-37', 34, 14, 'PA3'), ('PA2 J3-39', 34, 15, 'PA2'),
        ('PA1 J3-41', 34, 16, 'PA1'), ('PA0 J3-43', 34, 17, 'PA0'),
        ('GND J3-50', 34, 18, 'GND')]),
    # receive
    ('C1', '1uF', 'C', [(1, 3, 4, 'RXAUD'), (2, 3, 6, 'NC1R1')]),
    ('R1', '10k', 'R', [(1, 4, 6, 'NC1R1'), (2, 8, 6, 'NA')]),
    ('R3', '1M', 'R', [(1, 9, 3, 'OUT'), (2, 9, 7, 'NA')]),
    ('R2', '100k', 'R', [(1, 11, 5, 'VREF'), (2, 11, 9, 'NA')]),
    ('C2', '10uF', 'CP', [('+', 12, 5, 'VREF'), ('-', 12, 4, 'GND')]),
    ('R4', '10k', 'R', [(1, 13, 5, 'VREF'), (2, 13, 9, 'V33')]),
    ('R5', '6.8k', 'R', [(1, 14, 1, 'GND'), (2, 14, 5, 'VREF')]),
    ('U1', 'LM393', 'DIP8', [
        (1, 16, 4, 'OUT'), (2, 16, 5, 'VREF'), (3, 16, 6, 'NA'), (4, 16, 7, 'GND'),
        (5, 19, 7, 'GND'), (6, 19, 6, 'V33'), (7, 19, 5, 'NC7'), (8, 19, 4, 'V33')]),
    ('R6', '10k', 'R', [(1, 23, 3, 'OUT'), (2, 23, 7, 'V33')]),
    # squelch
    ('R20', '10k', 'R', [(1, 3, 8, 'SQCIN'), (2, 7, 8, 'NS')]),
    ('R21', '20k', 'R', [(1, 10, 12, 'NS'), (2, 10, 16, 'GND')]),
    # PTT
    ('R8', '100', 'R', [(1, 4, 13, 'NG'), (2, 8, 13, 'PTT')]),
    ('R9', '100k', 'R', [(1, 4, 14, 'NG'), (2, 4, 18, 'GND')]),
    ('Q1', '2N7000', 'TO92', [('D', 6, 15, 'PKS'), ('G', 7, 15, 'NG'), ('S', 8, 15, 'GND')]),
    # transmit DAC
    ('R10', '20k', 'R', [(1, 13, 18, 'PA3'), (2, 13, 22, 'N3')]),
    ('R11', '20k', 'R', [(1, 17, 18, 'PA2'), (2, 17, 22, 'N2')]),
    ('R12', '20k', 'R', [(1, 22, 18, 'PA1'), (2, 22, 22, 'N1')]),
    ('R13', '20k', 'R', [(1, 27, 18, 'PA0'), (2, 27, 22, 'N0')]),
    ('R14', '10k', 'R', [(1, 13, 23, 'N3'), (2, 17, 23, 'N2')]),
    ('R15', '10k', 'R', [(1, 18, 23, 'N2'), (2, 22, 23, 'N1')]),
    ('R16', '10k', 'R', [(1, 23, 23, 'N1'), (2, 27, 23, 'N0')]),
    ('R17', '20k', 'R', [(1, 28, 23, 'N0'), (2, 32, 23, 'GND')]),
    # filter, level, pad
    ('R7', '4.7k', 'R', [(1, 8, 23, 'NF'), (2, 12, 23, 'N3')]),
    ('C3', '10nF', 'C', [(1, 9, 25, 'NF'), (2, 11, 25, 'GND')]),
    ('C4', '1uF', 'C', [(1, 8, 21, 'NF'), (2, 8, 19, 'NE')]),
    ('RV1', '10k', 'POT', [(3, 5, 18, 'GND'), (2, 6, 18, 'NW'), (1, 7, 18, 'NE')]),
    ('R18', '100k', 'R', [(1, 6, 19, 'NW'), (2, 6, 23, 'NP')]),
    ('R19', '2.2k', 'R', [(1, 4, 19, 'GND'), (2, 4, 23, 'NP')]),
]

# traces: net -> list of polylines in grid units
TRACES = {
    'RXAUD': [[(1, 4), (3, 4)]],
    'NC1R1': [[(3, 6), (4, 6)]],
    'NA': [[(8, 6), (16, 6)], [(9, 6), (9, 7)], [(11, 6), (11, 9)]],
    'VREF': [[(11, 5), (16, 5)]],
    'OUT': [[(9, 3), (33, 3), (33, 10), (34, 10)], [(16, 3), (16, 4)]],
    'V33': [[(34, 11), (13, 11)], [(13, 9), (13, 11)], [(21, 11), (21, 4), (19, 4)],
            [(19, 6), (21, 6)], [(23, 7), (21, 7)]],
    'SQCIN': [[(1, 8), (3, 8)]],
    'NS': [[(7, 8), (7, 12), (34, 12)]],
    'PTT': [[(8, 13), (34, 13)]],
    'NG': [[(4, 13), (4, 14), (7, 14), (7, 15)]],
    'PKS': [[(6, 15), (1, 15)]],
    'PA3': [[(34, 14), (13, 14), (13, 18)]],
    'PA2': [[(34, 15), (17, 15), (17, 18)]],
    'PA1': [[(34, 16), (22, 16), (22, 18)]],
    'PA0': [[(34, 17), (27, 17), (27, 18)]],
    'N3': [[(13, 22), (13, 23)], [(12, 23), (13, 23)]],
    'N2': [[(17, 22), (17, 23), (18, 23)]],
    'N1': [[(22, 22), (22, 23), (23, 23)]],
    'N0': [[(27, 22), (27, 23), (28, 23)]],
    'NF': [[(8, 21), (8, 25), (9, 25)]],
    'NE': [[(8, 19), (8, 18), (7, 18)]],
    'NW': [[(6, 18), (6, 19)]],
    'NP': [[(6, 23), (1, 23)]],
}

BIG_DRILL_REFS = {'J1', 'J2'}


# ----------------------------------------------------------------- geometry
def pads():
    out = []
    for ref, val, fp, pins in PARTS:
        for pin, x, y, net in pins:
            big = ref in BIG_DRILL_REFS
            d = PAD_D_BIG if ref == 'J1' else PAD_D
            out.append(dict(ref=ref, pin=pin, x=x * U, y=y * U, net=net,
                            r=d / 2, drill=DRILL_BIG if big else DRILL_SMALL))
    return out


def prims():
    """Copper primitives: ('c', net, x, y, r) and ('s', net, x1, y1, x2, y2, hw)."""
    out = [('c', p['net'], p['x'], p['y'], p['r']) for p in pads()]
    for net, lines in TRACES.items():
        for line in lines:
            for (x1, y1), (x2, y2) in zip(line, line[1:]):
                out.append(('s', net, x1 * U, y1 * U, x2 * U, y2 * U, TRACE_W / 2))
    return out


def pt_seg(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / L))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def seg_seg(a, b):
    (x1, y1, x2, y2), (x3, y3, x4, y4) = a, b

    def ccw(ax, ay, bx, by, cx, cy):
        return (cy - ay) * (bx - ax) - (by - ay) * (cx - ax)
    d1, d2 = ccw(x3, y3, x4, y4, x1, y1), ccw(x3, y3, x4, y4, x2, y2)
    d3, d4 = ccw(x1, y1, x2, y2, x3, y3), ccw(x1, y1, x2, y2, x4, y4)
    if d1 * d2 < 0 and d3 * d4 < 0:
        return 0.0
    return min(pt_seg(x1, y1, x3, y3, x4, y4), pt_seg(x2, y2, x3, y3, x4, y4),
               pt_seg(x3, y3, x1, y1, x2, y2), pt_seg(x4, y4, x1, y1, x2, y2))


def gap(p, q):
    """Edge-to-edge distance between two primitives (negative = overlap)."""
    if p[0] == 'c' and q[0] == 'c':
        return math.hypot(p[2] - q[2], p[3] - q[3]) - p[4] - q[4]
    if p[0] == 's' and q[0] == 'c':
        p, q = q, p
    if p[0] == 'c':
        return pt_seg(p[2], p[3], *q[2:6]) - p[4] - q[6]
    return seg_seg(p[2:6], q[2:6]) - p[6] - q[6]


def dist_field(ps, X, Y):
    """Distance from grid points to the copper of primitives ps (<= 0 inside)."""
    D = np.full(X.shape, np.inf)
    for p in ps:
        if p[0] == 'c':
            d = np.hypot(X - p[2], Y - p[3]) - p[4]
        else:
            x1, y1, x2, y2, hw = p[2:7]
            dx, dy = x2 - x1, y2 - y1
            L = dx * dx + dy * dy
            t = np.clip(((X - x1) * dx + (Y - y1) * dy) / L, 0, 1) if L else 0
            d = np.hypot(X - (x1 + t * dx), Y - (y1 + t * dy)) - hw
        np.minimum(D, d, out=D)
    return D


# ----------------------------------------------------------------- checks
def drc(ps):
    errs = []
    worst = (1e9, None)
    for i in range(len(ps)):
        for j in range(i + 1, len(ps)):
            a, b = ps[i], ps[j]
            if a[1] == b[1]:
                continue
            g = gap(a, b)
            if g < worst[0]:
                worst = (g, (a, b))
            if g < MIN_CLEAR:
                errs.append('clearance %.2f mm between %s and %s' % (g, desc(a), desc(b)))
    # net connectivity: every net's copper must be one piece
    nets = {}
    for p in ps:
        nets.setdefault(p[1], []).append(p)
    for net, items in nets.items():
        if net == 'GND':
            continue
        seen, todo = {0}, [0]
        while todo:
            k = todo.pop()
            for m in range(len(items)):
                if m not in seen and gap(items[k], items[m]) <= 0.01:
                    seen.add(m)
                    todo.append(m)
        if len(seen) != len(items):
            loose = [desc(items[m]) for m in range(len(items)) if m not in seen]
            errs.append('net %s is not connected: %s' % (net, ', '.join(loose[:4])))
    return errs, worst


def desc(p):
    if p[0] == 'c':
        for q in pads():
            if abs(q['x'] - p[2]) < 1e-6 and abs(q['y'] - p[3]) < 1e-6:
                return '%s.%s(%s)' % (q['ref'], q['pin'], p[1])
    return '%s trace at (%.1f,%.1f)-(%.1f,%.1f)' % (
        p[1], p[2] / U, p[3] / U, p[4] / U, p[5] / U) if p[0] == 's' else p[1]


def iso_radius(k):
    """Centre offset of isolation pass k from the copper edge."""
    half = VBIT_TIP / 2 + (-ISO_DEPTH) * math.tan(math.radians(VBIT_ANGLE / 2))
    return half + 0.01 + k * ISO_STEP


def ground_check(ps):
    """Rasterise the board, mill away the channels, label the ground fill."""
    res = 0.05
    xs = np.arange(0, BOARD_W, res) + res / 2
    ys = np.arange(0, BOARD_H, res) + res / 2
    X, Y = np.meshgrid(xs, ys)
    sig = [p for p in ps if p[1] != 'GND']
    D = dist_field(sig, X, Y)
    reach = iso_radius(ISO_PASSES - 1) + iso_cut_half()
    ground = D > reach
    lab, n = ndimage.label(ground)
    gpads = [p for p in pads() if p['net'] == 'GND']
    ids = set()
    for p in gpads:
        ids.add(lab[int(p['y'] / res), int(p['x'] / res)])
    sizes = ndimage.sum(ground, lab, range(1, n + 1))
    main = max(ids) if len(ids) == 1 else None
    islands = [i + 1 for i, s in enumerate(sizes) if (i + 1) not in ids and s > 0]
    return ids, main, islands, sizes


def iso_cut_half():
    return VBIT_TIP / 2 + (-ISO_DEPTH) * math.tan(math.radians(VBIT_ANGLE / 2))


# ----------------------------------------------------------------- toolpaths
def rdp(pts, eps):
    """Ramer-Douglas-Peucker simplification of an (N,2) array."""
    if len(pts) < 3:
        return pts
    keep = np.zeros(len(pts), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        a, b = pts[i], pts[j]
        seg = pts[i + 1:j]
        if len(seg) == 0:
            continue
        ab = b - a
        L = np.hypot(*ab)
        if L == 0:
            d = np.hypot(*(seg - a).T)
        else:
            d = np.abs(ab[0] * (seg[:, 1] - a[1]) - ab[1] * (seg[:, 0] - a[0])) / L
        k = int(np.argmax(d))
        if d[k] > eps:
            m = i + 1 + k
            keep[m] = True
            stack += [(i, m), (m, j)]
    return pts[keep]


def isolation_paths(ps):
    nets = {}
    for p in ps:
        if p[1] != 'GND':
            nets.setdefault(p[1], []).append(p)
    res = 0.02
    paths = []
    for net, items in sorted(nets.items()):
        xs_all = [v for p in items for v in ((p[2],) if p[0] == 'c' else (p[2], p[4]))]
        ys_all = [v for p in items for v in ((p[3],) if p[0] == 'c' else (p[3], p[5]))]
        m = 2.0
        xs = np.arange(min(xs_all) - m, max(xs_all) + m, res)
        ys = np.arange(min(ys_all) - m, max(ys_all) + m, res)
        X, Y = np.meshgrid(xs, ys)
        D = dist_field(items, X, Y)
        gen = contour_generator(x=xs, y=ys, z=D)
        for k in range(ISO_PASSES):
            for line in gen.lines(iso_radius(k)):
                line = rdp(np.asarray(line), 0.008)
                paths.append((net, k, line))
    return paths


def to_machine(x, y):
    """Design (component side, y down) -> machine (copper side up, y up)."""
    return BOARD_W - x, BOARD_H - y


def order(items, start=(0.0, 0.0)):
    """Nearest-neighbour ordering of point lists; closed loops may rotate."""
    left = list(items)
    out, cur = [], start
    while left:
        best, bi, bk = 1e18, 0, 0
        for i, pts in enumerate(left):
            closed = len(pts) > 2 and np.allclose(pts[0], pts[-1])
            cand = range(len(pts) - 1) if closed else (0,)
            for k in cand:
                d = (pts[k][0] - cur[0]) ** 2 + (pts[k][1] - cur[1]) ** 2
                if d < best:
                    best, bi, bk = d, i, k
        pts = left.pop(bi)
        if bk:
            pts = np.vstack([pts[bk:-1], pts[:bk + 1]])
        out.append(pts)
        cur = pts[-1]
    return out


def gcode_header(title, tool, lines):
    return [
        '(%s)' % title,
        '(MyMENSCH software TNC radio interface, generated by mk_pcb.py)',
        '(Tool: %s)' % tool,
        '(Origin X0 Y0 = lower-left corner of the board, COPPER SIDE UP)',
        '(Z0 = top of the copper)',
    ] + ['(%s)' % s for s in lines] + [
        'G21 G90 G17 G94',
        'G0 Z%.2f' % Z_SAFE,
        'M3 S%d' % SPINDLE,
        'G4 P3',
    ]


def gcode_footer():
    return ['G0 Z10', 'M5', 'G0 X0 Y0', 'M2']


def write_isolation(paths, fn):
    loops = [np.array([to_machine(x, y) for x, y in pts]) for _, _, pts in paths]
    loops = order(loops)
    g = gcode_header('Isolation milling', '%d deg V-bit, %.2f mm tip' % (VBIT_ANGLE, VBIT_TIP),
                     ['Depth %.3f mm, %d passes per net, %.2f mm apart' %
                      (ISO_DEPTH, ISO_PASSES, ISO_STEP),
                      'Level the board or use a height map: the cut is very shallow.'])
    total = 0.0
    for pts in loops:
        g.append('G0 X%.3f Y%.3f' % tuple(pts[0]))
        g.append('G1 Z%.3f F%d' % (ISO_DEPTH, ISO_PLUNGE))
        first = True
        for x, y in pts[1:]:
            g.append('G1 X%.3f Y%.3f%s' % (x, y, ' F%d' % ISO_FEED if first else ''))
            first = False
        total += float(np.sum(np.hypot(*np.diff(pts, axis=0).T)))
        g.append('G0 Z%.2f' % Z_SAFE)
    g += gcode_footer()
    open(fn, 'w').write('\n'.join(g) + '\n')
    return len(loops), total


def write_drill(holes, dia, fn):
    pts = [np.array([to_machine(p['x'], p['y'])]) for p in holes]
    pts = order(pts)
    g = gcode_header('Drilling', '%.1f mm drill' % dia,
                     ['%d holes, depth %.2f mm' % (len(pts), DRILL_DEPTH),
                      'Put a sacrificial board under the PCB.'])
    for p in pts:
        x, y = p[0]
        g += ['G0 X%.3f Y%.3f' % (x, y), 'G1 Z%.2f F%d' % (DRILL_DEPTH, DRILL_FEED),
              'G0 Z%.2f' % Z_SAFE]
    g += gcode_footer()
    open(fn, 'w').write('\n'.join(g) + '\n')
    return len(pts)


def write_outline(fn):
    r = OUTLINE_TOOL / 2
    x0, y0, x1, y1 = -r, -r, BOARD_W + r, BOARD_H + r
    corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)]
    g = gcode_header('Board outline', '1/16 inch (%.3f mm) end mill' % OUTLINE_TOOL,
                     ['Board %.1f x %.1f mm, cut outside the edge' % (BOARD_W, BOARD_H),
                      'Last pass leaves 4 tabs %.1f mm long, %.2f mm thick' %
                      (TAB_LEN, OUTLINE_DEPTH - TAB_TOP)])
    g.append('G0 X%.3f Y%.3f' % (x0, y0))
    z = 0.0
    depths = []
    while z > OUTLINE_DEPTH + 1e-9:
        z = max(OUTLINE_DEPTH, z - OUTLINE_STEP)
        depths.append(z)
    for z in depths:
        tabs = z < TAB_TOP
        g.append('G1 Z%.3f F%d' % (z, ISO_PLUNGE * 2))
        for (ax, ay), (bx, by) in zip(corners, corners[1:]):
            if not tabs:
                g.append('G1 X%.3f Y%.3f F%d' % (bx, by, OUTLINE_FEED))
                continue
            mx, my = (ax + bx) / 2, (ay + by) / 2
            L = math.hypot(bx - ax, by - ay)
            ux, uy = (bx - ax) / L, (by - ay) / L
            t0 = (mx - ux * TAB_LEN / 2, my - uy * TAB_LEN / 2)
            t1 = (mx + ux * TAB_LEN / 2, my + uy * TAB_LEN / 2)
            g.append('G1 X%.3f Y%.3f F%d' % (t0[0], t0[1], OUTLINE_FEED))
            g.append('G1 Z%.3f' % TAB_TOP)
            g.append('G1 X%.3f Y%.3f' % t1)
            g.append('G1 Z%.3f' % z)
            g.append('G1 X%.3f Y%.3f' % (bx, by))
    g.append('G0 Z%.2f' % Z_SAFE)
    g += gcode_footer()
    open(fn, 'w').write('\n'.join(g) + '\n')
    return depths


# ----------------------------------------------------------------- drawings
FOOT = {'R': (6.3, 2.4), 'C': (7.2, 3.5)}


def svg_open(w, h, scale, title):
    W, H = w * scale + 40, h * scale + 110
    return ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
            'font-family="Helvetica, Arial, sans-serif">' % (W, H, W, H),
            '<rect width="100%" height="100%" fill="white"/>',
            '<text x="20" y="28" font-size="18" font-weight="bold">%s</text>' % title]


def write_copper_svg(ps, paths, fn):
    s = 8.0
    ox, oy = 20, 50
    out = svg_open(BOARD_W, BOARD_H, s,
                   'Copper side (as it sits on the CNC, mirrored) - what gets milled')

    def P(x, y):
        mx, my = to_machine(x, y)
        return ox + mx * s, oy + (BOARD_H - my) * s
    out.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#d9894a" stroke="#333"/>' % (
        ox, oy, BOARD_W * s, BOARD_H * s))
    w = 2 * iso_cut_half() * s
    for _, _, pts in paths:
        d = ' '.join('%.1f,%.1f' % P(x, y) for x, y in pts)
        out.append('<polyline points="%s" fill="none" stroke="#2b2b2b" stroke-width="%.2f" '
                   'stroke-linejoin="round"/>' % (d, max(w, 1.0)))
    for p in pads():
        x, y = P(p['x'], p['y'])
        out.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="white"/>' % (x, y, p['drill'] / 2 * s))
    out.append('<text x="%d" y="%d" font-size="13" fill="#444">Copper = orange, milled channels = '
               'dark, holes = white. Origin X0 Y0 at the lower-left corner.</text>' % (
                   ox, oy + BOARD_H * s + 28))
    out.append('</svg>')
    open(fn, 'w', encoding='utf-8').write('\n'.join(out))


def write_assembly_svg(ps, fn):
    s = 9.0
    ox, oy = 20, 50
    out = svg_open(BOARD_W, BOARD_H, s, 'Component side - part placement (copper seen through)')

    def P(x, y):
        return ox + x * s, oy + y * s
    out.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#f4f1e6" stroke="#333"/>' % (
        ox, oy, BOARD_W * s, BOARD_H * s))
    for p in ps:
        if p[1] == 'GND':
            continue
        if p[0] == 's':
            x1, y1 = P(p[2], p[3])
            x2, y2 = P(p[4], p[5])
            out.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#e7b48c" '
                       'stroke-width="%.1f" stroke-linecap="round"/>' % (x1, y1, x2, y2, TRACE_W * s))
    for ref, val, fp, pins in PARTS:
        xy = [(x * U, y * U) for _, x, y, _ in pins]
        cx = sum(x for x, _ in xy) / len(xy)
        cy = sum(y for _, y in xy) / len(xy)
        X, Y = P(cx, cy)
        if fp in FOOT:
            (ax, ay), (bx, by) = xy[0], xy[-1]
            L, Wd = FOOT[fp]
            ang = math.degrees(math.atan2(by - ay, bx - ax))
            out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="%s" '
                       'stroke="#555" transform="rotate(%.1f %.1f %.1f)"/>' % (
                           X - L / 2 * s, Y - Wd / 2 * s, L * s, Wd * s, Wd / 2 * s if fp == 'R' else 2,
                           '#c9d8ef' if fp == 'R' else '#f2d98a', ang, X, Y))
        elif fp == 'CP':
            out.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#9ec7a8" stroke="#555"/>' % (X, Y, 2.5 * s))
        elif fp == 'DIP8':
            out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#555" stroke="#222"/>' % (
                X - 3.2 * s, Y - 5.0 * s, 6.4 * s, 10.0 * s))
            out.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#999"/>' % (X - 2.0 * s, Y - 3.8 * s, 0.6 * s))
        elif fp == 'TO92':
            out.append('<path d="M %.1f %.1f h %.1f a %.1f %.1f 0 0 1 %.1f 0 z" fill="#555" stroke="#222"/>' % (
                X - 2.4 * s, Y + 0.8 * s, 4.8 * s, 2.4 * s, 2.4 * s, -4.8 * s))
        elif fp == 'POT':
            out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#4a6fb5" stroke="#222"/>' % (
                X - 3.3 * s, Y - 3.4 * s, 6.6 * s, 6.8 * s))
        for pin, x, y, net in pins:
            px, py = P(x * U, y * U)
            r = (PAD_D_BIG if ref == 'J1' else PAD_D) / 2 * s
            out.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#e7b48c" stroke="#8a5a2b"/>' % (px, py, r))
            out.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="white"/>' % (
                px, py, (DRILL_BIG if ref in BIG_DRILL_REFS else DRILL_SMALL) / 2 * s))
            if fp == 'WIRES':
                out.append('<text x="%.1f" y="%.1f" font-size="10" text-anchor="middle" fill="#0b5cad" '
                           'font-weight="bold">%s</text>' % (px, py + r + 11, pin))
            if fp == 'HDR':
                out.append('<text x="%.1f" y="%.1f" font-size="11" text-anchor="end" fill="#0b5cad" '
                           'font-weight="bold">%s</text>' % (px - 14, py + 4, pin))
            if fp == 'CP' and pin == '+':
                out.append('<text x="%.1f" y="%.1f" font-size="13" font-weight="bold">+</text>' % (
                    px + 0.9 * s, py + 1.2 * s))
            if fp == 'TO92' or fp == 'POT':
                out.append('<text x="%.1f" y="%.1f" font-size="9" text-anchor="middle" fill="#fff">%s</text>' % (
                    px, py + 3, pin))
        if fp not in ('WIRES', 'HDR'):
            tx, ty = X, Y + 4
            size = 10
            if fp == 'TO92':
                tx, ty, size = X + 0.6 * s, Y + 3.9 * s, 9
            if fp == 'POT':
                ty = Y - 1.5 * s
            if fp == 'DIP8':
                ty = Y + 1.0 * s
            col = '#fff' if fp in ('DIP8', 'POT') else '#111'
            out.append('<text x="%.1f" y="%.1f" font-size="10" text-anchor="middle" fill="%s" '
                       'font-weight="bold">%s %s</text>' % (tx, ty, col, ref, val)
                       if size == 10 else
                       '<text x="%.1f" y="%.1f" font-size="9" text-anchor="start" fill="%s" '
                       'font-weight="bold">%s %s</text>' % (tx, ty, col, ref, val))
        else:
            xs = [P(x * U, y * U)[0] for _, x, y, _ in pins]
            ys = [P(x * U, y * U)[1] for _, x, y, _ in pins]
            lx = min(xs) + (0 if fp == 'WIRES' else -60)
            out.append('<text x="%.1f" y="%.1f" font-size="11" font-weight="bold">%s %s</text>' % (
                lx, min(ys) - 16, ref, val))
    out.append('<text x="%d" y="%d" font-size="13" fill="#444">Parts go on this side; copper is '
               'underneath. Grid 0.1 in. Q1 2N7000: flat face toward the TOP edge (D left, S right).</text>' % (
                   ox, oy + BOARD_H * s + 28))
    out.append('</svg>')
    open(fn, 'w', encoding='utf-8').write('\n'.join(out))


# ----------------------------------------------------------------- main
def main():
    ps = prims()
    errs, worst = drc(ps)
    print('Board %.1f x %.1f mm, %d parts, %d pads, %d trace segments' % (
        BOARD_W, BOARD_H, len(PARTS), len(pads()), sum(1 for p in ps if p[0] == 's')))
    print('Closest copper between different nets: %.2f mm (%s / %s)' % (
        worst[0], desc(worst[1][0]), desc(worst[1][1])))
    ids, main_id, islands, sizes = ground_check(ps)
    if len(ids) != 1:
        errs.append('ground fill is split: GND pads sit in %d separate pieces' % len(ids))
    print('Ground fill: all GND pads in one piece: %s; floating copper islands: %d' % (
        'yes' if len(ids) == 1 else 'NO', len(islands)))
    if errs:
        print('DESIGN RULE ERRORS:')
        for e in errs:
            print('  ' + e)
        return 1
    paths = isolation_paths(ps)
    n, length = write_isolation(paths, os.path.join(HERE, 'isolation_30deg_vbit.nc'))
    print('isolation_30deg_vbit.nc: %d loops, %.0f mm of cutting' % (n, length))
    small = [p for p in pads() if p['drill'] == DRILL_SMALL]
    big = [p for p in pads() if p['drill'] == DRILL_BIG]
    print('drill_0.8mm.nc: %d holes' % write_drill(small, DRILL_SMALL, os.path.join(HERE, 'drill_0.8mm.nc')))
    print('drill_1.0mm.nc: %d holes' % write_drill(big, DRILL_BIG, os.path.join(HERE, 'drill_1.0mm.nc')))
    depths = write_outline(os.path.join(HERE, 'outline_1-16in_endmill.nc'))
    print('outline_1-16in_endmill.nc: %d passes to %.2f mm' % (len(depths), depths[-1]))
    write_copper_svg(ps, paths, os.path.join(HERE, 'copper_side.svg'))
    write_assembly_svg(ps, os.path.join(HERE, 'assembly_top.svg'))
    print('copper_side.svg, assembly_top.svg written')
    return 0


if __name__ == '__main__':
    sys.exit(main())
