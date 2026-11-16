REM Build the MyMENSCH MMON monitor
del mmon.obj mmon.lst mmon.bin mmon.s19 2>nul
WDC02AS -g -l mmon.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ mmon
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 mmon
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM10 mmon.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
