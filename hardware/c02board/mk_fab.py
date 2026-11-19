"""Route (optional), check and export the C02COMM board for ordering.

    python mk_fab.py                     DRC + Gerbers/drill zip + BOM (board must be routed)
    python mk_fab.py --route JAR         first autoroute with Freerouting (JAR = freerouting-x.y.z.jar)
    python mk_fab.py --bom               only write bom.csv

Steps:
  1. (--route) mk_pcb.py writes c02comm.dsn; Freerouting writes c02comm.ses;
     mk_pcb.py builds the board again and imports the tracks.
  2. kicad-cli DRC: must show no errors and no unconnected items.
  3. Gerbers + Excellon drill into fab/, zipped as fab/c02comm_gerbers.zip
     (what JLCPCB / PCBWay / OSH Park take), plus bom.csv.
"""
import argparse
import csv
import glob
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import board  # noqa: E402

KICAD = r'C:\Program Files\KiCad\10.0\bin'
CLI = os.path.join(KICAD, 'kicad-cli.exe')
KPY = os.path.join(KICAD, 'python.exe')
PCB = os.path.join(HERE, 'c02comm.kicad_pcb')
FAB = os.path.join(HERE, 'fab')


def run(*cmd):
    print('>', ' '.join(os.path.basename(c) if i == 0 else c for i, c in enumerate(cmd)))
    r = subprocess.run(cmd, cwd=HERE)
    if r.returncode:
        sys.exit('failed: %s' % cmd[0])


def bom():
    groups = {}
    for p in board.PARTS:
        if p['fp'] == 'HOLE' or p['dnp']:
            continue
        key = (p['value'], board.FP[p['fp']].split(':')[1], p['mpn'])
        groups.setdefault(key, []).append(p['ref'])

    def order(r):
        return (re.sub(r'\d', '', r), int(re.sub(r'\D', '', r) or 0))
    rows = sorted(((sorted(refs, key=order), v, fp, mpn) for (v, fp, mpn), refs in groups.items()),
                  key=lambda r: order(r[0][0]))
    path = os.path.join(HERE, 'bom.csv')
    with open(path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['Qty', 'References', 'Value', 'Footprint', 'Manufacturer', 'Mfr part',
                    'Mouser', 'Notes'])
        hdr = []
        for refs, v, fp, mpn in rows:
            if fp.startswith('PinHeader_1x'):          # one strip covers all of them: order it once
                first = not hdr
                hdr.append(refs[0])
                buy = board.HEADER_STRIP if first else ('', 'cut from the strip on the %s line' % hdr[0], '')
            else:
                buy = board.BUY.get((re.sub(r'\d.*', '', refs[0]), v))
                if buy is None:
                    sys.exit('bom: no BUY entry for %s %r' % (refs[0], v))
            w.writerow([len(refs), ' '.join(refs), v, fp, buy[0], buy[1], buy[2], mpn])
        for qty, what, refs in board.EXTRAS:
            w.writerow([qty, refs, what, '', '', '', '', 'not on the PCB'])
    print('bom.csv: %d lines, %d parts' % (len(rows), sum(len(r[0]) for r in rows)))


def route(jar):
    for f in ('c02comm.ses', 'c02comm.dsn'):
        if os.path.exists(os.path.join(HERE, f)):
            os.remove(os.path.join(HERE, f))
    run(KPY, 'mk_pcb.py')                                   # writes the .dsn
    exe = ['java', '-jar', jar] if jar.lower().endswith('.jar') else [jar]   # .jar or the installed .exe
    run(*exe, '-de', 'c02comm.dsn', '-do', 'c02comm.ses', '-mp', '40', '-mt', '2', '--gui.enabled=false')
    run(KPY, 'mk_pcb.py')                                   # imports the .ses


def drc():
    rpt = os.path.join(HERE, 'drc.txt')
    subprocess.run([CLI, 'pcb', 'drc', '--severity-error', '--output', rpt, PCB], cwd=HERE)
    text = open(rpt, encoding='utf-8', errors='replace').read()
    errs = re.search(r'\*\* Found (\d+) DRC violations', text)
    unc = re.search(r'\*\* Found (\d+) unconnected pads', text)
    n_err = int(errs.group(1)) if errs else len(re.findall(r'^\[', text, re.M))
    n_unc = int(unc.group(1)) if unc else text.count('[unconnected_items]')
    print('DRC: %d errors, %d unconnected (details in drc.txt)' % (n_err, n_unc))
    return n_err == 0 and n_unc == 0


def gerbers():
    os.makedirs(FAB, exist_ok=True)
    for f in glob.glob(os.path.join(FAB, '*')):
        os.remove(f)
    run(CLI, 'pcb', 'export', 'gerbers', '--output', FAB + os.sep, '--layers',
        'F.Cu,B.Cu,F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts', '--subtract-soldermask', PCB)
    run(CLI, 'pcb', 'export', 'drill', '--output', FAB + os.sep, '--format', 'excellon',
        '--excellon-separate-th', '--generate-map', '--map-format', 'pdf', PCB)
    z = os.path.join(FAB, 'c02comm_gerbers.zip')
    with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(glob.glob(os.path.join(FAB, '*'))):
            if not f.endswith(('.zip', '.pdf')):
                zf.write(f, os.path.basename(f))
    print('wrote', os.path.relpath(z, HERE))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--route', metavar='JAR', help='autoroute first, with this Freerouting .jar or freerouting.exe')
    ap.add_argument('--bom', action='store_true', help='only write bom.csv')
    a = ap.parse_args()
    bom()
    if a.bom:
        return
    if a.route:
        route(a.route)
    if not drc():
        sys.exit('fix the DRC report before ordering (is the board routed?)')
    gerbers()


if __name__ == '__main__':
    main()
