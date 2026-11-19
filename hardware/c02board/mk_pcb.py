"""Build c02comm.kicad_pcb from board.py (run with KiCad's Python).

    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" mk_pcb.py

Writes:
  c02comm.kicad_pro   project with JLCPCB-safe rules and a Power net class
  c02comm.kicad_pcb   parts placed and connected (ratsnest), board outline and
                      labels; tracks come from routing, ground planes are
                      added after the tracks are imported
  c02comm.dsn         Specctra file for an autorouter (Freerouting)
If c02comm.ses exists (the autorouter's result), its tracks are imported.
"""
import json
import os
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import board  # noqa: E402

NAME = 'c02comm'
PCB = os.path.join(HERE, NAME + '.kicad_pcb')
PRO = os.path.join(HERE, NAME + '.kicad_pro')
DSN = os.path.join(HERE, NAME + '.dsn')
SES = os.path.join(HERE, NAME + '.ses')
FPDIR = os.path.join(os.path.dirname(os.path.dirname(pcbnew.__file__)), 'share', 'kicad', 'footprints')
if not os.path.isdir(FPDIR):
    FPDIR = r'C:\Program Files\KiCad\10.0\share\kicad\footprints'

MM = pcbnew.FromMM


def write_rules():
    """GND pins have their own tracks, so a thermal with one spoke is fine."""
    with open(os.path.join(HERE, NAME + '.kicad_dru'), 'w') as f:
        f.write('(version 1)\n'
                '(rule "gnd_thermals"\n'
                '  (condition "A.Type == \'Zone\'")\n'
                '  (constraint min_resolved_spokes (min 1)))\n')


def write_project():
    """Rules for an ordinary 2-layer order (JLCPCB/PCBWay 'standard')."""
    pro = {
        'board': {'design_settings': {
            'rules': {'min_clearance': 0.2, 'min_track_width': 0.15, 'min_via_diameter': 0.6,
                      'min_through_hole_diameter': 0.3, 'min_copper_edge_clearance': 0.3,
                      'min_hole_clearance': 0.25},
            'track_widths': [0.0, 0.3, 0.5, 0.8, 1.2],
            'via_dimensions': [{'diameter': 0.0, 'drill': 0.0}, {'diameter': 0.8, 'drill': 0.4}],
        }},
        'net_settings': {
            'classes': [
                {'name': 'Default', 'clearance': 0.2, 'track_width': 0.3, 'via_diameter': 0.8,
                 'via_drill': 0.4, 'wire_width': 6, 'bus_width': 12, 'line_style': 0,
                 'schematic_color': 'rgba(0, 0, 0, 0.000)', 'pcb_color': 'rgba(0, 0, 0, 0.000)',
                 'diff_pair_gap': 0.25, 'diff_pair_via_gap': 0.25, 'diff_pair_width': 0.2,
                 'microvia_diameter': 0.3, 'microvia_drill': 0.1, 'priority': 2147483647},
                {'name': 'Power', 'clearance': 0.25, 'track_width': 0.8, 'via_diameter': 1.0,
                 'via_drill': 0.5, 'wire_width': 6, 'bus_width': 12, 'line_style': 0,
                 'schematic_color': 'rgba(0, 0, 0, 0.000)', 'pcb_color': 'rgba(0, 0, 0, 0.000)',
                 'diff_pair_gap': 0.25, 'diff_pair_via_gap': 0.25, 'diff_pair_width': 0.2,
                 'microvia_diameter': 0.3, 'microvia_drill': 0.1, 'priority': 0},
            ],
            'netclass_patterns': [{'netclass': 'Power', 'pattern': n} for n in sorted(board.POWER_NETS)],
            'meta': {'version': 4},
        },
        'meta': {'filename': NAME + '.kicad_pro', 'version': 3},
    }
    with open(PRO, 'w') as f:
        json.dump(pro, f, indent=2)


def load_fp(key):
    lib, name = board.FP[key].split(':')
    fp = pcbnew.FootprintLoad(os.path.join(FPDIR, lib + '.pretty'), name)
    if fp is None:
        raise SystemExit('footprint not found: ' + board.FP[key])
    return fp


def text(b, s, x, y, size=1.2, layer=pcbnew.F_SilkS):
    t = pcbnew.PCB_TEXT(b)
    t.SetText(s)
    t.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
    t.SetLayer(layer)
    t.SetTextSize(pcbnew.VECTOR2I(MM(size), MM(size)))
    t.SetTextThickness(MM(size * 0.15))
    if layer == pcbnew.B_SilkS:
        t.SetMirrored(True)
    b.Add(t)


def zone(b, layer, net):
    z = pcbnew.ZONE(b)
    z.SetLayer(layer)
    z.SetNet(net)
    z.SetLocalClearance(MM(0.3))
    z.SetMinThickness(MM(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(MM(0.4))
    z.SetThermalReliefSpokeWidth(MM(0.5))
    o = z.Outline()
    o.NewOutline()
    m = 0.6
    for x, y in ((m, m), (board.BOARD_W - m, m), (board.BOARD_W - m, board.BOARD_H - m), (m, board.BOARD_H - m)):
        o.Append(MM(x), MM(y))
    b.Add(z)


def build():
    write_project()
    write_rules()
    b = pcbnew.NewBoard(PCB)
    b.SetCopperLayerCount(2)
    ds = b.GetDesignSettings()
    ds.m_CopperEdgeClearance = MM(0.3)

    # outline
    r = pcbnew.PCB_SHAPE(b)
    r.SetShape(pcbnew.SHAPE_T_RECT)
    r.SetStart(pcbnew.VECTOR2I(0, 0))
    r.SetEnd(pcbnew.VECTOR2I(MM(board.BOARD_W), MM(board.BOARD_H)))
    r.SetLayer(pcbnew.Edge_Cuts)
    r.SetWidth(MM(0.1))
    b.Add(r)

    netinfo = {}
    for name in sorted(board.nets()):
        n = pcbnew.NETINFO_ITEM(b, name)
        b.Add(n)
        netinfo[name] = n

    for p in board.PARTS:
        fp = load_fp(p['fp'])
        fp.SetReference(p['ref'])
        fp.SetValue(p['value'])
        fp.SetPosition(pcbnew.VECTOR2I(MM(p['x']), MM(p['y'])))
        if p['rot']:
            fp.SetOrientationDegrees(p['rot'])
        if p['dnp']:
            fp.SetDNP(True)
            fp.SetExcludedFromBOM(True)
        for pad in fp.Pads():
            net = p['pins'].get(pad.GetNumber())
            if net:
                pad.SetNet(netinfo[net])
        # reference on silk, value on fab only
        fp.Reference().SetTextSize(pcbnew.VECTOR2I(MM(1.0), MM(1.0)))
        fp.Reference().SetTextThickness(MM(0.15))
        fp.Value().SetLayer(pcbnew.F_Fab)
        if p['fp'] == 'HOLE':
            fp.Reference().SetVisible(False)
        b.Add(fp)

    text(b, 'C02COMM  W65C02S radio board  KC4UMS', 98, 123, 1.5)
    text(b, 'rev A', 168, 123, 1.2)
    pcbnew.SaveBoard(PCB, b)
    return b


def main():
    b = build()
    b = pcbnew.LoadBoard(PCB)                   # with the project's net classes
    if os.path.exists(SES):
        if not pcbnew.ImportSpecctraSES(b, SES):
            raise SystemExit('could not import ' + SES)
        print('imported tracks from', os.path.basename(SES))
        # ground planes go on after routing, over tracks that already join
        # every GND pin (planes alone break into islands between the buses)
        gnd = b.FindNet('GND')
        zone(b, pcbnew.F_Cu, gnd)
        zone(b, pcbnew.B_Cu, gnd)
    filler = pcbnew.ZONE_FILLER(b)
    filler.Fill(b.Zones())
    pcbnew.SaveBoard(PCB, b)
    if not os.path.exists(SES):
        if not pcbnew.ExportSpecctraDSN(b, DSN):
            raise SystemExit('could not write ' + DSN)
    print('%s: %d parts, %d nets, %d pads, %.0f x %.0f mm' % (
        os.path.basename(PCB), len(board.PARTS), len(board.nets()),
        sum(len(v) for v in board.nets().values()), board.BOARD_W, board.BOARD_H))


if __name__ == '__main__':
    main()
