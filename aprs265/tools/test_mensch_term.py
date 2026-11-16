"""Check the baud probing against a simulated board (no hardware needed).

    python test_mensch_term.py
"""
import sys

import mensch_term as mt

HELP = (b'\r\nMENSCH ROM Version 2.03\r\n A Alter registers\r\n D Dump memory\r\n'
        b' F Fill memory\r\n G Go\r\n H Help\r\n J Jump to subroutine\r\n.')


class FakeBoard:
    """Answers like the monitor at `real` baud, sends garbage otherwise."""

    def __init__(self, baud, real, silent_when_wrong=False, banner=b''):
        self.baud, self.real, self.silent = baud, real, silent_when_wrong
        self.buf = bytearray(banner if baud == real else b'')
        self.sent = bytearray()

    @property
    def in_waiting(self):
        return len(self.buf)

    def read(self, n=1):
        d, self.buf[:] = bytes(self.buf[:n]), self.buf[n:]
        return d

    def write(self, data):
        self.sent += data
        if self.baud == self.real:
            self.buf += b'\r\n.' if data == b'\r' else HELP
        elif not self.silent:
            self.buf += bytes([0xF8, 0x80, 0x00, 0xFE, 0x9C])

    def reset_input_buffer(self):
        self.buf.clear()

    def close(self):
        pass


def run(real, **kw):
    boards = []

    def open_port(b):
        boards.append(FakeBoard(b, real, **kw))
        return boards[-1]
    found = mt.probe('COMX', mt.PROBE_ORDER, open_port=open_port,
                     log=lambda *a, **k: None)
    return found, boards


def main():
    ok = True

    def check(name, cond):
        nonlocal ok
        print(('ok   ' if cond else 'FAIL ') + name)
        ok &= bool(cond)

    found, boards = run(9600)
    check('finds 9600 on the first try', found == 9600 and len(boards) == 1)
    check('only CR and ? were sent', boards[0].sent == b'\r?')

    for real in (115200, 1200, 38400):
        found, _ = run(real)
        check('finds %d' % real, found == real)

    found, _ = run(19200, silent_when_wrong=True)
    check('finds 19200 when wrong speeds are silent', found == 19200)

    found, _ = run(250000)
    check('reports nothing when no speed works', found is None)

    check('text ratio: garbage', mt.text_ratio(b'\xf8\x80\x00\xfe') < 0.5)
    check('text ratio: text', mt.text_ratio(b'Hello\r\n') == 1.0)

    print('\nALL PASSED' if ok else '\nFAILURES')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
