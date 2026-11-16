"""Run aprsrx.s28 in the emulator against PK-232 style monitor lines.

    python run_tests.py          run all checks
    python run_tests.py -v       also print the console output
"""
import os
import sys

from emu65816 import Board, load_s28

HERE = os.path.dirname(os.path.abspath(__file__))
S28 = os.path.join(HERE, '..', 'aprsrx.s28')

# (line sent by the TNC, strings that must appear in the decoded output)
CASES = [
    ('KC4UMS-9>APRS,WIDE1-1,WIDE2-1*:!3500.00N/08500.00W>Mobile test',
     ['KC4UMS-9 > APRS via WIDE1-1,WIDE2-1*', 'Pos    35 00.00N  085 00.00W',
      'Sym    /> car', 'Cmt    Mobile test']),
    # PK-232 frame type tag before the colon
    ('W1AW>APRS,WIDE2-1* <UI>:!3500.00S\\01530.50E#PHG5130/W2 digi /A=001234',
     ['W1AW > APRS via WIDE2-1*', 'Pos    35 00.00S  015 30.50E', '(alternate/overlay)',
      'PHG    5130', 'Cmt    /W2 digi /A=001234', 'Alt    001234 ft']),
    ('N0CALL>APRS:@092345z4903.50N/07201.75W_090/005g010t077r001p010P005h50b10132wRSW',
     ['Time   092345z', 'Pos    49 03.50N  072 01.75W', 'weather station',
      'Wind 090/005mph', 'Gust 10mph', 'Temp 77F', 'Rain1h 0.01in', 'Rain24h 0.10in',
      'RainToday 0.05in', 'Hum 50%', 'Baro 1013.2mb', 'Cmt    wRSW']),
    ('N0CALL>APRS:!/5L!!<*e7>7P[',
     ['Pos    49 30.00N  072 45.00W', 'Course 088', 'Speed 36 kt', 'Sym    /> car']),
    ('N0CALL>SS2UVT,WIDE1-1:`(_fnPO>/]"4T}=',
     ['N0CALL > SS2UVT via WIDE1-1', 'Pos    33 25.64N  112 07.74W', 'Course 251',
      'Speed 25 kt', 'Mic-E  En Route', 'Alt    61 m', 'Cmt    ]"4T}=']),
    ('KC4UMS>APRS::N0CALL   :Hello there{123',
     ['Msg to N0CALL', 'Text   Hello there', 'Msg ID 123']),
    ('N0CALL>APRS::KC4UMS   :ack123', ['Msg to KC4UMS', 'ACK    id 123']),
    ('W1AW>APRS::BLN1     :Net tonight 8pm', ['Bulletin BLN1', 'Text   Net tonight 8pm']),
    ('W1AW>APRS:;LEADER   *092345z4903.50N/07201.75W>088/036',
     ['Object LEADER (live)', 'Time   092345z', 'Pos    49 03.50N  072 01.75W',
      'Course 088  Speed 036 kt']),
    ('W1AW>APRS:;OLD      _092345z4903.50N/07201.75W>', ['Object OLD (killed)']),
    ('W1AW>APRS:)AID #2!4903.50N/07201.75WA', ['Item   AID #2 (live)', 'aid station']),
    ('W1AW>APRS:>Net Control Center', ['Status Net Control Center']),
    ('W1AW>APRS:_10090556c220s004g005t077r000p000P000h50b09900wRSW',
     ['Time   10090556', 'WindDir 220deg', 'Wind 4mph', 'Gust 5mph', 'Temp 77F',
      'Hum 50%', 'Baro 990.0mb', 'Cmt    wRSW']),
    ('W1AW>APRS:_10090556c...s...g...t-05h00', ['Temp -5F', 'Hum 100%']),
    ('W1AW>APRS,TCPIP*:}KC4UMS>APRS,TCPIP,W1AW*:!3500.00N/08500.00W-Home',
     ['Third-party packet:', 'KC4UMS > APRS via TCPIP,W1AW*', 'house', 'Cmt    Home']),
    ('W1AW>APRS:T#005,199,000,255,073,123,01101001', ['Telemetry T#005,199']),
    ('W1AW>APRS:!garbage', ['bad/unknown format']),
    ('N0CALL>SSSSSS:`(_fnPO>/', ['Mic-E  Off Duty']),
    ('N0CALL>APRS:`(_fnPO>/', ['bad Mic-E destination: APRS']),
    ('cmd:', ['TNC| cmd:']),
    ('*** CONNECTED to W1AW', ['TNC| *** CONNECTED to W1AW']),
]

# HEADERLN ON: header and info on separate lines
HEADERLN = ('W1AW>APRS,WIDE2-1:', '>status on its own line',
            ['W1AW > APRS via WIDE2-1', 'Status status on its own line'])


def run(lines, parity=False, keys=b'\x1b', early=b'', **kw):
    board = Board(load_s28(S28), **kw)
    data = bytearray()
    for ln in lines:
        b = (ln + '\r\n').encode('latin-1')
        if parity:                      # 7E1: set bit 7 as even parity
            b = bytes(c | (0x80 if bin(c).count('1') % 2 else 0) for c in b)
        data += b
    board.rx = data
    board.keys = list(keys)
    board.early_keys = list(early)
    reason = board.run()
    return board, reason, board.cpu.out.decode('latin-1')


def check(name, out, wants):
    missing = [w for w in wants if w not in out]
    if missing:
        print('FAIL', name)
        for w in missing:
            print('   missing:', repr(w))
        return False
    print('ok  ', name)
    return True


def main():
    verbose = '-v' in sys.argv
    good = True

    lines = [c[0] for c in CASES] + list(HEADERLN[:2])
    board, reason, out = run(lines)
    if verbose:
        print(out)
    good &= check('program exits on ESC via BRK', reason, ['BRK'])
    for i, (line, wants) in enumerate(CASES):
        # each packet's block runs from its own "#nnnn" to the next one
        good &= check(line[:50], out, wants)
    good &= check('HEADERLN ON', out, HEADERLN[2])

    cpu = board.cpu
    good &= check('stack restored', 'S=%04X' % cpu.s, ['S=01ED'])
    good &= check('T7 vector restored', cpu.mem[0x011C:0x0120].hex(), ['5cb0e000'])
    good &= check('T7 interrupt disabled', '%02X' % (cpu.mem[0xDF46] & 0x80), ['00'])
    good &= check('no UART overruns', str(board.overruns), ['0'])
    good &= check('ISR ran', str(board.isr_count > 1000), ['True'])

    _, _, out7 = run([CASES[0][0]], parity=True)
    good &= check('7E1 parity bit stripped', out7, CASES[0][1])

    # keys: S = stats, R = raw on
    _, _, outk = run([CASES[0][0]], keys=b'Sr\x1b')
    good &= check('stats key', outk, ['pkts 1', 'uart errors 0', 'buffer overflows 0'])
    good &= check('raw toggle', outk, ['[raw on]'])
    _, _, outr = run(['W1AW>APRS:>one', 'W1AW>APRS:>two'], early=b'R')
    good &= check('raw mode output', outr, ['raw| W1AW>APRS:>one', 'raw| W1AW>APRS:>two',
                                            'Status two'])

    # a long line is truncated and counted
    _, _, outl = run(['W1AW>APRS:>' + 'x' * 400, 'W1AW>APRS:>after'], keys=b'S\x1b')
    good &= check('long line counted, next line fine', outl, ['long lines 1', 'Status after'])

    # TNC bursts: bytes arriving 4x faster than 9600 baud would allow
    lines = [c[0] for c in CASES]
    _, _, out1 = run(lines, keys=b'S\x1b')
    one = out1.split('pkts ')[1].split()[0]
    b4, _, outf = run(lines * 3, byte_period=240, keys=b'S\x1b')
    good &= check('fast burst: no overruns', str(b4.overruns), ['0'])
    good &= check('fast burst: every packet decoded (%s x 3)' % one, outf,
                  ['pkts %d ' % (int(one) * 3), 'buffer overflows 0'])

    # bytes faster than the Timer 7 poll: UART overruns must be counted, not crash
    b5, r5, out5 = run(lines[:3], byte_period=60, keys=b'S\x1b')
    good &= check('overrun: still exits cleanly', r5, ['BRK'])
    # several overruns between two polls latch into one ACSR0 error flag
    errs = int(out5.split('uart errors ')[1].split()[0])
    good &= check('overrun: errors counted (%d)' % errs, str(0 < errs <= b5.overruns), ['True'])

    print('\nALL PASSED' if good else '\nFAILURES')
    return 0 if good else 1


if __name__ == '__main__':
    sys.exit(main())
