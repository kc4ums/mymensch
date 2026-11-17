# Software TNC for the W65C134SXB (transmit side)

This is a port of `../tnc/` (MyMENSCH) to WDC's **W65C134SXB**. The packet code is the same: AX.25 frame, CRC, bit stuffing, NRZI and the 1200/2200 Hz sine generator. Only the hardware layer changed. It uses the same radio interface (`../hardware/`) with the Kenwood TM-V71A.

## Differences from the MyMENSCH version

| | MyMENSCH (`tnc/`) | W65C134SXB (`tnc134/`) |
|---|---|---|
| Load | WDC uploader, runs at `$8000` | EasySXB at 9600 baud, load `tnc134.hex`, start with **JMP 00:2000** |
| Console | ACIA_A registers | ROM monitor routines `OUTCH` `$F00F` and `RD_CHAR` `$F006`, interrupt driven |
| DAC, PTT, SQC, RX | VIA_A PA0-PA3, PA4, PA5, PA7 (J3) | **Port 5**: P50-P53, P54, P55, P57 |
| Sample timer | VIA_A Timer 1 | Timer 1 (polled flag in IFR2 bit 4, cleared by writing a 1) |
| LEDs | GPIO_B | Port 3 bits 0-2, the SXB's chip-select LED lines |
| Logic supply | 3.3 V | **5 V** |
| Store in flash | not possible on this FPGA image | the SXB has a 128 KB flash socket |
| ESC | restarts the board | returns to the monitor prompt |

Things the ROM monitor reserves, all taken from WDC's monitor listing:
- **Zero page** `$40-$A3`, including its serial buffers. This program uses `$B0-$D1`.
- **Port 6** for the UART, and **P44-P47** for handshaking. Port 5 is free.
- **Timer 2** for its 1-second clock, and **Timer A** for the baud rate. Timer 1 is free: the manual says the monitor uses it, but the ROM never enables its interrupt.

## Build and load

```
mk_tnc134.bat
```

This writes `tnc134.hex` (Intel HEX) and `tnc134.s28`. Both load with EasySXB:

1. In EasySXB, select the W65C134SXB board, then connect at 9600 baud.
2. Upload `tnc134.hex`.
3. **JMP** to `00:2000`.

As with the MyMENSCH version, edit the CONFIG block at the top of `tnc134.asm` first: call, SSID, position, and `cfg_ok`. The keys and LEDs work the same: `B`, `P`, `1`, `2`, `S`, `?`; heartbeat, TX and RX.

## Wiring the interface board to the SXB

Connect the interface board's J2 pins to the SXB's **Port 5** pins. The SXB board datasheet wasn't available when this was written, so find P50-P57 on the SXB's headers yourself.

| Interface J2 | SXB |
|---|---|
| PA7 (RX) | **P57** |
| PA5 (SQC) | **P55** |
| PA4 (PTT) | **P54** |
| PA3, PA2, PA1, PA0 (DAC) | **P53, P52, P51, P50** |
| +3V3 | SXB **VDD (5 V)** |
| GND | SXB GND |

**5 V notes:**
- **Comparator:** the reference becomes about 2.0 V. The LM393 is fine at 5 V.
- **DAC:** it swings 0-5 V, so set RV1 lower.
- **SQC:** leave **R21** out, so the radio's squelch line reaches P55 through R20 only. The 10k/20k divider would cut a 5 V squelch signal to 3.3 V, which may not read as a logic high on a 5 V chip.

## Testing without hardware

`test_tnc134.py` runs the program on a W65C134SXB model: the shared 65C02 core, the ROM routines, Port 5, Port 3 and Timer 1. It runs the same checks as `../tnc/test_tnc.py`: sample period, frame decoded from the audio byte for byte, FCS, tone pitch, and the LEDs.

```
python test_tnc134.py        (add -v to see the console)
```

## Not yet confirmed on real hardware

- **Timer 1 period.** The code assumes the 134's T1 period is latch + 1 cycles. If test tone `1` reads about 1206 Hz instead of 1200, change `T1_SAMPLE` and `T1_TICK` to `192-2` and `36864-2`.
- **LEDs.** The heartbeat, TX and RX LEDs are assumed to be on P30-P32, following WDC's LEDCS03 example. If they're elsewhere, or inverted, change `HB_LED`, `TX_LED` and `RX_LED`.
- **Clock.** The SXB's crystal is assumed to be 3.6864 MHz. The program checks the monitor's crystal byte at start-up and warns if it's anything else.
- **Port 5 header pins:** see the wiring section.
