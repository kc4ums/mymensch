REM Build the AMTOR station: RAM image (EasySXB, JMP 00:2000) and flash image
del amtor_ram.obj amtor_ram.lst amtor_ram.hex amtor_ram.s19 amtor_rom.obj amtor_rom.lst amtor_rom.bin amtor_rom.s19 2>nul
WDC02AS -g -l amtor_ram.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HI amtor_ram
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 amtor_ram
if errorlevel 1 goto fail
WDC02AS -g -l amtor_rom.asm
if errorlevel 1 goto fail
WDCLN -g -sz -t -HM19 amtor_rom
if errorlevel 1 goto fail
python mk_flash.py
if errorlevel 1 goto fail
echo Build OK
echo RAM test:  load amtor_ram.hex with EasySXB (9600 baud), then JMP 00:2000
echo Flash:     program amtor_flash.bin (128 KB) into the SXB's flash chip
goto end
:fail
echo BUILD FAILED
:end
