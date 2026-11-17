# Software TNC for the MyMENSCH Rev-C (transmit side)

The MyMENSCH builds APRS packets itself and sends them as 1200-baud audio to a Kenwood TM-V71A data port. There is no external TNC. Receive comes next.

The wiring is in `../hardware/radio_interface.svg`. Transmit needs the R-2R DAC on J4 pins 37-43 (VIA_B PA3-PA0) and the PTT transistor on J4 pin 35 (PA4).

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
   wdc_uploader_term.exe -d COM10 tnc.bin -m write -x -s 5 -t
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

1. **Into a dummy load or on low power, press `1`.** Listen on a second receiver or HT: you should hear a clean 1200 Hz tone. A phone tuner app should read 1200 Hz. If it doesn't, the CPU clock isn't 14.7456 MHz; the delay counts `D_SAMPLE` / `D_BIT` assume it.
2. **Set deviation with RV1.** Turn RV1 up until the tone is clearly audible, then back it off so the tone sounds clean, not distorted. With a deviation meter, aim for about 3 kHz.
3. **Press `B`.** If your signal reaches an internet gateway (iGate), the packet appears on aprs.fi under your call within a minute.

## How it works

- **Packet building:** the packet is built as an AX.25 UI frame: addresses, control `03`, PID `F0`, APRS position text and CRC-16 FCS.
- **Encoding:** the frame is then encoded one bit per byte into a buffer at `$0800-$17FF`. The buffer holds the TXDELAY flags, the frame (with bit stuffing), the FCS and 3 tail flags, all NRZI-encoded.
- **Audio:** the send loop plays the buffer at 19200 samples/s, stepping a 64-step sine table with a 16-bit phase accumulator, so phase stays continuous across tone changes.
- **Timing:** there are no timers. Every sample is exactly 768 CPU cycles, counted instruction by instruction in `tx_smp`.

Memory used: code at `$8000-$87FF`, frame buffer at `$0300`, tone buffer at `$0800-$17FF`, and zero page `$40-$5F`.

## Testing without hardware

`test_tnc.py` runs the program on the emulator in `../aprs/test`, extended to count 65C02 cycles. The test:

1. Rebuilds the audio from the DAC writes.
2. Checks every sample period is 768 cycles.
3. Demodulates the tones, undoes NRZI and bit stuffing, and checks the FCS.
4. Compares the frame byte for byte with an independent Python AX.25 encoder.
5. Measures the test tones.

```
python test_tnc.py        (add -v to see the console)
```

## Not yet confirmed on real hardware

- **VIA_B port A:** it may not exist in this FPGA image. Run `aprs/probe/regmap.bin` to check. If it's missing, only the pin addresses in `tnc.asm` change.
- **Timing:** the instruction timing is assumed identical to a W65C02S. Test tone `1` confirms it.
- **SQC:** its polarity on the TM-V71A hasn't been checked. `cfg_sqc` is `0` (ignore SQC) until it's measured.
