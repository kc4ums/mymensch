# Radio interface PCB (CNC-milled, single-sided)

This board joins the MyMENSCH to the Kenwood TM-V71A data port for the software TNC. The circuit is `../radio_interface.svg`.

`mk_pcb.py` holds the layout. It checks it and writes everything here:

| File | What it is |
|---|---|
| `isolation_30deg_vbit.nc` | Copper isolation, 30° V-bit (0.1 mm tip), 0.08 mm deep, 3 passes around every signal net. |
| `drill_0.8mm.nc` | 64 holes for the components. |
| `drill_1.0mm.nc` | 14 holes for the J2 header pins and the radio cable wires (J1). |
| `outline_1-16in_endmill.nc` | Board cut-out, 1/16" end mill, 5 passes, 4 holding tabs on the last two. |
| `copper_side.svg` | What gets milled, seen copper side up as on the machine. |
| `assembly_top.svg` | Where every part goes, seen from the component side. |

The board is **90.2 x 67.3 mm**: through-hole parts on top, copper on the bottom. All copper that isn't a signal stays as ground fill, so ground needs no traces.

## Cutting it (GRBL, e.g. a 3018)

1. **Blank.** Use single-sided FR-4, at least **93 x 70 mm**; 100 x 80 is comfortable. Tape it flat with double-sided tape, **copper up**, on a spoil board.
2. **Origin.** Set X0 Y0 at the **lower-left corner of the board**, about 2 mm in from the blank's edges. The outline cut runs 0.8 mm outside the board.
3. **Isolation.** Fit the V-bit and zero Z on the copper, then run `isolation_30deg_vbit.nc`. The cut is only 0.08 mm deep, so a warped blank will leave gaps. Probe a height map first (Candle: *Heightmap*; bCNC: *Probe → Autolevel*), or at least check flatness at the four corners.
4. **0.8 mm drill.** Zero Z on the copper again, then run `drill_0.8mm.nc`.
5. **1.0 mm drill.** Run `drill_1.0mm.nc`. If you only have 0.8 mm, drill these with it and open them up by hand with a 1.0 mm bit in a pin vise.
6. **Outline.** Fit the 1/16" end mill and zero Z, then run `outline_1-16in_endmill.nc`. Snap the board out at the tabs and sand the edges.
7. **Check for shorts.** Look over the copper with a magnifier, and use a meter between neighbouring traces and ground. Any burrs come off with fine sandpaper or a deburring tool.

Feeds are conservative: V-bit 150 mm/min, drill plunge 60 mm/min, outline 120 mm/min, spindle `S10000`. To change them, edit the constants at the top of `mk_pcb.py` and run `python mk_pcb.py`.

## Parts

| Ref | Part | Notes |
|---|---|---|
| U1 | LM393 dual comparator, DIP-8 | Notch toward the top edge; pin 1 is top-left, nearest C2 |
| Q1 | 2N7000, TO-92 | **Flat face toward the top edge** (drain on the left pad) |
| RV1 | 10k trimpot, 3362P or similar, 0.1" inline | Body toward Q1 |
| C1, C4 | 1 µF film or ceramic, 0.2" (5 mm) pitch | |
| C2 | 10 µF electrolytic, 0.1" pitch, 5 mm max dia | **+ lead in the lower pad** (marked + on `assembly_top.svg`) |
| C3 | 10 nF film or ceramic, 0.2" pitch | |
| R1, R4, R6, R14, R15, R16, R20 | 10k | 1/4 W, 0.4" pitch, all resistors |
| R10, R11, R12, R13, R17, R21 | 20k | |
| R2, R9, R18 | 100k | |
| R3 | 1M | |
| R5 | 6.8k | |
| R7 | 4.7k | |
| R8 | 100 Ω | |
| R19 | 2.2k | |
| J2 | 1x9 male header, 0.1" | Jumper wires to MyMENSCH **J3**, pins as labelled |
| J1 | 5 wire pads | Solder in the wires of a 6-pin mini-DIN cable (PR1, SQC, PKS, GND, PKD; pin 4 PR9 not used) |

The J2 labels show which **J3** pin each wire goes to: PA7 → J3-29, +3V3 → J3-49, PA5 → J3-33, PA4 → J3-35, PA3–PA0 → J3-37/39/41/43, GND → J3-50.

These are VIA_A port A pins. This FPGA image has no VIA_B or VIA_C (`probes/regmap.asm` showed it). On J3, **pin 49 is +3V3 and pin 50 is GND**, the reverse of J4.

## Checks done by `mk_pcb.py`

- **Clearance:** every pair of different nets is at least 0.45 mm apart. The closest is 0.64 mm, between neighbouring J2 header pins.
- **Connectivity:** each net's copper is one connected piece containing all its pads.
- **Ground fill:** after the isolation channels are cut, every ground pad sits in one connected ground fill. One small floating copper island is left over; it's harmless.
- **Tolerance:** the isolation passes, 0.39 mm wide in total, never reach another net's copper.
