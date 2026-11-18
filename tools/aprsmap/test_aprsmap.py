"""Checks for aprsmap.py: position decoding, KISS, distance, and one screen draw.

    python test_aprsmap.py
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aprsmap  # noqa: E402

ok = True


def check(cond, msg):
    global ok
    print(('  ok   ' if cond else '  FAIL ') + msg)
    ok &= bool(cond)


def near(a, b, tol=0.0005):
    return a is not None and abs(a - b) < tol


def pos(line, lat, lon, sym=None, call=None, what=''):
    d = aprsmap.decode(line)
    good = d and near(d['lat'], lat) and near(d['lon'], lon)
    if sym:
        good = good and d['sym'] == sym
    if call:
        good = good and d['call'] == call
    check(good, '%-14s %s' % (what, (d['call'], round(d['lat'], 4), round(d['lon'], 4), d['sym'])
                              if d and d['lat'] is not None else d))


def main():
    pos('KC4UMS-9>APRS,WIDE1-1,WIDE2-1*:!3500.00N/08500.00W>Mobile test', 35.0, -85.0, '/>', what='plain !')
    pos('W1AW>APRS,WIDE2-1* <UI>:!3500.00S\\01530.50E#PHG5130', -35.0, 15.508333, '\\#', what='PK-232 <UI>')
    pos('N0CALL>APRS:@092345z4903.50N/07201.75W_090/005g010t077', 49.058333, -72.029167, '/_', what='timestamp @')
    pos('N0CALL>APRS:!/5L!!<*e7>7P[', 49.5, -72.75, '/>', what='compressed')   # APRS 1.01 example
    # Mic-E for 35 12.34 N, 085 43.21 W, encoded by hand from the spec
    pos('N0CALL>351R3T,WIDE1-1:`qG1l\x1c\x1c>/', 35 + 12.34 / 60, -(85 + 43.21 / 60), '/>', what='Mic-E')
    pos('W1AW>APRS:;LEADER   *092345z4903.50N/07201.75W>088/036', 49.058333, -72.029167, call='LEADER',
        what='object')
    pos('W1AW>APRS:)AID #2!4903.50N/07201.75WA', 49.058333, -72.029167, call='AID #2', what='item')
    pos('W1AW>APRS,TCPIP*:}KC4UMS>APRS,TCPIP,W1AW*:!3500.00N/08500.00W-Home', 35.0, -85.0, '/-',
        call='KC4UMS', what='third party')
    d = aprsmap.decode('W1AW>APRS:>Net Control Center')
    check(d and d['lat'] is None and d['text'] == 'Net Control Center', 'status kept, no position')
    check(aprsmap.decode('fm W1AW to APRS ctl UI') is None, 'non-packet line ignored')

    # KISS: build a frame the way a TNC sends it
    def addr(call, last=False, h=False):
        c, _, s = call.partition('-')
        b = bytes(ord(x) << 1 for x in c.ljust(6)) + bytes([0x60 | int(s or 0) << 1 | (0x80 if h else 0) | last])
        return b
    ax = addr('APRS') + addr('KC4UMS-9') + addr('WIDE1-1', h=True) + addr('WIDE2-1', last=True) + \
        b'\x03\xF0' + b'!3500.00N/08500.00W>\xC0test'
    esc = ax.replace(b'\xDB', b'\xDB\xDD').replace(b'\xC0', b'\xDB\xDC')
    lines = list(aprsmap.Kiss().feed(b'\xC0\x00' + esc + b'\xC0'))
    check(lines == ['KC4UMS-9>APRS,WIDE1-1*,WIDE2-1:!3500.00N/08500.00W>\xC0test'], 'KISS frame -> %r' % lines)

    check([aprsmap.is_serial(x) for x in ('COM5', 'com12', '/dev/ttyUSB0', 'heard.txt', 'tcp:localhost:8001')]
          == [True, True, True, False, False], 'COM5 and /dev/tty* are serial ports, files and tcp: are not')
    d, b = aprsmap.dist_brg(35.0, -85.0, 36.0, -85.0)
    check(abs(d - 69.09) < 0.1 and abs(b) < 0.01, '1 degree north = 69.1 mi, 000 deg (%.2f, %.1f)' % (d, b))
    d, b = aprsmap.dist_brg(35.0, -85.0, 35.0, -84.0)
    check(abs(b - 89.7) < 0.2, 'due east = ~090 deg (%.1f)' % b)
    lat, lon = aprsmap.grid_to_latlon('EM75')
    check(near(lat, 35.5, 0.01) and near(lon, -85.0, 0.01), 'grid EM75 -> %.2f,%.2f' % (lat, lon))

    # one screen, with the stations above
    m = aprsmap.Map((35.0, -85.0), 'KC4UMS', None, 'mi')
    for line in ('KC4UMS-9>APRS:!3510.00N/08500.00W>car', 'W4XX>APRS:!3500.00N/08520.00W-house',
                 'N4YY>APRS:!3450.00N/08450.00W#digi', 'W1AW>APRS:>status only'):
        m.add(line)
    old, buf = sys.stdout, io.StringIO()
    sys.stdout = buf
    try:
        m.draw()
    finally:
        sys.stdout = old
    scr = buf.getvalue()
    check('KC4UMS-9' in scr and 'W4XX' in scr and '@' in scr and 'stations 4' in scr,
          'screen draws home, stations and list (%d chars)' % len(scr))
    check(m.rng == 25, 'auto range picks 25 mi for stations up to 20 mi out (%s)' % m.rng)

    # command line: what's typed goes to the TNC with a CR
    class Port:
        def __init__(self):
            self.sent = b''

        def write(self, b):
            self.sent += b
    port = Port()
    aprsmap.TNC['port'] = port
    m.cmd = ''
    for ch in 'Bx\x08\r':
        aprsmap.command_key(m, ch)
    m.cmd = ''
    for ch in 'P\r':
        aprsmap.command_key(m, ch)
    m.cmd = ''
    aprsmap.command_key(m, 'UP')
    aprsmap.command_key(m, 'UP')
    recalled = m.cmd
    aprsmap.command_key(m, '\r')
    m.cmd = ''
    for ch in 'MYCALL KC4UMS\r':
        aprsmap.command_key(m, ch)
    check(port.sent == b'BPBMYCALL KC4UMS\r' and recalled == 'B' and m.cmd is None,
          'command line: B, P, B again from history (single keys, no CR), then a long command with CR: %r'
          % port.sent)
    check(any('TNC> P' in x for x in m.log), 'sent commands are shown in the log')
    m.cmd = 'S'
    old, buf = sys.stdout, io.StringIO()
    sys.stdout = buf
    try:
        m.draw()
    finally:
        sys.stdout = old
    check('TNC> S_' in buf.getvalue(), 'command line drawn at the bottom')
    aprsmap.TNC['port'] = None
    m.cmd = ''
    for ch in 'B\r':
        aprsmap.command_key(m, ch)
    check('no serial TNC' in m.status, 'without a serial TNC it says so')

    print('ALL PASSED' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
