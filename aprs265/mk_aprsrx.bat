REM Build the APRS receiver for the W65C265S (MyMensch)
REM Output: aprsrx.s28 (load with the monitor S command or a terminal upload)
REM         aprsrx.bin (WDC binary, for EasySXB)

del aprsrx.obj aprsrx.lst aprsrx.s28 aprsrx.bin 2>nul

WDC816AS -g -l aprsrx.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM28 aprsrx
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ aprsrx
if errorlevel 1 goto fail
echo Build OK
goto end
:fail
echo BUILD FAILED
:end
