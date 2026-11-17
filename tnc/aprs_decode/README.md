# APRS decoder (from the old PK-232 receiver)

`aprsrx.asm` was the first version of this project. It read text lines from an AEA PK-232 TNC on ACIA_B and decoded the APRS in them. The software TNC no longer uses a PK-232, so this program isn't run any more. It's kept because its decoder will be reused for the TNC's receive side.

What it decodes:
- position, plain and compressed
- Mic-E
- weather
- messages, including ACK/REJ and bulletins
- objects and items
- status
- third-party traffic
- telemetry and other types, labelled

The receive side will format each received AX.25 frame as the same `CALL>DEST,PATH:info` text line the PK-232 printed, then pass it to this decoder.

`run_tests.py` checks the decoder on the emulator (`../../tools/emu`) with about 25 packet types:

```
python run_tests.py        (add -v to see the decoded output)
```

To rebuild it, use `mk_aprsrx.bat`.

Note that its I/O assumptions came from the datasheet and are wrong for this board's FPGA image. Its console code is fine, but it uses ACIA_B for the TNC and has its own timing assumptions. Treat it as decoder source, not as a program to load.
