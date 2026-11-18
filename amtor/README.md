# AMTOR station for the W65C134SXB (no computer needed)

This is a stand-alone HF text station in the spirit of the old teletype.
- **What you use:** a PS/2 keyboard to type on and a 20x4 character LCD to read.
- **What does the work:** WDC's W65C134SXB, a 65C02 microcontroller board running on 5 V.
- **Radio:** a Kenwood TS-480 connects through the same interface board as the APRS TNC (`../hardware/`).

There is no PC, USB host or operating system in the chain. The program can live in the SXB's flash and start by itself at power-up.

On the air it uses **AMTOR / SITOR Mode B (FEC)**:
- **Code and speed:** the CCIR 476 code at 100 baud, 170 Hz shift.
- **Error protection:** every character is sent twice, the repeat 350 ms later. Each code has exactly four 1s in its 7 bits, so the receiver can see which copy arrived damaged and use the other one.
- **Interoperability:** it matches fldigi's SITOR-B mode. Anyone with a PC can copy it, and so can you when testing.

| Part | State |
|---|---|
| Mode B transmit and receive, keyboard, LCD, scroll-back, CQ/ID keys | Done. Passes the emulator test: it decodes its own audio, and receives clean, noisy and late-joined signals. **Not yet run on a real SXB.** |
| Mode A (ARQ, point-to-point, error-free) | Next. |
| Mailbox (leave and read messages) | After ARQ. |

## What you need

- **W65C134SXB.** It has no voltage regulator, so feed it a clean **5 V** (for example a 12 V → 5 V buck converter from the station battery) through its micro-USB socket.
- **20x4 character LCD:** HD44780-compatible, 5 V, parallel (not the I²C-backpack kind), plus a 10k contrast pot.
- **PS/2 keyboard:** any keyboard with a PS/2 plug, or a USB keyboard that comes with a PS/2 adapter. Also two 4.7k pull-up resistors.
- **Radio interface:** the board in `../hardware/`, built as for the TNC but with **R21 left out** (5 V logic).
- **Kenwood TS-480 (HX or SAT):** connect to its rear **DATA** socket, a 6-pin mini-DIN. It has the same layout as the TM-V71A's data socket, so the same cable works.

## Wiring

**J4 (Port 5) to the radio interface board.** This is the same as `../tnc134/`. The board's J2 labels are the MyMENSCH's:

| SXB J4 pin | Signal | Interface J2 |
|---|---|---|
| 1 | VDD 5 V | +3V3 pin (it runs on 5 V here) |
| 2 | GND | GND |
| 3, 4, 5, 6 | P50-P53: DAC bits 0-3 | PA0, PA1, PA2, PA3 |
| 7 | P54: PTT | PA4 |
| 10 | P57: comparator (RX audio) | PA7 |

**J3 (Port 4) to the LCD and keyboard clock**:

| SXB J3 pin | Signal | Goes to |
|---|---|---|
| 1 | VDD 5 V | LCD 2 (VDD), LCD 15 (backlight +, through ~100 Ω if the module has no resistor), keyboard +5 V, both pull-ups |
| 2 | GND | LCD 1 (VSS), LCD 5 (R/W), LCD 16 (backlight −), keyboard GND |
| 3, 4, 5, 6 | P40-P43 | LCD 11, 12, 13, 14 (D4-D7) |
| 7 | P44 | LCD 4 (RS) |
| 8 | P45 | LCD 6 (E) |
| 9 | P46 | keyboard CLOCK, with 4.7k to 5 V |
| 10 | P47 | **nothing** (the ROM monitor's serial DSR) |

LCD pin 3 (contrast) goes to the wiper of the 10k pot between 5 V and GND.

**J5 (Port 6)**: pin 6, P63, goes to the keyboard DATA line, with 4.7k to 5 V.

PS/2 socket (6-pin mini-DIN, looking at the socket's face):
- pin 1: DATA
- pin 3: GND
- pin 4: +5 V
- pin 5: CLOCK

## TS-480 setup

- **Mode: USB.** The tones are 1615/1785 Hz, centred on 1700 Hz. On USB the signal sits at the dial frequency + 1.7 kHz.
- **DATA socket** (rear): pin 1 = audio in from the interface, 2 = ground, 3 = PTT, 5 = audio out to the interface. Pin 3 mutes the microphone while transmitting.
- **Menu 46:** data input level. Start at the default 4, and set it with **RV1** on the interface board so the ALC barely moves.
- **Menu 47:** data output level; the default 4 is fine.
- **Menu 60** (DATA VOX): **off**. The program keys PTT itself.
- **Menu 45** (data filter): try it on, to narrow the receiver for data.
- **Power:** AMTOR is a 100% duty-cycle mode. Keep the power moderate (50 W or less on the TS-480HX) for long transmissions.

To test with fldigi on another radio or a websdr: choose **SITOR-B** and put the cursor on 1700 Hz.

## Operating

The screen layout:

```
RX SYNC M##.. S#...     status: RX/TX, SYNC when locked, tuning bars
THE QUICK BROWN FOX      printer, rows 1-2: what was received and sent
JUMPS OVER THE LAZY_
CQ CQ DE KC4UMS_         text you've typed that hasn't been sent yet
```

- **Tuning:** tune so that **both** the M and S bars move while a station is sending. When the receiver locks on, the status shows **SYNC** and the third LED lights.
- **Type at any time.** Text waits on the bottom line until it is sent. Backspace removes characters that haven't been sent yet.
- **Transmitting:**
  - **F1** starts transmitting: about 2 s of phasing, then your text as you type it.
  - **F2** sends whatever is left, then `DE <your call>`, then returns to receive.
  - **F3** sends a CQ call and comes back to receive by itself.
  - **F4** inserts `DE <call>` anywhere.
  - **Esc** drops the transmitter at once. While receiving, Esc clears the typed text instead.
- **Scrolling:** Up, Down, PgUp and PgDn scroll back through the last 256 lines. Home jumps to the oldest line and End to the newest. A `^` on the status row means you are looking at old text.
- **F5** clears the screen. **F12** returns to the WDC monitor (RAM build only).

**Character set:** CCIR 476 has only capital letters, digits and `- ? : ( ) . , ' = / + "`-style punctuation (the exact set follows fldigi: `' ! : ( 2 & . / ; - $ , " ) # ?`). Keys it can't send are ignored.

**Legal:**
- AMTOR (CCIR 476/625) is named in FCC Part 97.309(a)(3), and 100 baud is within the HF limit.
- Identify at least every 10 minutes and at the end of each contact. F2's automatic `DE <call>` covers the end.
- No encryption, codes or ciphers.

## Building and loading

```
mk_amtor.bat
```

That makes:
- `amtor_ram.hex`: a test build that runs from RAM. Load and start it with this repo's uploader, `python ..\tools\sxb134\sxb134.py COM5 amtor_ram.s19 --go 2000`. Or in EasySXB, upload it at 9600 baud, then **JMP 00:2000**.
- `amtor_rom.s19`: the flash build. Write it into the SXB's flash in place with `python ..\tools\sxb134\sxb134.py COM5 amtor_rom.s19 --flash`. From then on, the board starts AMTOR at every power-up. The ROM monitor sees `WDC` at `$8000` and jumps straight to the program, with no computer needed.
- `amtor_flash.bin`: the same program as a 128 KB image for an external programmer (for example a TL866), written into all four 32 KB banks. A spare programmed chip kept in a Faraday bag is cheap insurance.

**Back to the monitor** (to re-flash or load a RAM build): hold **J5 pin 6 (P63) to GND** while pressing RESET, then use `--flash` or `--unflash`. With the keyboard's 4.7k pull-up fitted, the pin normally reads high and AMTOR starts. If the pull-up is missing the pin floats and may read low, so the board will probably start in the monitor instead.

Before building, edit the CONFIG block near the top of `amtor.asm`:
- `cfg_call`: your call.
- `cfg_autoid`: 1 to add `DE <call>` at the end of each transmission.
- `cfg_rev`: 1 to swap mark and space.
- `cfg_phase`: phasing pairs before the text.

`mk_tables.py` regenerates `amtor_tables.inc`, the CCIR 476 and keyboard tables.

**Don't type on the PS/2 keyboard while the WDC monitor prompt is up** (RAM build). The monitor uses the P46 interrupt as a power-fail input and would shut the board down, so press RESET if that happens. Once the program is running, P46 belongs to the keyboard. F12 switches that interrupt off before returning to the monitor.

## How it works

- **Receive:** Timer 1 interrupts 9600 times a second, and each interrupt does the following:
  1. Reads the comparator output, one bit.
  2. Multiplies it by 1-bit sine and cosine references for both tones.
  3. Keeps a running sum of the products over one bit time (96 samples).
  4. Every other sample, compares the mark and space magnitudes. A software phase-locked loop finds the bit centres from the mark/space changes.
- **Character sync:** the main loop finds character timing from the phasing signal. A late arrival can also lock on from a character and its repeat 35 bits later. The loop then takes the good copy of each character and drops sync after 4 bad characters in a row.
- **Transmit:** Timer 1 runs at 19200 interrupts per second. Each one outputs one sample from a 4-bit sine table, with the phase continuous across bits. The main loop keeps a 16-code queue full, alternating each character slot with the repeat of the character from two slots earlier.
- **Keyboard:** each falling clock edge on P46 interrupts and reads one bit from P63. The Timer 1 handler masks only itself, so a keyboard bit never waits behind a sample.
- **LCD:** written one byte per Timer 1 tick (at least 52 µs apart), and only for rows that changed.

## Testing without hardware

```
python test_amtor.py        (add -v to see the LCD)
```

`test_amtor.py` runs the program on a W65C134SXB model with interrupts, a cycle-counted 65C02 core, a PS/2 keyboard and an HD44780. It checks four things:

- **Transmit:** it types a message, sends it with F1/F2, and checks the result.
  - The audio is demodulated and decoded independently with fldigi's code table.
  - Every slot must be a valid code, and every character must match its repeat.
  - Phasing must come first, the text must arrive followed by the ID, and the radio must end unkeyed.
- **Receive:** an fldigi-equivalent SITOR-B signal is fed in clean, at 0 dB SNR in 2.5 kHz, and joined mid-message without phasing.
- **Timing:** no Timer 1 tick is ever lost, every keyboard bit is read inside its window, and every LCD write waits long enough after the one before.
- **Decoder check:** the decoder logic was first prototyped in Python against the same signals.

## Not yet confirmed on real hardware

- **Timer 1 period.** The code assumes latch + 1 cycles, as in `../tnc134/`. If it's latch + 2, the baud rate is 0.26% slow, which a receiver tracks easily. To be exact, change `T1_RX`/`T1_TX` to `384-2` and `192-2`.
- **Clock in the flash build.** The CPU is assumed to start on the 3.6864 MHz crystal (FCLK) when the ROM jumps to `$8004`.
- **Audio levels.** The TS-480's ANI/ANO levels aren't in its manual. Set them with RV1 and menus 46/47 as above.
