# MyMENSCH APRS

A software TNC for WDC's MyMENSCH Rev-C board, with a Kenwood TM-V71A. The board's FPGA runs a W65C02 at 3.6864 MHz, and the MyMENSCH does all the packet work itself: no external TNC.

| Folder | Contents |
|---|---|
| `tnc/` | The software TNC: builds APRS packets and sends them as 1200-baud audio (transmit side; receive is next). `tnc/aprs_decode/` holds the APRS decoder from the old PK-232 receiver, for the receive work. |
| `hardware/` | Radio interface schematic (`radio_interface.svg`) and the CNC-milled PCB (`pcb/`: G-code, drawings, generator). |
| `monitor/` | MMON, a machine-language monitor: dump and edit memory and I/O, load S19 files, run code, catch BRKs. |
| `probes/` | Small programs that test the board's hardware, and what they found. |
| `lib/` | `dbg.inc`: register and memory dump helpers to include in any program. |
| `tools/emu/` | The 65C02 emulator of the MyMENSCH that every test runs on. |
| `docs/` | W65C165i1M08SA datasheet. |

Build with WDCTools (`C:\WDC\Tools\BIN` on the PATH): each program folder has a `mk_*.bat`. Load with WDC's uploader, e.g.

```
wdc_uploader_term.exe -d COM4 tnc.bin -m write -x -s 5 -t
```

Press RESET on the board when the uploader asks.

## What this board's FPGA image actually has

These were measured with the programs in `probes/`. They differ from the datasheet:

- **CPU clock:** 3.6864 MHz (the 14.7456 MHz oscillator divided by 4), with standard 65C02 cycle timing.
- **VIA_A:** works, with its ports on J3. **VIA_B and VIA_C are missing.**
- **VIA_A Timer 1 flag:** clears only when `$40` is written to the IFR, not when T1C-L is read.
- **Missing blocks:** the ADC, the multipliers and the chip ID are not in the image.
