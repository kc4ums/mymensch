# sxb134: uploader for the W65C134SXB

This loads a program into the SXB's RAM through the ROM monitor built into the W65C134S, checks it, and starts it. It does the same job as EasySXB, from the command line, with a read-back check.

```
python sxb134.py COM5 ..\..\amtor\amtor_ram.s19 --go 2000 --term
```

- **What it loads:** `.s19`, `.s28` and Intel `.hex` files, and `.bin` with `--addr`.
- **Starting the program:** `--go ADDR` jumps to the program. `--jsr ADDR` calls it, so an `RTS` comes back to the monitor.
- **`--term`:** stays connected as a terminal; Ctrl-] quits. Run `python sxb134.py COM5 --term` on its own for just a terminal.
- **Verify:** every load is read back and compared. `--no-verify` skips that.
- **Needs:** Python 3 and pyserial (`pip install pyserial`).

Find the port in Device Manager: it is the FTDI "USB Serial Port".

## How it talks to the monitor

It uses only commands the monitor already has. These are from WDC's ROM listing, `134iromlist.pdf`:

| Sent | Monitor does |
|---|---|
| CR | prints a new `.` prompt; this is how the tool checks the monitor is there. On a real SXB the monitor ends its lines with CR only (`E\rE 005A  00\r.`). The tool accepts that and CR LF. |
| `S1...` CR | stores one S-record and answers with a new `.` prompt. A bad checksum beeps and prints `E aaaa  nn` first, and the tool resends that record (up to 3 times) |
| `E` | prints and clears the load error count |
| `W` start end CR | sends the memory back as S1 records, which the tool compares with the file |
| `G` addr or `J` addr | JMP or JSR to the program; the monitor types the space itself |

The tool sends each record only after the prompt for the one before. So it never overruns the monitor's small receive buffer, and it doesn't depend on how the SXB wires its handshake lines. It holds DTR and RTS on, which the monitor's DSR input (P47) expects.

**Speed:** about 1 KB every 3 s at 9600 baud. Loading AMTOR (3.8 KB) and verifying it takes about 20 s.

## Writing the flash

The SXB's flash chip (an SST39SF010A on the board this was written for) can be programmed in place:

```
python sxb134.py COM5 ..\..\amtor\amtor_rom.s19 --flash
python sxb134.py COM5 --unflash
```

- **`--flash`** writes a program built for `$8000-$EFFF` into flash bank 3.
  - **Why bank 3:** the ROM monitor selects it at reset (it sets P34 and P35 high), then checks `$8000` for `WDC`.
  - **What happens:** the tool loads `flash134.s19` into RAM at `$7000`. Then, for each 4 KB sector the program covers, it stages the data at `$1000`, erases the sector, programs it, and checks it. Finally it reads the whole range back through the monitor.
- **`--unflash`** erases the sector at `$8000`, which removes the `WDC` signature, so the board starts in the monitor again.
- **`--bank N`** writes another bank instead (0-3).

**Getting back to the monitor:** once a program with `WDC` at `$8000` is in flash, the board runs it at every reset instead of the monitor. To get back in and re-flash:
- **AMTOR's flash build:** hold **J5 pin 6 (P63) to GND** (J5 pin 2) while you press RESET. Then run `--unflash` or `--flash` again.
- **Other programs:** they need their own way back (`jmp $F057` re-enters the monitor). Otherwise you'd have to pull the chip.

**Checking the chip:** `flashid.s19` is a read-only probe (`--jsr 7000`). It prints the chip's ID and whether writes reach it.

## Limits

- **Without `--flash`,** only RAM ($0200-$7FFF) is loaded.
- **If nothing answers,** the tool asks you to press RESET and waits 30 s for the monitor's sign-on.

## Test

```
python test_sxb134.py
python test_flash134.py
```

`test_sxb134.py` runs the uploader against a model of the monitor's serial side, written from the ROM listing. It checks:
- the load, verify, start, flash and file-format paths;
- that corrupted records are noticed and resent;
- that a silent board is reported.

`test_flash134.py` runs `flash134.s19` on the 65C02 core against a model of the SST39SF010A, wired as on the SXB (bank lines on P34/P35). It checks:
- the exact command sequences, sector erase, and programming with `$FF` bytes skipped;
- that other banks and sectors are left untouched and the bank lines are restored;
- that bad addresses are refused and a write-protected chip is reported.

**On a real SXB:**
- **RAM loading works:** `tnc134.hex` loaded, verified and ran. That's how the CR-only prompt was found.
- **Flash writing** (`--flash`, `--unflash`) **hasn't been tried on the board yet.** The chip's ID was read with `flashid.s19`: `BF B5`, an SST39SF010A, and writes reach it.

`test_sxb134.py` runs the monitor model both with CR LF and with CR-only line ends.

`../aprsmap/aprsmap.py --load` uses this tool's code to load `tnc134` before it opens the map.
