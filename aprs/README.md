# APRS receiver: AEA PK-232 → WDC MyMENSCH Rev-C

Receive-only for now. The PK-232 decodes packets off the air and prints each one as a text line. The MyMENSCH reads those lines on **ACIA_B**, decodes the APRS content, and prints it on the USB port (**ACIA_A** through the CH340), the same port WDC's uploader uses.

Target: MyMENSCH Rev-C running the W65C165i1 FPGA design. Your board reported `CPU Type: W65C02 - Board Type: MyMENSCH C`.

```
#0002 N0CALL > SS2UVT via WIDE1-1
  Pos    33 25.64N  112 07.74W
  Sym    /> car
  Course 251  Speed 25 kt
  Mic-E  En Route
  Alt    61 m
  Cmt    ]"4T}=
```

The 8 LEDs show the packet count in binary, so you can see packets arriving even without a terminal open.

## What gets decoded

| APRS type | Shown |
|---|---|
| Position `!` `=` `/` `@` (plain and compressed) | lat/lon, symbol name, course/speed, PHG/RNG/DFS, `/A=` altitude, comment |
| Mic-E `` ` `` `'` | lat/lon, course/speed, message (En Route, In Service…), altitude, comment |
| Weather (`_`, or a position with the `_` symbol) | wind, gust, temperature, rain ×3, humidity, pressure, luminosity |
| Message `:` | addressee, text, message ID, ACK/REJ, bulletins |
| Object `;` and Item `)` | name, live/killed, time, position |
| Status `>` | text |
| Third-party `}` | the inner packet, decoded normally |
| Telemetry, NMEA, capabilities, query, Peet Bros, user-defined | labeled, shown raw |

TNC chatter such as `cmd:` or `*** CONNECTED` is shown with a `TNC|` prefix.

## Wiring

**The MyMENSCH runs on 3.3 V.** Use a **MAX3232** (or a 3.3 V RS-232 ↔ TTL module) between the PK-232 and the board. A 5 V MAX232 or a direct RS-232 connection can damage the FPGA.

Receive needs one data wire plus ground. Use header **J4**:

```
PK-232 DB-25               MAX3232 module                    MyMENSCH J4
pin 3  (TXD out of TNC) --> RS-232 RX in
                            TTL RX out  ---------------------> pin 44  RXD_B
pin 7  (signal ground)  --- GND ----------------------------- pin 49  VSS
                            VCC <---------------------------- pin 50  VDD (3.3 V)
```

The PK-232 expects the computer to raise its handshake lines. With a 3-wire cable, add jumpers at the PK-232's DB-25:

- **4 ↔ 5** (RTS–CTS)
- **6 ↔ 8 ↔ 20** (DSR–DCD–DTR)

Reserved for transmit later: **J4 pin 42 TXD_B**, plus pins 46/48 (RTS_B / CTS_B).

## PK-232 setup

Do this once from a PC terminal connected straight to the PK-232. It stores the settings in its battery-backed RAM.

```
ABAUD 9600        terminal speed; must match TNC_CTRL in aprsrx.asm (default 9600)
AWLEN 8           8 data bits   (7 data + even parity also works; the parity bit is stripped)
PARITY 0
PACKET            packet mode
HBAUD 1200        1200-baud VHF APRS
MONITOR ON        monitor all traffic   (newer firmware: MONITOR 4 or higher)
MRPT ON           show the digipeater path
HEADERLN OFF      header and data on one line (ON also works)
MSTAMP OFF        no timestamps in the header
```

Command names vary a little between PK-232 firmware versions, so check the manual if one is rejected. Set `ABAUD` before moving the cable to the MyMensch. A receive-only port can't send the `*` the PK-232 waits for on a cold start.

To use another TNC speed, change `TNC_CTRL` near the top of `aprsrx.asm`: `$18` = 1200, `$1A` = 2400, `$1C` = 4800, `$1E` = 9600, `$1F` = 19200.

## Build

With WDCTools installed (`C:\WDC\Tools\BIN` on the PATH), run:

```
mk_aprsrx.bat
```

This makes `aprsrx.bin` (for the uploader) and `aprsrx.s19` (for the tests). The code loads at `$8000` and is about 5.5 KB.

## Load and run

The board's automatic reset doesn't work on your setup, so use `-s` and **press RESET** when the uploader says so:

```
C:\Users\kc4ums\Downloads\wdc_uploader_term\wdc_uploader_term.exe -d COM10 aprsrx.bin -m write -x -s 5 -t
```

- `-m write -x` loads the program into RAM at `$8000` and starts it.
- `-t` keeps the uploader open as a terminal (115200 baud), where the decoded packets appear.

Keys in the terminal:

| Key | Action |
|---|---|
| `R` | raw mode on/off. Also prints each TNC line exactly as received. |
| `S` | statistics: packets, UART errors, ring overflows, over-long lines |
| `ESC` | stop. Turns ACIA_B off and restarts the board into its monitor. |
| `Ctrl+]` | quit the uploader's terminal |

Loading into RAM means the program is gone after a power cycle. Once you're happy with it, add `-k` to store it in the board's user flash instead, as WDC's examples do.

## How it works

- **Jump table.** The program starts with the 15-entry table the MyMENSCH firmware requires at `$8000`. Entry 4 (`IRQ_ACIA_B`) points at the receive handler.
- **Receive interrupt.** ACIA_B interrupts on every received byte. The handler counts any overrun/framing/parity error and stores the byte in a 256-byte ring buffer.
- **Main loop.** It takes bytes from the ring, builds lines, and decodes them. It also checks the console for keys.
- **Console.** Output goes to ACIA_A, waiting on its transmit-empty flag. GPIO E7 is driven low so the CH340 lets the PC send keys.
- **Memory used:**
  - code `$8000–$95FF`
  - buffers and variables `$0200–$06FF`
  - zero page `$40–$77`

## Testing without hardware

`test/` has a 65C02 bench that loads the real `aprsrx.s19`. It models:
- ACIA_A at real 115200-baud output speed
- ACIA_B with receive interrupts and overrun
- the jump table
- the reset vector

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
- real 9600-baud timing (nothing lost)
- 4× bursts (nothing lost)
- forced overruns (counted exactly; the program keeps running)
- the ACIA_B settings
- the LED count

## Not yet confirmed on real hardware

- **The uploader terminal hasn't been tried yet.** It was used for reading memory, but receiving keys and showing this program's output haven't been seen working.
- **ACIA_A flags and RTS on GPIO E7** come from the W65C165i1 datasheet. If keys don't reach the program, the E7 handshake line is the first thing to check.
- **The PK-232 path** (ACIA_B on J4 pin 44) is wired per the datasheet but not yet tested with the TNC.

## Next steps (for later)

- Transmit: TXD_B (J4 pin 42) so the console can configure the PK-232 and send beacons and messages.
- KISS mode on the PK-232.
- A heard-stations list.
