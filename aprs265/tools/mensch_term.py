"""Find the baud rate of a W65C265S / Mensch Monitor board, then open a terminal.

    python mensch_term.py --list           show serial ports
    python mensch_term.py COM5             probe baud rates, then open a terminal
    python mensch_term.py COM5 --baud 9600 skip probing

In the terminal:
    Ctrl+U   upload a file (e.g. ..\\aprsrx.s28), line by line
    Ctrl+]   quit
Everything else, including ESC, is sent to the board.

Probing sends a carriage return at each speed and checks whether readable
text comes back, then sends '?' (the monitor's help command) to confirm.
9600 is tried first because that is the monitor's default, so usually no
bytes are sent at a wrong speed. If the board acts oddly after probing,
press its reset button.
"""
import argparse
import os
import sys
import threading
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit('pyserial is missing:  pip install pyserial')

PROBE_ORDER = [9600, 19200, 38400, 57600, 115200, 4800, 2400, 1200]

KEYWORDS = [b'mensch', b'wdc', b'copyright', b'pcntr', b'xreg', b'alter', b'dump',
            b'fill', b'help', b'memory', b'register']

QUIT_KEY = '\x1d'       # Ctrl+]
UPLOAD_KEY = '\x15'     # Ctrl+U


# ------------------------------------------------------------------ probing
def text_ratio(data):
    """Fraction of bytes that are printable ASCII or CR/LF/TAB."""
    if not data:
        return 0.0
    good = sum(1 for b in data if 0x20 <= b <= 0x7E or b in (9, 10, 13))
    return good / len(data)


def read_for(port, seconds):
    end = time.time() + seconds
    buf = bytearray()
    while time.time() < end:
        n = port.in_waiting
        if n:
            buf += port.read(n)
        else:
            time.sleep(0.02)
    return bytes(buf)


def probe_one(port):
    """Return (verdict, sample) where verdict is 'confirmed', 'likely' or 'no'."""
    port.reset_input_buffer()
    got = read_for(port, 0.3)              # anything already arriving (banner)
    port.write(b'\r')
    got += read_for(port, 0.8)
    if len(got.strip()) < 1 or text_ratio(got) < 0.9:
        return 'no', got
    port.write(b'?')                       # monitor help: lists the commands
    got += read_for(port, 1.5)
    if text_ratio(got) < 0.9:
        return 'no', got
    low = got.lower()
    hits = sum(1 for k in KEYWORDS if k in low)
    lines = [ln for ln in got.replace(b'\r', b'\n').split(b'\n') if ln.strip()]
    if hits >= 2 or len(lines) >= 5:
        return 'confirmed', got
    return 'likely', got


def probe(portname, bauds, rtscts=False, open_port=None, log=print):
    """Try each baud. Returns the working baud or None."""
    open_port = open_port or (lambda b: serial.Serial(portname, b, timeout=0.1,
                                                      write_timeout=1, rtscts=rtscts))
    likely = None
    for baud in bauds:
        log('  trying %6d ... ' % baud, end='')
        try:
            port = open_port(baud)
        except serial.SerialException as e:
            log('cannot open port: %s' % e)
            return None
        try:
            verdict, sample = probe_one(port)
        except serial.SerialTimeoutException:
            log('blocked (the board is holding CTS off)')
            port.close()
            continue
        finally:
            port.close()
        if verdict == 'confirmed':
            log('Mensch Monitor answered')
            return baud
        if verdict == 'likely':
            log('readable reply, but no monitor help text')
            likely = likely or baud
        else:
            log('no (%s)' % ('silent' if not sample.strip() else 'garbage'))
    return likely


# ------------------------------------------------------------------ terminal
def reader(port, stop, logfile):
    out = sys.stdout
    while not stop.is_set():
        try:
            data = port.read(port.in_waiting or 1)
        except serial.SerialException:
            out.write('\n[serial port lost]\n')
            stop.set()
            break
        if data:
            text = data.decode('latin-1')
            out.write(text)
            out.flush()
            if logfile:
                logfile.write(text)
                logfile.flush()


def upload(port, path, line_delay):
    try:
        with open(path, 'rb') as f:
            lines = f.read().splitlines()
    except OSError as e:
        print('\n[upload failed: %s]' % e)
        return
    print('\n[sending %d lines from %s]' % (len(lines), path))
    for i, ln in enumerate(lines, 1):
        port.write(ln.rstrip() + b'\r')
        port.flush()
        time.sleep(line_delay)
        if i % 50 == 0:
            print('[%d/%d]' % (i, len(lines)))
    print('[upload done]')


def get_key():
    import msvcrt
    ch = msvcrt.getwch()
    if ch in ('\x00', '\xe0'):             # arrow / function key: ignore
        msvcrt.getwch()
        return None
    return ch


def terminal(portname, baud, rtscts, line_delay, logpath):
    port = serial.Serial(portname, baud, timeout=0.1, rtscts=rtscts)
    logfile = open(logpath, 'a', encoding='latin-1') if logpath else None
    stop = threading.Event()
    t = threading.Thread(target=reader, args=(port, stop, logfile), daemon=True)
    t.start()
    print('--- %s at %d 8N1%s.  Ctrl+U upload file, Ctrl+] quit ---'
          % (portname, baud, ', RTS/CTS' if rtscts else ''))
    port.write(b'\r')
    try:
        if os.name != 'nt':
            for line in sys.stdin:             # simple line mode elsewhere
                port.write(line.rstrip('\n').encode('latin-1') + b'\r')
            return
        while not stop.is_set():
            ch = get_key()
            if ch is None:
                continue
            if ch == QUIT_KEY:
                break
            if ch == UPLOAD_KEY:
                path = input('\nfile to send: ').strip().strip('"')
                if path:
                    upload(port, path, line_delay)
                continue
            port.write(ch.encode('latin-1', 'replace'))
    except KeyboardInterrupt:
        port.write(b'\x03')
    finally:
        stop.set()
        t.join(0.5)
        port.close()
        if logfile:
            logfile.close()
        print('\n--- closed ---')


def listen(portname, baud, rtscts, seconds):
    """Send nothing; print what arrives so a reset banner can be seen."""
    port = serial.Serial(portname, baud, timeout=0.1, rtscts=rtscts)
    print('Listening on %s at %d for %d s. Press RESET on the board now.'
          % (portname, baud, seconds))
    got = bytearray()
    end = time.time() + seconds
    while time.time() < end:
        data = port.read(port.in_waiting or 1)
        if data:
            got += data
            sys.stdout.write(data.decode('latin-1'))
            sys.stdout.flush()
    port.close()
    print('\n--- %d bytes received ---' % len(got))
    if got:
        print('hex: ' + got[:48].hex(' ') + (' ...' if len(got) > 48 else ''))
        if text_ratio(bytes(got)) >= 0.9:
            print('Readable text: %d baud is right.' % baud)
        else:
            print('Garbage: the board is talking at a different speed. '
                  'Try --listen --baud 19200, 38400, 115200 ...')
    else:
        print('Nothing arrived: check the cable/port, power, and that the board resets.')
    return 0 if got else 1


# ------------------------------------------------------------------ main
def list_ports():
    ports = list(serial.tools.list_ports.comports())
    if not ports:
        print('no serial ports found')
    for p in ports:
        desc = p.description + ' ' + (p.manufacturer or '')
        tag = '   <- USB serial chip, probably the board' \
            if any(k in desc for k in ('FTDI', 'FT232', 'CH340', 'CH341')) else ''
        print('%-8s %s%s' % (p.device, p.description, tag))


def main(argv=None):
    ap = argparse.ArgumentParser(description='Mensch Monitor baud finder and terminal')
    ap.add_argument('port', nargs='?', help='COM port, e.g. COM5')
    ap.add_argument('--list', action='store_true', help='list serial ports and exit')
    ap.add_argument('--baud', type=int, help='skip probing and use this speed')
    ap.add_argument('--bauds', help='comma-separated speeds to probe, in order')
    ap.add_argument('--rtscts', action='store_true', help='use RTS/CTS flow control')
    ap.add_argument('--probe-only', action='store_true', help='report the speed and exit')
    ap.add_argument('--line-delay', type=float, default=0.05,
                    help='seconds between lines when uploading (default 0.05)')
    ap.add_argument('--log', help='append everything received to this file')
    ap.add_argument('--listen', type=float, nargs='?', const=20, metavar='SECONDS',
                    help='send nothing; show what arrives (press RESET meanwhile)')
    a = ap.parse_args(argv)

    if a.list or not a.port:
        list_ports()
        if not a.port:
            print('\nusage: python mensch_term.py COMx')
        return 0

    if a.listen:
        return listen(a.port, a.baud or 9600, a.rtscts, a.listen)

    baud = a.baud
    if not baud:
        bauds = [int(b) for b in a.bauds.split(',')] if a.bauds else PROBE_ORDER
        print('Probing %s (8N1%s)...' % (a.port, ', RTS/CTS' if a.rtscts else ''))
        baud = probe(a.port, bauds, a.rtscts)
        if not baud:
            print('\nNo speed worked. Things to try:')
            print('  - press RESET on the board and run again')
            print('  - run again with --rtscts')
            print('  - run with --listen and press RESET to see what the board sends')
            print('  - check the port with --list')
            return 1
        print('\nUsing %d baud.' % baud)
    if a.probe_only:
        return 0
    terminal(a.port, baud, a.rtscts, a.line_delay, a.log)
    return 0


if __name__ == '__main__':
    sys.exit(main())
