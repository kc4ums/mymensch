"""aprsmap: APRS stations on a text-terminal map. No GUI.

Reads APRS packets, decodes the positions and draws them around your
station on an ASCII "radar" map, with a station list and the latest packets.

Sources:
    COM5                 a TNC's serial port, text lines "CALL>DEST,PATH:info"
                         (PK-232 / TNC2 monitor format, or tnc134's own echo)
    COM5 --kiss          a TNC in KISS mode
    tcp:localhost:8001   KISS over TCP, e.g. Direwolf with a sound card
    file.txt             replay a log of text lines (--speed 0 = all at once)

    python aprsmap.py COM5 --home 35.0,-85.0
    python aprsmap.py tcp:localhost:8001 --home EM75 --range 50

Keys: + / - zoom, a auto range, c clear, q quit.
Symbols on the map are the station's own APRS symbol character
('-' house, '>' car, '_' weather, '#' digi, ...); '@' is you.
Needs Python 3 and, for serial ports, pyserial.
"""
import argparse
import math
import os
import queue
import re
import shutil
import socket
import sys
import threading
import time

# ---------------------------------------------------------------- decoding

TNC2 = re.compile(r'^(?:\S*?\s)?([A-Z0-9]{1,6}(?:-\d{1,2})?)>([A-Z0-9,*\-]+)(?:\s*<[^>]*>)?\s*:(.*)$')


def _uncomp(s):
    """'DDMM.mmN/DDDMM.mmW>' -> (lat, lon, table, symbol, rest) or None."""
    m = re.match(r'(\d{2})([\d ]{2}\.[\d ]{2})([NS])(.)(\d{3})([\d ]{2}\.[\d ]{2})([EW])(.)', s)
    if not m:
        return None
    lat = int(m.group(1)) + float(m.group(2).replace(' ', '0')) / 60
    lon = int(m.group(5)) + float(m.group(6).replace(' ', '0')) / 60
    if m.group(3) == 'S':
        lat = -lat
    if m.group(7) == 'W':
        lon = -lon
    return lat, lon, m.group(4), m.group(8), s[19:]


def _comp(s):
    """Compressed: table, 4+4 base-91 chars, symbol, cs, type."""
    if len(s) < 13 or not all(33 <= ord(c) <= 124 for c in s[1:9]):
        return None
    b91 = lambda t: sum((ord(c) - 33) * 91 ** (3 - i) for i, c in enumerate(t))
    lat = 90 - b91(s[1:5]) / 380926
    lon = -180 + b91(s[5:9]) / 190463
    return lat, lon, s[0], s[9], s[13:]


def _position(s):
    if not s:
        return None
    if s[0].isdigit():
        return _uncomp(s)
    if s[0] in '/\\' or s[0].isalpha():
        return _comp(s)
    return None


def _mice(dest, info):
    """Mic-E: latitude in the destination, longitude in the info field."""
    d = dest.split('-')[0]
    if len(d) != 6 or len(info) < 9:
        return None
    dig = ''
    for c in d:
        if c.isdigit():
            dig += c
        elif 'A' <= c <= 'J':
            dig += str(ord(c) - 65)
        elif 'P' <= c <= 'Y':
            dig += str(ord(c) - 80)
        elif c in 'KLZ':
            dig += '0'
        else:
            return None
    lat = int(dig[0:2]) + (int(dig[2:4]) + int(dig[4:6]) / 100) / 60
    if not ('P' <= d[3] <= 'Z'):
        lat = -lat
    off = 'P' <= d[4] <= 'Z'
    west = 'P' <= d[5] <= 'Z'
    dd = ord(info[1]) - 28 + (100 if off else 0)
    if 180 <= dd <= 189:
        dd -= 80
    elif 190 <= dd <= 199:
        dd -= 190
    mm = ord(info[2]) - 28
    if mm >= 60:
        mm -= 60
    hh = ord(info[3]) - 28
    lon = dd + (mm + hh / 100) / 60
    if west:
        lon = -lon
    if abs(lat) > 90 or abs(lon) > 180:
        return None
    return lat, lon, info[8], info[7], info[9:]


def decode(line):
    """One text line -> dict(call, lat, lon, sym, text, kind) or None."""
    m = TNC2.match(line.strip())
    if not m:
        return None
    src, path, info = m.groups()
    dest = path.split(',')[0]
    if not info:
        return None
    t = info[0]
    out = {'call': src, 'raw': line.strip(), 'lat': None, 'lon': None, 'sym': '/?',
           'text': '', 'kind': ''}
    p = None
    if t in '!=':
        p = _position(info[1:])
    elif t in '/@':
        p = _position(info[8:])
    elif t in '`\'\x1c\x1d':
        p = _mice(dest, info)
        out['kind'] = 'Mic-E'
    elif t == ';' and len(info) >= 18:          # object: name, *|_, time, position
        out['call'] = info[1:10].strip()
        out['kind'] = 'obj ' + src
        if info[10] == '_':
            out['killed'] = True
        p = _position(info[18:])
    elif t == ')':                              # item: name ! or _ position
        mm = re.match(r'\)(.{3,9}?)([!_])', info)
        if mm:
            out['call'] = mm.group(1).strip()
            out['kind'] = 'item ' + src
            if mm.group(2) == '_':
                out['killed'] = True
            p = _position(info[mm.end():])
    elif t == '}':                              # third party: decode the inner packet
        inner = decode(info[1:])
        if inner:
            inner['raw'] = line.strip()
        return inner
    elif t == ':':
        mm = re.match(r':(.{9}):(.*)', info)
        if mm:
            out['kind'] = 'msg'
            out['text'] = '%s: %s' % (mm.group(1).strip(), mm.group(2))
        return out
    elif t == '>':
        out['kind'] = 'status'
        out['text'] = info[1:]
        return out
    elif t == '_':
        out['kind'] = 'wx'
        return out
    if p:
        out['lat'], out['lon'], tab, sym, rest = p
        out['sym'] = tab + sym
        out['text'] = rest.strip()
    return out


# ---------------------------------------------------------------- KISS

def ax25_to_tnc2(frame):
    """An AX.25 UI frame (no flags, no FCS) -> 'SRC>DEST,PATH:info' or None."""
    def addr(b):
        call = ''.join(chr(x >> 1) for x in b[:6]).strip()
        ssid = (b[6] >> 1) & 15
        return call + ('-%d' % ssid if ssid else ''), b[6]
    if len(frame) < 16:
        return None
    dest, _ = addr(frame[0:7])
    src, last = addr(frame[7:14])
    path, i = [], 14
    while not last & 1 and i + 7 <= len(frame):
        a, last = addr(frame[i:i + 7])
        path.append(a + ('*' if last & 0x80 else ''))
        i += 7
    if i + 2 > len(frame) or frame[i] != 0x03 or frame[i + 1] != 0xF0:
        return None
    info = frame[i + 2:].decode('latin-1').rstrip('\r\n')
    return '%s>%s:%s' % (src, ','.join([dest] + path), info)


class Kiss:
    def __init__(self):
        self.buf, self.esc, self.inframe = bytearray(), False, False

    def feed(self, data):
        for b in data:
            if b == 0xC0:
                if self.inframe and len(self.buf) > 1 and self.buf[0] & 0x0F == 0:
                    line = ax25_to_tnc2(bytes(self.buf[1:]))
                    if line:
                        yield line
                self.buf, self.inframe = bytearray(), True
            elif self.esc:
                self.buf.append({0xDC: 0xC0, 0xDD: 0xDB}.get(b, b))
                self.esc = False
            elif b == 0xDB:
                self.esc = True
            else:
                self.buf.append(b)


# ---------------------------------------------------------------- sources

TNC = {'port': None}                # the serial port, for the command line


def send_tnc(text):
    """Send text to the serial TNC. Returns an error string or ''."""
    port = TNC['port']
    if port is None:
        return 'no serial TNC to send to'
    try:
        port.write(text.encode('latin-1'))
        return ''
    except Exception as e:
        return 'send failed: %s' % e


def is_serial(src):
    """COMn or a /dev/tty* device. (On Windows os.path.exists('COM5') is True.)"""
    return bool(re.fullmatch(r'(?i)com\d+|/dev/\S+', src))


def reader(src, kiss, baud, speed, q, send=''):
    """Thread: put text lines on q."""
    try:
        if src.startswith('tcp:'):
            _, host, port = src.split(':')
            s = socket.create_connection((host, int(port)))
            k = Kiss()
            while True:
                data = s.recv(1024)
                if not data:
                    q.put(('err', 'connection closed'))
                    return
                for line in k.feed(data):
                    q.put(('pkt', line))
        elif not is_serial(src):
            with open(src, encoding='latin-1') as f:
                for line in f:
                    if line.strip():
                        q.put(('pkt', line.rstrip('\r\n')))
                        if speed:
                            time.sleep(speed)
            q.put(('err', 'end of file'))
        else:
            import serial
            port = serial.Serial(src, baud, timeout=0.2)
            TNC['port'] = port
            if send:
                time.sleep(0.3)
                port.write(send.encode('latin-1'))
            k, buf = Kiss(), b''
            while True:
                data = port.read(256)
                if not data:
                    continue
                if kiss:
                    for line in k.feed(data):
                        q.put(('pkt', line))
                    continue
                buf += data
                while re.search(b'[\r\n]', buf):
                    line, buf = re.split(b'[\r\n]', buf, 1)
                    if line.strip():
                        q.put(('pkt', line.decode('latin-1')))
    except Exception as e:                       # shown on the status line
        q.put(('err', '%s: %s' % (src, e)))


# ---------------------------------------------------------------- geometry

def grid_to_latlon(g):
    g = g.upper()
    lon = (ord(g[0]) - 65) * 20 - 180 + int(g[2]) * 2
    lat = (ord(g[1]) - 65) * 10 - 90 + int(g[3])
    if len(g) >= 6:
        lon += (ord(g[4]) - 65) / 12 + 1 / 24
        lat += (ord(g[5]) - 65) / 24 + 1 / 48
    else:
        lon, lat = lon + 1, lat + 0.5
    return lat, lon


def dist_brg(lat1, lon1, lat2, lon2):
    """Miles and degrees true, great circle."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 3958.8 * 2 * math.asin(min(1, math.sqrt(a)))
    b = math.degrees(math.atan2(math.sin(dl) * math.cos(p2),
                                math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)))
    return d, b % 360


def nice(r):
    for n in (1, 2, 5, 10, 15, 20, 25, 50, 75, 100, 150, 200, 300, 500, 1000, 2000, 5000, 12500):
        if r <= n:
            return n
    return 12500


# ---------------------------------------------------------------- screen

CSI = '\x1b['
DIM, BOLD, RST, CYAN, GREEN, YEL = CSI + '2m', CSI + '1m', CSI + '0m', CSI + '36m', CSI + '32m', CSI + '33m'
POINTS = 'N NE E SE S SW W NW'.split()


class Map:
    def __init__(self, home, mycall, rng, units):
        self.home, self.mycall, self.rng, self.auto = home, mycall, rng, rng is None
        self.km = units == 'km'
        self.st = {}            # call -> station dict
        self.log = []           # latest raw lines
        self.status = ''
        self.heard = 0
        self.cmd = None         # text being typed on the command line, None = closed
        self.hist = []
        self.hpos = 0

    def add(self, line):
        self.heard += 1
        shown = ''.join(c if ' ' <= c <= '~' else '.' for c in line)   # Mic-E has control chars
        self.log = (self.log + [time.strftime('%H:%M ') + shown])[-50:]
        d = decode(line)
        if not d:
            return
        call = d['call']
        if d.get('killed'):
            self.st.pop(call, None)
            return
        s = self.st.setdefault(call, {'call': call, 'lat': None, 'lon': None, 'sym': '/?',
                                      'text': '', 'n': 0})
        s['n'] += 1
        s['t'] = time.time()
        if d['lat'] is not None:
            s['lat'], s['lon'], s['sym'] = d['lat'], d['lon'], d['sym']
            s['d'], s['b'] = dist_brg(self.home[0], self.home[1], d['lat'], d['lon'])
        if d['text']:
            s['text'] = d['text']
        if d['kind']:
            s['kind'] = d['kind']

    def draw(self):
        cols, rows = shutil.get_terminal_size((100, 32))
        rows -= 1
        logn = max(3, min(8, rows // 5))
        maph = rows - logn - 2
        mapw = min(cols - 30, maph * 2 + 1) if cols > 70 else cols
        mapw -= 1 - mapw % 2
        listw = cols - mapw - 1
        k = 1.609344 if self.km else 1.0
        unit = 'km' if self.km else 'mi'
        pos = [s for s in self.st.values() if s['lat'] is not None]
        if self.auto:
            far = sorted(s['d'] for s in pos)
            # range that holds 90% of the stations, so one far DX doesn't shrink everyone
            r = far[min(len(far) - 1, int(len(far) * 0.9))] * 1.1 if far else 10
            self.rng = nice(r * k) / k
        rng = self.rng
        cx, cy = mapw // 2, maph // 2
        sx = (mapw // 2) / rng            # columns per mile
        sy = (maph // 2) / rng            # rows per mile (cells are ~2:1)

        grid = [[' '] * mapw for _ in range(maph)]
        color = [[''] * mapw for _ in range(maph)]

        def put(x, y, ch, c=''):
            if 0 <= y < maph and 0 <= x < mapw:
                grid[y][x], color[y][x] = ch, c

        for ring in (0.5, 1.0):                 # range rings
            for i in range(360):
                a = math.radians(i)
                put(int(round(cx + math.sin(a) * rng * ring * sx)),
                    int(round(cy - math.cos(a) * rng * ring * sy)), '.', DIM)
        for i, lab in ((0, 'N'), (90, 'E'), (180, 'S'), (270, 'W')):
            a = math.radians(i)
            put(int(round(cx + math.sin(a) * rng * sx)), int(round(cy - math.cos(a) * rng * sy)), lab, DIM)
        half = '%g' % (rng * k / 2)
        for j, ch in enumerate(half):
            put(cx + 1 + j, int(round(cy - rng * 0.5 * sy)), ch, DIM)

        now = time.time()
        placed, used = [], {(cx, cy)}
        for s in sorted(pos, key=lambda s: s['t']):     # symbols first, newest on top
            x = cx + s['d'] * math.sin(math.radians(s['b'])) * sx
            y = cy - s['d'] * math.cos(math.radians(s['b'])) * sy
            x, y = int(round(x)), int(round(y))
            edge = not (0 <= x < mapw and 0 <= y < maph)
            x, y = min(max(x, 0), mapw - 1), min(max(y, 0), maph - 1)
            age = now - s['t']
            c = BOLD + GREEN if age < 600 else (GREEN if age < 1800 else DIM)
            put(x, y, '+' if edge else (s['sym'][1] if s['sym'][1] != ' ' else '*'), c)
            used.add((x, y))
            placed.append((s, x, y, c if not edge else DIM))
        put(cx, cy, '@', BOLD + YEL)
        for s, x, y, c in reversed(placed):             # then labels, newest first, where they fit
            lab = s['call']
            for lx in (x + 1, x - len(lab)):
                cells = range(lx - 1, lx + len(lab) + 1)    # keep a blank on each side
                if lx >= 0 and lx + len(lab) <= mapw and \
                        all((i, y) not in used or i == x for i in cells):
                    for j, ch in enumerate(lab):
                        put(lx + j, y, ch, c)
                    used.update((i, y) for i in range(lx, lx + len(lab)))
                    break

        # station list, nearest-heard first
        lst = sorted(self.st.values(), key=lambda s: -s['t'])
        side = ['%s%-*s%s' % (BOLD, listw, ' Call       %s  Brg  Age' % unit.rjust(5), RST)]
        for s in lst[:maph - 1]:
            age = int((now - s['t']) / 60)
            ages = '%dm' % age if age < 60 else '%dh' % (age // 60)
            if s['lat'] is not None:
                d = s['d'] * k
                ds = ('%5.1f' % d) if d < 100 else ('%5d' % d)
                row = ' %s%-9s %s %3d %4s' % (s['sym'][1], s['call'][:9], ds, s['b'], ages)
            else:
                row = ' %s%-9s %s %3s %4s' % (' ', s['call'][:9], '    -', '', ages)
            row += ' ' + ''.join(c if ' ' <= c <= '~' else '.' for c in s['text'])
            side.append(row[:listw].ljust(listw))

        out = [CSI + 'H']
        title = ' aprsmap  %s  home %.4f,%.4f  range %g %s%s  heard %d  stations %d ' % (
            self.mycall, self.home[0], self.home[1], rng * k, unit, ' (auto)' if self.auto else '',
            self.heard, len(self.st))
        out.append(CYAN + title[:cols].ljust(cols) + RST + '\n')
        for y in range(maph):
            ln, cur = '', None
            for x in range(mapw):
                if color[y][x] != cur:
                    ln += RST + color[y][x]
                    cur = color[y][x]
                ln += grid[y][x]
            out.append(ln + RST + DIM + '|' + RST + (side[y] if y < len(side) else ' ' * listw)[:listw] + '\n')
        out.append(DIM + '-' * cols + RST + '\n')
        for ln in (self.log[-logn:] + [''] * logn)[:logn]:
            out.append(ln[:cols].ljust(cols) + '\n')
        if self.cmd is not None:
            ln = 'TNC> ' + self.cmd + '_'
            hint = '   Enter send  Esc cancel  Up/Down history'
            out.append(BOLD + YEL + ln[-(cols - 1):] + RST + DIM + hint[:max(0, cols - 1 - len(ln))] + RST +
                       ' ' * max(0, cols - 1 - len(ln) - len(hint)))
        else:
            keys = ' : command   + - zoom  a auto  c clear  q quit   ' + self.status
            out.append(DIM + keys[:cols - 1].ljust(cols - 1) + RST)
        sys.stdout.write(''.join(out))
        sys.stdout.flush()


def keys():
    """Yield pressed keys without blocking (Windows console or a Unix tty).
    The arrow keys come back as 'UP' and 'DOWN'."""
    if os.name == 'nt':
        import msvcrt
        while msvcrt.kbhit():
            ch = msvcrt.getwch()
            if ch in '\x00\xe0':                # a special key: one more code follows
                ch = {'H': 'UP', 'P': 'DOWN'}.get(msvcrt.getwch(), '')
                if not ch:
                    continue
            yield ch
    else:
        import select
        while select.select([sys.stdin], [], [], 0)[0]:
            yield sys.stdin.read(1)


def command_key(m, ch):
    """A key while the command line is open."""
    if ch in ('\r', '\n'):
        text = m.cmd
        m.cmd = None
        if text and (not m.hist or m.hist[-1] != text):
            m.hist.append(text)
        m.hpos = len(m.hist)
        # one key (B, P, 1, ...) goes alone: tnc134 acts on single keys, and an
        # extra CR would stop a test tone at once. Longer commands end with CR.
        err = send_tnc(text if len(text) == 1 else text + '\r')
        m.log = (m.log + [time.strftime('%H:%M ') + 'TNC> ' + text])[-50:]
        m.status = err
    elif ch == '\x1b':
        m.cmd = None
    elif ch in ('\x08', '\x7f'):
        m.cmd = m.cmd[:-1]
    elif ch == 'UP' and m.hist:
        m.hpos = max(0, m.hpos - 1)
        m.cmd = m.hist[m.hpos]
    elif ch == 'DOWN' and m.hist:
        m.hpos = min(len(m.hist), m.hpos + 1)
        m.cmd = m.hist[m.hpos] if m.hpos < len(m.hist) else ''
    elif len(ch) == 1 and ' ' <= ch <= '~':
        m.cmd += ch


HERE = os.path.dirname(os.path.abspath(__file__))
TNC134 = os.path.normpath(os.path.join(HERE, '..', '..', 'tnc134', 'tnc134.hex'))


def main():
    ap = argparse.ArgumentParser(description='APRS stations on a text map.')
    ap.add_argument('source', help='COMn, /dev/ttyX, tcp:host:port (KISS) or a log file')
    ap.add_argument('--home', required=True, help='lat,lon in degrees (west/south negative) or a grid square')
    ap.add_argument('--call', default='', help='your call, shown in the title')
    ap.add_argument('--range', type=float, help='map radius (default: auto)')
    ap.add_argument('--km', action='store_true', help='kilometres instead of miles')
    ap.add_argument('--kiss', action='store_true', help='serial TNC is in KISS mode')
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--speed', type=float, default=0.3, help='seconds between lines when replaying a file')
    ap.add_argument('--log', help='append every line heard to this file')
    ap.add_argument('--send', default='', help='characters to send to a serial TNC on start, e.g. T for tnc134 test mode')
    ap.add_argument('--load', nargs='?', const=TNC134, metavar='FILE',
                    help='first load FILE (default tnc134.hex) into a W65C134SXB through its monitor and start it')
    ap.add_argument('--go', default='2000', metavar='ADDR', help='start address for --load (hex, default 2000)')
    a = ap.parse_args()

    if a.load:
        if not is_serial(a.source):
            sys.exit('--load needs a serial port as the source')
        sys.path.insert(0, os.path.join(HERE, '..', 'sxb134'))
        import sxb134
        try:
            sxb134.main([a.source, a.load, '--go', a.go, '--baud', str(a.baud)])
        except SystemExit as e:
            if e.code:
                raise
        time.sleep(1.0)                         # let the program start and print its banner

    if ',' in a.home:
        home = tuple(float(x) for x in a.home.split(','))
    else:
        home = grid_to_latlon(a.home)
    m = Map(home, a.call, a.range / (1.609344 if a.km else 1) if a.range else None, 'km' if a.km else 'mi')
    q = queue.Queue()
    threading.Thread(target=reader, args=(a.source, a.kiss, a.baud, a.speed, q, a.send), daemon=True).start()
    logf = open(a.log, 'a', encoding='latin-1') if a.log else None

    if os.name == 'nt':
        os.system('')                           # turns on ANSI escapes in the Windows console
    else:
        import termios
        import tty
        old = termios.tcgetattr(sys.stdin)
        tty.setcbreak(sys.stdin)
    sys.stdout.write(CSI + '?25l' + CSI + '2J')
    last = 0
    try:
        while True:
            dirty = False
            try:
                while True:
                    kind, val = q.get(timeout=0.1)
                    if kind == 'pkt':
                        m.add(val)
                        if logf:
                            logf.write(time.strftime('%Y-%m-%d %H:%M:%S ') + val + '\n')
                            logf.flush()
                    else:
                        m.status = val
                    dirty = True
            except queue.Empty:
                pass
            for ch in keys():
                dirty = True
                if m.cmd is not None:
                    command_key(m, ch)
                    continue
                if ch in (':', '\r', '\n'):
                    m.cmd = ''
                    m.hpos = len(m.hist)
                    continue
                if len(ch) != 1:
                    continue
                if ch in 'qQ\x1b':
                    return
                if ch in '+=':
                    m.auto, m.rng = False, max(0.5, m.rng / 2)
                elif ch in '-_':
                    m.auto, m.rng = False, min(12500, m.rng * 2)
                elif ch in 'aA':
                    m.auto = True
                elif ch in 'cC':
                    m.st.clear()
                    m.log.clear()
                    sys.stdout.write(CSI + '2J')
            if dirty or time.time() - last > 5:
                m.draw()
                last = time.time()
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write(RST + CSI + '?25h\n')
        if os.name != 'nt':
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)


if __name__ == '__main__':
    main()
