REM Build the MyMENSCH dbg.inc demo
del dbgdemo.obj dbgdemo.lst dbgdemo.bin dbgdemo.s19 2>nul
WDC02AS -g -l dbgdemo.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ dbgdemo
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 dbgdemo
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM10 dbgdemo.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
