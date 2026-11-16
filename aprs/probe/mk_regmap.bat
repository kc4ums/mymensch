REM Build the MyMENSCH register map probe
del regmap.obj regmap.lst regmap.bin regmap.s19 2>nul
WDC02AS -g -l regmap.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HZ regmap
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 regmap
if errorlevel 1 goto fail
echo Build OK
echo Run:  wdc_uploader_term.exe -d COM10 regmap.bin -m write -x -s 5 -t
goto end
:fail
echo BUILD FAILED
:end
