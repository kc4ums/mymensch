"""sxb134 - load and run programs on a W65C134SXB through its ROM monitor.

Replaces EasySXB for everyday work. It talks to the monitor in the
W65C134S's mask ROM over the board's USB serial port (FTDI, 9600 8N1), using
only the monitor's own commands (from WDC's ROM listing, 134iromlist.pdf):

  S1.../S2...<CR>   one Motorola S-record; the monitor answers with a new
                    "." prompt, or with a beep and "E aaaa  nn" on a bad
                    checksum. Records are sent one at a time, each after
                    the prompt for the last, so no handshake lines are needed.
  E                 print and clear the load error count
  Wsssseeee<CR>     dump memory back as S1 records (used to verify)
  Gaaaa / Jaaaa     JMP / JSR to an address (the monitor types the space)

    python sxb134.py PORT FILE [options]

FILE is .s19/.s28/.srec (addresses taken from the file), .hex (Intel HEX),
or .bin with --addr. Examples:

    python sxb134.py COM5 amtor_ram.s19 --go 2000 --term
    python sxb134.py COM5 tnc134.hex --go 2000
    python sxb134.py COM5 data.bin --addr 4000 --no-verify
    python sxb134.py COM5 --term                (just a terminal)

Options:
  --go ADDR      start the program with G (JMP) after loading
  --jsr ADDR     start it with J (JSR; an RTS returns to the monitor)
  --no-verify    skip reading the memory back
  --term         stay connected as a terminal afterwards (Ctrl-] quits)
  --baud N       default 9600 (the monitor's rate on the SXB)
  --chunk N      data bytes per record, default 32
  --flash        write FILE ($8000-$EFFF) into the SXB's flash (SST39SF010A)
                 instead of RAM, using flash134.s19 run from RAM at $7000
  --bank N       flash bank 0-3 (default 3: the one the board boots from)
  --unflash      erase the flash sector at $8000 of the bank, removing the
                 'WDC' signature so the board starts in the monitor again

Flash: the program goes into the bank the ROM monitor looks at after a
reset; if it starts with 'WDC' at $8000, the board runs it from $8004 at
every power-up. Each 4 KB sector it touches is erased and rewritten, then
the whole range is read back. The flash writer uses RAM $1000-$1FFF and
$7000-$70FF, so it overwrites whatever program was loaded there.
"""
import argparse
import os
import re
import sys
import time

# the prompt: a '.' after a line end. The real W65C134SXB ROM sends CR only;
# CR LF is accepted too.
PROMPT = (b'\r.', b'\n.')
BEL = 0x07


class LoadError(Exception):
    pass


# ---------------------------------------------------------------- files
def read_image(path, addr=None):
    """Return {address: byte} from S19/S28/S37, Intel HEX or raw binary."""
    ext = os.path.splitext(path)[1].lower()
    mem = {}
    if ext == '.bin':
        if addr is None:
            raise LoadError('a .bin file needs --addr')
        data = open(path, 'rb').read()
        for i, b in enumerate(data):
            mem[addr + i] = b
        return mem
    text = open(path, encoding='latin-1').read().split()
    if ext == '.hex' or (text and text[0].startswith(':')):
        base = 0
        for n, line in enumerate(text, 1):
            if not line.startswith(':'):
                continue
            raw = bytes.fromhex(line[1:])
            if sum(raw) & 0xFF:
                raise LoadError('%s line %d: bad checksum' % (path, n))
            cnt, a, typ = raw[0], (raw[1] << 8) | raw[2], raw[3]
            if typ == 0:
                for i in range(cnt):
                    mem[base + a + i] = raw[4 + i]
            elif typ == 2:
                base = ((raw[4] << 8) | raw[5]) << 4
            elif typ == 4:
                base = ((raw[4] << 8) | raw[5]) << 16
            elif typ == 1:
                break
        return mem
    for n, line in enumerate(text, 1):
        if len(line) < 4 or line[0] != 'S' or line[1] not in '123':
            continue
        raw = bytes.fromhex(line[2:])
        if (sum(raw) & 0xFF) != 0xFF:
            raise LoadError('%s line %d: bad checksum' % (path, n))
        alen = {'1': 2, '2': 3, '3': 4}[line[1]]
        a = int.from_bytes(raw[1:1 + alen], 'big')
        for i, b in enumerate(raw[1 + alen:-1]):
            mem[a + i] = b
    return mem


def segments(mem):
    """Contiguous runs: [(start, bytes)]."""
    out = []
    for a in sorted(mem):
        if out and out[-1][0] + len(out[-1][1]) == a:
            out[-1][1].append(mem[a])
        else:
            out.append((a, bytearray([mem[a]])))
    return out


def s1(addr, data):
    raw = bytes([len(data) + 3, addr >> 8, addr & 0xFF]) + bytes(data)
    return 'S1' + raw.hex().upper() + '%02X' % (~sum(raw) & 0xFF)


# ---------------------------------------------------------------- monitor
class Monitor:
    def __init__(self, port, log=None):
        self.port = port
        self.log = log

    def _read_until(self, end, timeout):
        buf = bytearray()
        t0 = time.time()
        while not buf.endswith(end):
            c = self.port.read(1)
            if c:
                buf += c
                t0 = time.time()
            elif time.time() - t0 > timeout:
                raise TimeoutError(bytes(buf))
        if self.log:
            self.log(bytes(buf))
        return bytes(buf)

    def sync(self, wait_reset=30.0):
        """Get to a fresh '.' prompt. Asks for RESET if the board is silent."""
        self.port.reset_input_buffer()
        for _ in range(3):
            self.port.write(b'\r')
            try:
                self._read_until(PROMPT, 0.7)
                time.sleep(0.05)
                self.port.reset_input_buffer()
                return True
            except TimeoutError:
                pass
        print('No monitor prompt. Press RESET on the SXB (waiting %d s)...' % wait_reset)
        t0 = time.time()
        buf = bytearray()
        while time.time() - t0 < wait_reset:
            c = self.port.read(64)
            buf += c
            if buf.endswith(b'.') or any(p in buf for p in PROMPT):
                time.sleep(0.3)
                self.port.reset_input_buffer()
                return True
        raise LoadError('the SXB monitor is not answering. Check the port, '
                        'the USB cable and that the board is powered')

    def command(self, text, timeout=2.0):
        self.port.write(text.encode())
        return self._read_until(PROMPT, timeout)

    def errors(self):
        """E: (address, count); also clears the count."""
        r = self.command('E').decode('latin-1')
        m = re.search(r'E ([0-9A-F]{4})\s+([0-9A-F]{2})', r)
        if not m:
            raise LoadError('unexpected reply to E: %r' % r)
        return int(m.group(1), 16), int(m.group(2), 16)

    def send_record(self, rec, retries=3):
        for attempt in range(retries + 1):
            r = self.command(rec + '\r', timeout=3.0)
            if BEL not in r and b'E ' not in r:
                return attempt
            self.errors()                     # clear the count before retrying
        raise LoadError('record rejected %d times: %s' % (retries + 1, rec))

    def upload(self, mem, chunk=32, progress=None):
        self.errors()
        total = len(mem)
        done = retried = 0
        for start, data in segments(mem):
            for off in range(0, len(data), chunk):
                piece = data[off:off + chunk]
                retried += self.send_record(s1(start + off, piece))
                done += len(piece)
                if progress:
                    progress(done, total)
        return retried

    def dump(self, start, end):
        """W: read $start-$end back. Returns {address: byte}."""
        self.port.write(('W%04X%04X' % (start, end)).encode())
        time.sleep(0.05)
        self.port.write(b'\r')
        n = end - start + 1
        r = self._read_until(PROMPT, 3.0 + n / 40).decode('latin-1')
        mem = {}
        for line in r.split():
            if line.startswith('S1') and len(line) >= 10:
                raw = bytes.fromhex(line[2:])
                if (sum(raw) & 0xFF) != 0xFF:
                    raise LoadError('bad checksum reading back: ' + line)
                a = (raw[1] << 8) | raw[2]
                for i, b in enumerate(raw[3:-1]):
                    mem[a + i] = b
        return mem

    def verify(self, mem):
        bad = []
        for start, data in segments(mem):
            back = self.dump(start, start + len(data) - 1)
            for i, b in enumerate(data):
                if back.get(start + i) != b:
                    bad.append(start + i)
        return bad

    # ---- flash (SST39SF010A via flash134.s19) ----
    FLASHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'flash134.s19')
    PBLOCK, STAGE = 0x7003, 0x1000

    def load_flasher(self):
        mem = read_image(self.FLASHER)
        self.upload(mem)
        if self.verify(mem):
            raise LoadError('the flash writer did not load correctly')

    def flasher(self, op, bank=3, dst=0x8000, src=0x1000, length=0x1000):
        p = bytes([op, bank]) + dst.to_bytes(2, 'little') + src.to_bytes(2, 'little') +             length.to_bytes(2, 'little') + bytes([0xEE])
        self.send_record(s1(self.PBLOCK, p))
        self.port.write(b'J7000')
        r = self._read_until(PROMPT, 15.0)
        back = self.dump(self.PBLOCK + 8, self.PBLOCK + 10)
        st = back.get(self.PBLOCK + 8)
        bad = back.get(self.PBLOCK + 9, 0) | (back.get(self.PBLOCK + 10, 0) << 8)
        if st != 0:
            why = {1: 'bad parameters', 2: 'erase timed out', 3: 'program timed out',
                   4: 'verify mismatch', 0xEE: 'the writer did not run'}.get(st, 'status %r' % st)
            raise LoadError('flash %s at $%04X (%s)' % (why, bad, r.decode('latin-1').strip()))

    def flash(self, mem, bank=3, progress=None):
        self.load_flasher()
        sectors = sorted({a & 0xF000 for a in mem})
        total = len(sectors)
        for n, sa in enumerate(sectors):
            part = {a: v for a, v in mem.items() if sa <= a < sa + 0x1000}
            self.flasher(4)                                   # staging := $FF
            self.upload({self.STAGE + a - sa: v for a, v in part.items() if v != 0xFF})
            self.flasher(3, bank, sa, self.STAGE, 0x1000)     # erase + program + verify
            if progress:
                progress(n + 1, total)
        return sectors

    def unflash(self, bank=3):
        self.load_flasher()
        self.flasher(1, bank, 0x8000, self.STAGE, 0)

    def run(self, addr, jsr=False):
        self.port.write(('%s%04X' % ('J' if jsr else 'G', addr)).encode())


def terminal(port):
    """Plain terminal until Ctrl-]."""
    import threading
    print('--- terminal: Ctrl-] to quit ---')
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            data = port.read(256)
            if data:
                sys.stdout.write(data.decode('latin-1'))
                sys.stdout.flush()
    t = threading.Thread(target=reader, daemon=True)
    t.start()
    try:
        if os.name == 'nt':
            import msvcrt
            while True:
                ch = msvcrt.getwch()
                if ch == '\x1d':
                    break
                if ch in ('\x00', '\xe0'):
                    msvcrt.getwch()
                    continue
                port.write(ch.encode('latin-1', 'replace'))
        else:
            import termios
            import tty
            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            tty.setraw(fd)
            try:
                while True:
                    ch = sys.stdin.read(1)
                    if ch == '\x1d':
                        break
                    port.write(ch.encode('latin-1', 'replace'))
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
    finally:
        stop.set()
        print('\n--- bye ---')


def main(argv=None):
    ap = argparse.ArgumentParser(description='Load and run programs on a W65C134SXB.')
    ap.add_argument('port', help='serial port, e.g. COM5 or /dev/ttyUSB0')
    ap.add_argument('file', nargs='?', help='.s19 .s28 .hex or .bin')
    ap.add_argument('--addr', type=lambda s: int(s, 16), help='load address for .bin (hex)')
    ap.add_argument('--go', type=lambda s: int(s, 16), metavar='ADDR', help='JMP here after loading')
    ap.add_argument('--jsr', type=lambda s: int(s, 16), metavar='ADDR', help='JSR here after loading')
    ap.add_argument('--no-verify', action='store_true')
    ap.add_argument('--term', action='store_true', help='terminal afterwards (Ctrl-] quits)')
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--chunk', type=int, default=32)
    ap.add_argument('--flash', action='store_true', help='write FILE into flash ($8000-$EFFF)')
    ap.add_argument('--bank', type=int, default=3, choices=range(4), help='flash bank (default 3, the boot bank)')
    ap.add_argument('--unflash', action='store_true', help="erase the 'WDC' signature sector")
    a = ap.parse_args(argv)

    import serial
    try:
        port = serial.Serial(a.port, a.baud, timeout=0.05)
    except serial.SerialException as e:
        sys.exit('cannot open %s: %s' % (a.port, e))
    port.dtr = True                     # the monitor's DSR input (P47)
    port.rts = True
    mon = Monitor(port)
    try:
        if a.unflash:
            mon.sync()
            mon.unflash(a.bank)
            print('  erased flash $8000-$8FFF (bank %d): the board will start in the monitor' % a.bank)
        if a.file and a.flash:
            mem = read_image(a.file, a.addr)
            lo, hi = min(mem), max(mem)
            if lo < 0x8000 or hi > 0xEFFF:
                sys.exit('%s covers $%04X-$%04X; flash is $8000-$EFFF' % (a.file, lo, hi))
            print('%s: %d bytes, $%04X-$%04X -> flash bank %d' % (os.path.basename(a.file), len(mem), lo, hi, a.bank))
            if mem.get(0x8000) == 0x57 and mem.get(0x8001) == 0x44 and mem.get(0x8002) == 0x43:
                print("  it starts with 'WDC': the board will run it at every power-up")
            mon.sync()
            t0 = time.time()

            def fbar(done, total):
                sys.stdout.write('\r  flashing sector %d of %d' % (done, total))
                sys.stdout.flush()
            sectors = mon.flash(mem, a.bank, fbar)
            print('\r  wrote %d sector(s) in %.1f s%s' % (len(sectors), time.time() - t0, ' ' * 20))
            if a.bank == 3 and not a.no_verify:
                bad = mon.verify(mem)
                if bad:
                    sys.exit('  VERIFY FAILED at %d addresses, first $%04X' % (len(bad), bad[0]))
                print('  verified (read back through the monitor)')
        elif a.file:
            mem = read_image(a.file, a.addr)
            if not mem:
                sys.exit('%s: no data' % a.file)
            lo, hi = min(mem), max(mem)
            if hi >= 0x8000 or lo < 0x0200:
                sys.exit('%s covers $%04X-$%04X; only RAM $0200-$7FFF can be loaded '
                         'through the monitor' % (a.file, lo, hi))
            print('%s: %d bytes, $%04X-$%04X' % (os.path.basename(a.file), len(mem), lo, hi))
            mon.sync()
            t0 = time.time()

            def bar(done, total):
                n = 30 * done // total
                sys.stdout.write('\r  loading [%s%s] %3d%%' % ('#' * n, '.' * (30 - n), 100 * done // total))
                sys.stdout.flush()
            retried = mon.upload(mem, a.chunk, bar)
            print('\r  loaded %d bytes in %.1f s%s%s' % (
                len(mem), time.time() - t0,
                ', %d records resent' % retried if retried else '', ' ' * 20))
            if not a.no_verify:
                bad = mon.verify(mem)
                if bad:
                    sys.exit('  VERIFY FAILED at %d addresses, first $%04X' % (len(bad), bad[0]))
                print('  verified')
        start = a.go if a.go is not None else a.jsr
        if start is not None:
            if not a.file:
                mon.sync()
            mon.run(start, jsr=a.jsr is not None)
            print('  started at $%04X (%s)' % (start, 'JSR' if a.jsr is not None else 'JMP'))
        if a.term:
            terminal(port)
    except LoadError as e:
        sys.exit('error: %s' % e)
    except TimeoutError as e:
        sys.exit('error: no "." prompt from the monitor; it last sent %r' % (e.args[0][-60:] if e.args else b''))
    finally:
        port.close()


if __name__ == '__main__':
    main()
