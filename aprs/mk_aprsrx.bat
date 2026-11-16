REM Build the APRS receiver for the MyMENSCH Rev-C (W65C02 core)
REM Output: aprsrx.bin (for wdc_uploader_term) and aprsrx.s19 (for the tests)

del aprsrx.obj aprsrx.lst aprsrx.bin aprsrx.s19 2>nul

WDC02AS -g -l aprsrx.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ aprsrx
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 aprsrx
if errorlevel 1 goto fail
echo Build OK
echo Load and run:  wdc_uploader_term.exe -d COM10 aprsrx.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
