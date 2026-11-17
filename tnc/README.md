# Software TNC for the MyMENSCH Rev-C (transmit side)

The MyMENSCH builds APRS packets itself and sends them as 1200-baud audio to a Kenwood TM-V71A data port. There is no external TNC. Receive comes next.

The wiring is in `../hardware/radio_interface.svg`, and the board is in `../hardware/pcb/`. Transmit needs the R-2R DAC on **J3** pins 37-43 (VIA_A PA3-PA0) and the PTT transistor on J3 pin 35 (PA4). On J3, pin 49 is +3V3 and pin 50 is GND.

## Set up

1. **Edit the CONFIG block** near the top of `tnc.asm`:
   - `cfg_call` and its SSID byte
   - `cfg_lat` and `cfg_lon`, in APRS format `ddmm.hhN` and `dddmm.hhW`
   - the symbol (`cfg_symt` / `cfg_symc`)
   - the comment and the beacon interval
   - finally, set `cfg_ok` to `1`. Until then, the program won't send packets; only the test tones work.
2. **Build and load:**
   ```
   mk_tnc.bat
   wdc_uploader_term.exe -d COM4 tnc.bin -m write -x -s 5 -t
   ```
3. **Set up the radio:** put the DATA band on the band tuned to 144.390 MHz, and set the data speed to 1200.

## Keys

| Key | Action |
|---|---|
| `B` | Send a position beacon now. The console shows it, e.g. `TX KC4UMS>APZ65C,WIDE1-1,WIDE2-1:!...` |
| `P` | Periodic beacon on/off. It's on at start-up when `cfg_ok` = 1; the first beacon goes out after 1 minute, then every `cfg_bmin` minutes. |
| `1` / `2` | Key the radio with a steady 1200 / 2200 Hz tone, about 30 s or until any key. |
| `S` | Status. |
| `ESC` | Restart the board. |

LEDs:

| LED | Meaning |
|---|---|
| 0 | Heartbeat: a double flash once a second while idle. |
| 1 | TX: on while the radio is keyed. |
| 2 | RX: channel busy. It follows SQC if `cfg_sqc` is set; otherwise it lights on audio at the comparator (PA7), and stays on 200 ms after activity stops. |

To move them, change `HB_LED`, `TX_LED` and `RX_LED` in `tnc.asm`.

## First time on the air

1. **Into a dummy load or on low power, press `1`.** Listen on a second receiver or HT: you should hear a clean 1200 Hz tone. A phone tuner app should read 1200 Hz. If it doesn't, check `T1_SAMPLE` in `tnc.asm`: it assumes PHI2 = 3.6864 MHz, which `probes/clock.bin` measured on this board.
2. **Set deviation with RV1.** Turn RV1 up until the tone is clearly audible, then back it off so the tone sounds clean, not distorted. With a deviation meter, aim for about 3 kHz.
3. **Press `B`.** If your signal reaches an internet gateway (iGate), the packet appears on aprs.fi under your call within a minute.

## How it works

- **Packet building:** the packet is built as an AX.25 UI frame: addresses, control `03`, PID `F0`, APRS position text and CRC-16 FCS.
- **Encoding:** the frame is then encoded one bit per byte into a buffer at `$0800-$17FF`. The buffer holds the TXDELAY flags, the frame (with bit stuffing), the FCS and 3 tail flags, all NRZI-encoded.
- **Audio:** the send loop plays the buffer at 19200 samples/s, stepping a 64-step sine table with a 16-bit phase accumulator, so phase stays continuous across tone changes.
- **Timing:** VIA_A Timer 1 runs free with a 192-cycle period (19200/s at PHI2 = 3.6864 MHz). `tx_smp` waits for the Timer 1 flag, writes the DAC straight away, clears the flag by writing `$40` to the IFR, then works out the next sample. The sample rate is therefore exact no matter which path the code takes. This VIA does not clear the flag when T1C-L is read, as a 65C22 would.
- **Idle tick:** between transmissions the same timer runs at 36,864 cycles, giving the 10 ms tick behind the heartbeat, the RX LED and the beacon timer.

Memory used:
- code at `$8000-$882F`
- frame buffer at `$0300`
- tone buffer at `$0800-$17FF`
- zero page `$40-$61`

## Testing without hardware

`test_tnc.py` runs the program on the emulator in `../tools/emu`, extended to count 65C02 cycles. The test:

1. Rebuilds the audio from the DAC writes.
2. Checks every sample period is 192 cycles, with Timer 1 modelled the way the board's VIA behaves.
3. Demodulates the tones, undoes NRZI and bit stuffing, and checks the FCS.
4. Compares the frame byte for byte with an independent Python AX.25 encoder.
5. Measures the test tones.

```
python test_tnc.py        (add -v to see the console)
```

## Not yet confirmed on real hardware

- **VIA_A port A outputs:** the VIA_A registers and Timer 1 work (`regmap`, `clock` probes), but the port pins haven't been measured with a meter yet.
- **Tone frequency on air:** the clock (3.6864 MHz) and Timer 1 were measured with `probes/clock.bin`. Test tone `1` reading 1200 Hz confirms it end to end.
- **SQC:** its polarity on the TM-V71A hasn't been checked. `cfg_sqc` is `0` (ignore SQC) until it's measured.
