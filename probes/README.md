# Hardware probes

These are small programs that check what the MyMENSCH Rev-C's FPGA image really contains. Each builds with its `mk_*.bat` and loads with:

```
wdc_uploader_term.exe -d COM4 <name>.bin -m write -x -s 5 -t
```

| Program | What it does | Result on this board |
|---|---|---|
| `regmap` | Hex dump of the I/O page at `$7F00-$7FFF`, then read-back tests of the VIAs, multipliers, ADC and chip ID | VIA_A works; VIA_B, VIA_C, multipliers, ADC and chip ID read `00` and ignore writes |
| `clock` | Times 1000 characters at 115200 baud with VIA_A Timer 1, without relying on its flag. Also checks how the T1 flag clears. | **PHI2 = 3.6864 MHz**, standard 65C02 cycle timing. The T1 flag clears when `$40` is written to the IFR, but not when T1C-L is read. |
| `adcprobe` | Drives the ADC every way the datasheet allows | No ADC in the image |
| `probe` | Earlier combined probe (clock, multipliers, ADC) | Its clock figure is wrong on this board, because it expects reading T1C-L to clear the flag. Use `clock` instead. |
| `dbgdemo` | Demo of `../lib/dbg.inc` (register and memory dumps) | |

`test/` runs each probe on the emulator in `../tools/emu`, to check it before using it on the board:

```
python test/test_regmap.py
```
