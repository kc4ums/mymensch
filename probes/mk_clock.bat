REM Build the MyMENSCH clock probe
del clock.obj clock.lst clock.bin clock.s19 2>nul
WDC02AS -g -l clock.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ clock
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 clock
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM4 clock.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
