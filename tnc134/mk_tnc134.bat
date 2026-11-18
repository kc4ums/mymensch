REM Build the W65C134SXB software TNC
del tnc134.obj tnc134.lst tnc134.hex tnc134.s28 tnc134.s19 2>nul
python mk_sim.py
if errorlevel 1 goto fail
WDC02AS -g -l tnc134.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HI tnc134
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM28 tnc134
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 tnc134
if errorlevel 1 goto fail
echo Build OK
echo Load tnc134.hex with EasySXB (9600 baud), then JMP 00:2000
goto end
:fail
echo BUILD FAILED
:end
