# MyMENSCH APRS

APRS projects for WDC's MyMENSCH Rev-C board (W65C165i1 on an Intel MAX 10 10M08 FPGA).

- `aprs/` - APRS receiver: an AEA PK-232 TNC on ACIA_B, decoded packets on the USB console. Also hardware probes (`aprs/probe/`) and a 65C02 test bench (`aprs/test/`).
- `aprs265/` - older version for the W65C265SXB. Not for the MyMENSCH.

See `aprs/README.md` for wiring, building and loading.
