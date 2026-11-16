REM Build the MyMENSCH hardware probe
del probe.obj probe.lst probe.bin probe.s19 2>nul
WDC02AS -g -l probe.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ probe
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 probe
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM10 probe.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
