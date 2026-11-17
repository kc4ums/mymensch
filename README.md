# MyMENSCH APRS

APRS projects for WDC's MyMENSCH Rev-C board (W65C165i1 on an Intel MAX 10 10M08 FPGA).

- `aprs/` - APRS receiver: an AEA PK-232 TNC on ACIA_B, decoded packets on the USB console. Also hardware probes (`aprs/probe/`) and a 65C02 test bench (`aprs/test/`).
- `tnc/` - software TNC: the MyMENSCH sends APRS packets as audio straight to a radio's data port (transmit side; receive next).
- `monitor/` - MMON, a machine-language monitor: dump/edit memory and I/O, load S19 files, run code, catch BRKs.

See `aprs/README.md` for wiring, building and loading.
