# aprsmap: APRS map in a text terminal

This shows the APRS stations you hear on an ASCII map centred on your station, in an ordinary terminal window (Windows Terminal, cmd, PuTTY over SSH, a Linux console). There's no GUI and no internet map.

```
 aprsmap  KC4UMS  home 35.0000,-85.0000  range 50 mi (auto)  heard 6  stations 6
                ......N......                | Call          mi  Brg  Age
           .....             .....           | >KC4UMS-9   11.5   0   0m car
        ....                     ....        | -W4XX       18.9 270   0m house
  ..            .......25....            ..  | #N4YY       14.9 140   0m digi Signal Mtn
 .  >K4ZZ   ..        >KC4UMS-9..          . |  W1AW          -       0m status only
.          .      _WX4A          .          .| >K4ZZ       43.1 289   0m
W          .  -W4XX   @          .          E| _WX4A       11.0 301   0m 090/005g010t077
 .          ..            #N4YY..          . |
----------------------------------------------------------------------------------------------
13:33 N4YY>APRS:!3450.00N/08450.00W#digi Signal Mtn
```

- **Map:** north is up, `@` is you, and the dotted rings are full and half range.
  - Each station is drawn with its own APRS symbol character: `-` house, `>` car, `#` digi, `_` weather, and so on.
  - Bright means heard in the last 10 min, normal means within 30 min, dim means older.
  - A `+` on the edge is a station beyond the map.
- **List:** every station, newest first, with distance, bearing, how long ago it was heard, and its comment or status.
- **Bottom:** the latest raw packets.
- **Keys:** `:` (or Enter) command line, `+` / `-` zoom, `a` back to auto range, `c` clear, `q` quit.

## Command line

Press `:` or Enter. A `TNC>` prompt opens at the bottom, and what you type goes to the TNC on the serial port when you press Enter.
- **Single keys:** a one-character command (`B` beacon, `P` periodic on/off, `S` status, `T` test mode, `1` / `2` tones, `?` help) is sent on its own. `tnc134` acts on single keys, and a CR after a tone key would stop the tone at once.
- **Longer commands:** anything longer is sent with a CR, ready for line commands the TNC may get later.
- **Replies:** the TNC's replies (`TX ...`, `done`, the status line) show in the packet area under the map, along with what you sent.
- **Keys at the prompt:** Esc cancels, Backspace edits, Up and Down recall earlier commands.

This only works with a serial TNC. With KISS over TCP or a log file there's nothing to send to, and it says so.

## Running it

```
python aprsmap.py SOURCE --home LAT,LON [--call KC4UMS] [--range 50] [--km] [--log heard.txt]
```

`--home` takes decimal degrees, with west and south negative (`35.0,-85.0`), or a grid square (`EM75`, `EM75kb`).

| Source | Use it for |
|---|---|
| `COM5` | A TNC that prints monitored packets as text, `CALL>DEST,PATH:info`. This covers TNC2-style monitors such as the PK-232 (`<UI>` tags are fine). Set `--baud` to match. |
| `COM5 --kiss` | A TNC in KISS mode. |
| `tcp:localhost:8001` | KISS over TCP. **Direwolf** uses port 8001: a PC sound card and the radio, with no TNC hardware at all. |
| `heard.txt` | Replays a saved log (`--speed 0` loads it all at once). |

**`tnc134` doesn't receive yet:** it only transmits. Until its receive side is written, use another TNC or Direwolf as the source. When it does receive, it will print each packet as a `CALL>DEST,PATH:info` line, and `aprsmap.py COM5` will map them directly.

**Trying it with `tnc134`'s test mode:** this needs no radio. It shows 20 simulated stations around South Georgia, two of them moving:

```
python aprsmap.py COM5 --send T --home 31.45,-83.51
```

`--send T` presses `T` (test mode) on the TNC when the port opens. See `../../tnc134/README.md`.

**Loading `tnc134` first:** `--load` puts the TNC program on the W65C134SXB through its monitor, the same way `../sxb134/sxb134.py` does. It loads, verifies and starts it at `$2000`, then opens the map, so one command does it all:

```
python aprsmap.py COM5 --load --send T --home 31.45,-83.51
```

- **What it loads:** `--load` alone loads `tnc134/tnc134.hex`. `--load FILE` loads another file, and `--go ADDR` changes the start address.
- **Before you run it:** the board must be at the monitor prompt. Press RESET first if a program is already running.

**What's decoded for the map:**
- plain and compressed positions, with or without a timestamp;
- Mic-E;
- objects and items (a killed one is removed);
- third-party packets, whose inner packet is mapped.

Status packets and messages show up in the list, with no position.

**Needs:** Python 3. pyserial is needed only for serial ports. The terminal must handle ANSI colours, which Windows 10 and later do.

## Test

```
python test_aprsmap.py
```

It checks:
- each position format against known values, including the APRS spec's compressed example and a hand-encoded Mic-E;
- KISS unframing and unescaping;
- distance, bearing and grid squares;
- one full screen draw.
