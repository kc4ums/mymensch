"""Placement check (KiCad Python): courtyards inside the board and not overlapping.

    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" check_place.py [png]
With 'png', also draws place.png (courtyards and references) if Pillow is there.
"""
import os
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import board  # noqa: E402

b = pcbnew.LoadBoard(os.path.join(HERE, 'c02comm.kicad_pcb'))
TO = pcbnew.ToMM
boxes = []
for fp in b.GetFootprints():
    ref = fp.GetReference()
    cy = fp.GetCourtyard(pcbnew.F_CrtYd)
    if cy.OutlineCount():
        bb = cy.BBox()
    else:
        bb = fp.GetBoundingBox(False)
    x0, y0, x1, y1 = TO(bb.GetLeft()), TO(bb.GetTop()), TO(bb.GetRight()), TO(bb.GetBottom())
    boxes.append((ref, x0, y0, x1, y1))

bad = 0
for ref, x0, y0, x1, y1 in boxes:
    if ref.startswith('H'):
        continue
    if x0 < 0.5 or y0 < 0.5 or x1 > board.BOARD_W - 0.5 or y1 > board.BOARD_H - 0.5:
        print('OUTSIDE  %-6s %6.1f %6.1f %6.1f %6.1f' % (ref, x0, y0, x1, y1))
        bad += 1
for i in range(len(boxes)):
    for j in range(i + 1, len(boxes)):
        a, c = boxes[i], boxes[j]
        ox = min(a[3], c[3]) - max(a[1], c[1])
        oy = min(a[4], c[4]) - max(a[2], c[2])
        if ox > 0.05 and oy > 0.05:
            print('OVERLAP  %-6s %-6s by %.1f x %.1f mm' % (a[0], c[0], ox, oy))
            bad += 1
print('%d placement problems' % bad)

if 'png' in sys.argv:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        sys.exit('no Pillow')
    s = 7
    im = Image.new('RGB', (int(board.BOARD_W * s) + 1, int(board.BOARD_H * s) + 1), 'white')
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, board.BOARD_W * s, board.BOARD_H * s], outline='black')
    for ref, x0, y0, x1, y1 in boxes:
        col = {'U': 'blue', 'R': 'darkgreen', 'C': 'brown', 'J': 'purple'}.get(ref[0], 'black')
        d.rectangle([x0 * s, y0 * s, x1 * s, y1 * s], outline=col)
        d.text((x0 * s + 2, y0 * s + 1), ref, fill=col)
    for fp in b.GetFootprints():
        for pad in fp.Pads():
            p = pad.GetPosition()
            x, y = TO(p.x) * s, TO(p.y) * s
            d.ellipse([x - 3, y - 3, x + 3, y + 3], fill='gray' if pad.GetNetname() else 'red')
    im.save(sys.argv[sys.argv.index('png') + 1] if len(sys.argv) > sys.argv.index('png') + 1 else
            os.path.join(HERE, 'place.png'))
