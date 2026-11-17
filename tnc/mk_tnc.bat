REM Build the MyMENSCH software TNC
del tnc.obj tnc.lst tnc.bin tnc.s19 2>nul
WDC02AS -g -l tnc.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ tnc
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 tnc
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM4 tnc.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
