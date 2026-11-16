# MMON: machine-language monitor for the MyMENSCH Rev-C

A small monitor you upload like any program. Use it to look at and change memory and I/O registers, load S19 programs and run them, and catch BRKs.

## Build and load

```
mk_mmon.bat
wdc_uploader_term.exe -d COM10 mmon.bin -m write -x -s 5 -t
```

Press RESET when the uploader asks. The `>` prompt appears in the uploader's terminal.

## Commands

Numbers are hex. `$` is optional, and commands can be typed in upper or lower case.

| Command | What it does |
|---|---|
| `D [start [end]]` | Dump memory with an ASCII column. 128 bytes by default; `D` alone carries on. |
| `I` | Dump the I/O page `$7F00-$7FFF`. |
| `E addr [bb bb ..]` | Write bytes, then show them read back. Good for poking I/O registers. |
| `F start end bb` | Fill memory. |
| `G [addr]` | Call `addr` with A/X/Y/P from `R`. When your code does `RTS` you're back at the prompt, with the registers shown. |
| `R [a [x [y [p]]]]` | Show or set the registers `G` uses. P starts as `04` (IRQs masked). |
| `L` | Load an S19 file: paste it, or use Ctrl+T Ctrl+U in the terminal. `G` then runs the file's start address. |
| `?` | Help. |
| `X` | Restart into WDC's firmware. |

ESC cancels a line, stops a dump and aborts a load.

**BRK:** a `BRK` in your code stops back in the monitor and prints `BRK at xxxx` and the registers. `G` resumes after the BRK and its signature byte.

**Reading `$7F60`:** the dumps show the ACIA_A data register as `--`, because reading it would swallow a key.

## Memory

| Range | Use |
|---|---|
| `$8000-$8FFF` | monitor code |
| `$0100-$02FF` | stack, line buffer, saved registers, IRQ vectors |
| `$00F0-$00FF` | monitor zero page |
| `$0300-$7EFF`, `$9000-$F7FF` | free for your programs |

`L` refuses to write into the monitor's memory and counts those bytes as "refused". It reads back every byte it writes and counts any that didn't stick as "not written". `F` refuses ranges that overlap `$8000-$8FFF`.

Build your programs with `ORG` in the free RAM, not at `$8000`. They don't need the 15-entry jump table; the monitor's table stays in place.

## Interrupts

The monitor's jump table sends each IRQ through a RAM vector. To use an interrupt, store your handler's address there (the handler ends with `RTI`) and clear I with `R` or `CLI`:

| Vector | IRQ | Vector | IRQ |
|---|---|---|---|
| `$0260` | ACIA_C | `$026C` | VIA_D |
| `$0262` | ACIA_B | `$026E` | VIA_C |
| `$0264` | ACIA_A | `$0270` | VIA_B |
| `$0266` | ADC | `$0272` | VIA_A |
| `$0268` | I2C | `$0274` | GPIO_A |
| `$026A` | SPI | `$0276` | GPIO_E |

## Testing without hardware

`test_mmon.py` runs the monitor on the 65C02 emulator in `../aprs/test`. It types commands, hits a BRK and resumes, and pastes an S19 at the real 115200-baud character rate, checking that no characters are lost.

```
python test_mmon.py        (add -v to see the session)
```

## Not yet confirmed on real hardware

- Whether RAM at `$9000-$F7FF` can be written; the datasheet calls it "protected RAM". `L` reports bytes that didn't stick, or try `E 9000 55`.
- That BRK reaches the jump table's BRK entry directly, as the datasheet's vector table suggests.
- Pasting into the uploader's terminal. If characters get lost, use Ctrl+T Ctrl+U instead.
