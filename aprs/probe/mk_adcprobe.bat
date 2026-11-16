REM Build the MyMENSCH ADC probe
del adcprobe.obj adcprobe.lst adcprobe.bin adcprobe.s19 2>nul
WDC02AS -g -l adcprobe.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ adcprobe
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 adcprobe
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM10 adcprobe.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
