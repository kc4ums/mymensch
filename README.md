# MyMENSCH APRS

A software TNC for WDC's MyMENSCH Rev-C board and a Kenwood TM-V71A. The MyMENSCH does all the packet work itself, with no external TNC: it builds APRS packets and sends them as 1200-baud audio through a small interface board on the radio's data port. The board's FPGA runs a W65C02 at 3.6864 MHz.

## Status

| Part | State |
|---|---|
| Transmit (`tnc/`): position beacons, periodic beacon, test tones, LEDs | Done. Passes the emulator test, including decoding its own audio. **Not yet tried on the board or on air.** |
| Radio interface: schematic and milled PCB (`hardware/`) | Done. The layout passes its clearance and connectivity checks. **Not yet cut.** |
| Receive: demodulate 1200-baud audio, decode packets | Next. The APRS decoder is ready in `tnc/aprs_decode/`. |
| Board hardware facts | Measured; see below. |

## Folders

| Folder | Contents |
|---|---|
| `tnc/` | The software TNC (transmit side). `tnc/aprs_decode/` holds the APRS decoder from the old PK-232 receiver, for the receive work. |
| `hardware/` | Radio interface schematic (`radio_interface.svg`), plus `pcb/`: the CNC-milled board's GRBL G-code, drawings and generator. |
| `monitor/` | MMON, a machine-language monitor: dump and edit memory and I/O, load S19 files, run code, catch BRKs. |
| `probes/` | Small programs that test the board's hardware, and what they found. |
| `lib/` | `dbg.inc`: register and memory dump helpers to include in any program. |
| `tools/emu/` | The 65C02 emulator of the MyMENSCH that every test runs on. |
| `docs/` | W65C165i1M08SA datasheet. |

## Building and loading

You need WDCTools (`C:\WDC\Tools\BIN` on the PATH) and WDC's uploader. Each program folder has a `mk_*.bat`.

```
cd tnc
mk_tnc.bat
wdc_uploader_term.exe -d COM4 tnc.bin -m write -x -s 5 -t
```

Press RESET on the board when the uploader asks. The program then runs from RAM and its console appears in the uploader's terminal (Ctrl+] to quit). Programs live in RAM, so re-upload after every power cycle. Storing to flash (`-k`) fails on this board with "Clear Failed": the user-flash controller seems to be missing from the FPGA image (see below).

## First bench test (no radio)

1. Load `tnc.bin` as above. LED 0 should double-flash once a second. That shows Timer 1 and the program are running.
2. Press `1` for a test tone. J3-35 (PTT) should go high, and J3-37…43 (the DAC) should toggle. Any key stops it.
3. Then build the interface board (`hardware/pcb/README.md`) and follow "First time on the air" in `tnc/README.md`.

## Wiring to the MyMENSCH

Everything connects to **J3** (VIA_A port A):

| J3 pin | Signal |
|---|---|
| 29 | PA7: comparator output (RX audio) |
| 33 | PA5: radio SQC (optional) |
| 35 | PA4: PTT |
| 37, 39, 41, 43 | PA3-PA0: DAC bits 3-0 |
| 49 | +3V3 |
| 50 | GND |

On J3, pin 49 is +3V3 and pin 50 is GND, the reverse of J4.

## Tests

Every program has an emulator test; none needs the board:

```
python tnc/test_tnc.py
python tnc/aprs_decode/run_tests.py
python monitor/test_mmon.py
python probes/test/test_regmap.py      (also test_probe, test_adcprobe, test_dbgdemo)
```

## What this board's FPGA image actually has

These were measured with the programs in `probes/`. They differ from the datasheet:

- **CPU clock:** 3.6864 MHz (the 14.7456 MHz oscillator divided by 4), with standard 65C02 cycle timing.
- **VIA_A:** works, with its ports on J3. **VIA_B and VIA_C are missing.**
- **VIA_A Timer 1 flag:** clears only when `$40` is written to the IFR, not when T1C-L is read.
- **Missing blocks:** the ADC, the multipliers and the chip ID are not in the image. That's why receive uses a comparator instead of the ADC.
- **User flash (UFM):** its registers at `$7FE0-$7FEC` read `00` (the write-protect register should reset to `1F`), and the uploader's `-k` fails with "Clear Failed". So it's most likely missing too, and programs can't be stored in flash.
