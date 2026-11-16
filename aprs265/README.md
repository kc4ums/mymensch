# APRS receiver: AEA PK-232 → WDC W65C265SXB (W65C265S)

> **Not for the MyMENSCH.** This version targets WDC's W65C265SXB (W65C265S chip with the Mensch Monitor ROM). The MyMENSCH Rev-C version is in `../aprs/`. `tools/mensch_term.py` (the baud finder) also only applies to the W65C265SXB, because the MyMENSCH talks WDC's binary uploader protocol instead of a text console.


Receive-only for now. The PK-232 decodes packets off the air and prints each one as a text line. The MyMensch reads those lines on **UART0**, decodes the APRS content, and prints it on the Mensch Monitor console (the USB/UART3 terminal you already use).

```
#0002 N0CALL > SS2UVT via WIDE1-1
  Pos    33 25.64N  112 07.74W
  Sym    /> car
  Course 251  Speed 25 kt
  Mic-E  En Route
  Alt    61 m
  Cmt    ]"4T}=

#0003 N0CALL > APRS
  Time   092345z
  Pos    49 03.50N  072 01.75W
  Sym    /_ weather station
  WX     Wind 090/005mph Gust 10mph Temp 77F Rain1h 0.01in Rain24h 0.10in RainToday 0.05in Hum 50% Baro 1013.2mb
  Cmt    wRSW
```

## What gets decoded

| APRS type | Shown |
|---|---|
| Position `!` `=` `/` `@` (plain and compressed) | lat/lon, symbol name, course/speed, PHG/RNG/DFS, `/A=` altitude, comment |
| Mic-E `` ` `` `'` | lat/lon, course/speed, message (En Route, In Service…), altitude, comment |
| Weather (`_` positionless, or a position with the `_` symbol) | wind, gust, temperature, rain ×3, humidity, pressure, luminosity |
| Message `:` | addressee, text, message ID, ACK/REJ, bulletins |
| Object `;` and Item `)` | name, live/killed, time, position |
| Status `>` | text |
| Third-party `}` | the inner packet, decoded normally |
| Telemetry, NMEA, capabilities, query, Peet Bros, user-defined | labeled, shown raw |

TNC chatter such as `cmd:` or `*** CONNECTED` is printed with a `TNC|` prefix.

## Wiring

The PK-232 serial port uses RS-232 levels (±12 V). The W65C265S pins are 5 V TTL, so **you need a MAX232/MAX3232 level converter.** Wiring RS-232 straight to P60 can damage the chip.

Receive only needs one data wire plus ground:

```
PK-232 DB-25                MAX232 (or RS-232/TTL module)        MyMensch
pin 3  (TXD out of TNC) --> R1IN  (pin 13)
                            R1OUT (pin 12) ---------------------> P60 / RXD0  (Port 6 header)
pin 7  (signal ground)  --- GND ------------------------------- GND
                            VCC <-------------------------------- +5 V
```

The PK-232 is wired as DCE and expects the computer to raise its handshake lines. With a 3-wire cable, add jumpers at the PK-232's DB-25 so it sees itself as allowed to send:

- **4 ↔ 5** (RTS–CTS)
- **6 ↔ 8 ↔ 20** (DSR–DCD–DTR)

UART3 (USB console) is untouched. P61/TXD0 is not used yet; it will carry the transmit side later.

## PK-232 setup

Do this once from a PC terminal connected straight to the PK-232. It stores the settings in its battery-backed RAM.

```
ABAUD 9600        terminal speed (must match the MyMensch console speed, see below)
AWLEN 8           8 data bits   (7 data + even parity also works; the parity bit is stripped)
PARITY 0          no parity
PACKET            packet mode
HBAUD 1200        1200-baud VHF APRS
MONITOR ON        monitor all traffic   (newer firmware: MONITOR 4 or higher)
MRPT ON           show the digipeater path
HEADERLN OFF      header and data on one line (ON also works)
MSTAMP OFF        no timestamps in the header
```

Command names vary a little between PK-232 firmware versions, so check your manual if one is rejected. Because the PK-232 autobauds on a cold start, set `ABAUD` before you move the cable over to the MyMensch. Receive-only means the MyMensch can't send the `*` the autobaud routine waits for.

## Baud rate

`TNC_BAUD` near the top of `aprsrx.asm` sets the UART0 speed:

| `TNC_BAUD` | UART0 speed |
|---|---|
| `0` (default) | same as the monitor console. UART0 shares the monitor's Timer 4, normally 9600. |
| `1`…`5` | 1200 / 2400 / 4800 / 9600 / 19200, from Timer 3. Uses the crystal speed the monitor detected at reset. |

## Build

With WDCTools installed (`C:\WDC\Tools\BIN` on the PATH), run:

```
mk_aprsrx.bat
```

This produces `aprsrx.s28` (Motorola S28) and `aprsrx.bin` (WDC binary for EasySXB). The code loads at `$00:2000` and is about 6 KB.

## Console app (baud finder + terminal)

`tools/mensch_term.py` finds the board's baud rate and opens a terminal at that speed:

```
python tools\mensch_term.py --list        show COM ports (the board is an FTDI USB serial port)
python tools\mensch_term.py COM5          probe speeds, then open a terminal
```

It tries 9600 first (the monitor default), then 19200, 38400, 57600, 115200, 4800, 2400 and 1200. At each speed it sends a carriage return and then `?`, and accepts the speed once the monitor's help text comes back.

In the terminal, **Ctrl+U** uploads a file (for example `aprsrx.s28`) one line at a time, and **Ctrl+]** quits. Other options: `--baud 9600` skips probing, `--rtscts` turns on hardware flow control, `--log file.txt` saves everything received.

## Load and run

1. Connect your terminal to the MyMensch USB port at 9600 8N1 and reset to get the monitor prompt.
2. **Load:** send `aprsrx.s28` as a plain text file. The monitor's `S` command takes S28 records as they arrive. Alternatively, load `aprsrx.bin` with EasySXB.
3. **Run:** `J002000` (or `G002000`).

Keys while it runs:

| Key | Action |
|---|---|
| `ESC` | stop. Restores the monitor's vectors and timers, then returns to the monitor through `BRK`. |
| `R` | raw mode on/off. Also prints each TNC line exactly as received. |
| `S` | statistics: packets, UART errors, ring overflows, over-long lines |

## How it works

- **Why not the UART0 interrupt?** The Mensch Monitor ROM hard-wires the UART interrupt vectors to its own buffering code. Only some interrupts go through RAM vectors.
- **Timer 7 instead.** Timer 7 *is* RAM-vectored (`JML` at `$00:011C`) and unused by the monitor. The program points that vector at its own ISR and runs Timer 7 at about 4 kHz. Each tick checks the UART0 receive flag (`UIFR` bit 0) and moves any waiting byte into a 2 KB ring buffer. That is 4× faster than bytes can arrive at 9600 baud.
- **Main loop.** It drains the ring, assembles lines, and decodes them. Console output (`PUT_CHR`) can block, but bytes keep landing in the ring meanwhile.
- **Resources used:**
  - Timer 7 and the `$011C` vector
  - direct page `$C0–$FF`
  - RAM `$2000–$37FF` (code) and `$5000–$5BFF` (buffers and variables)
  - a private stack at `$7EFF`

  Everything is put back on `ESC`.

## Testing without hardware

`test/` has a small 65816 emulator that loads the real `aprsrx.s28`. It stubs the monitor calls (`PUT_CHR`, `GET_BYTE_FROM_PC`) and models Timer 7, UART0 and its overrun flag. It then feeds PK-232 style lines through the ISR into the decoder:

```
cd test
python run_tests.py        (add -v to see the console output)
```

The checks cover:
- each packet type
- 7E1 parity input
- HEADERLN mode
- the keys
- over-long lines
- bursts at 4× line rate (no data lost)
- forced UART overruns (counted; the program keeps running)
- clean restore on exit

Reference coordinates were checked against `aprslib`.

## Assumptions to check on your board

- **MyMensch = W65C265S with the Mensch Monitor in ROM**, console on UART3, and RXD0 on P60. This matches WDC's W65C265S documentation, but I have not seen a MyMensch schematic.
- **Timer 7 rate.** `T7_RELOAD = 921` gives 4 kHz at a 3.6864 MHz FCLK. With other crystals the rate scales but stays well above 9600 baud byte timing.
- **Monitor behavior** comes from WDC's 1995 ROM listing (`265iromlist.pdf`): vector `$011C`, UART timer setup, and `MON_SPEED` at `$DFB5`. If your chip has a newer ROM revision, those are the places to check first.

## Next steps (for later)

- Transmit: enable TXD0 so the console can talk to the PK-232 directly (configure it, send beacons and messages).
- KISS mode on the PK-232 for binary-clean frames.
- A heard-stations list or last-position table.
- Decoding compressed altitude/range and telemetry.
