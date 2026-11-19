"""C02COMM: a W65C02S board for the radio projects, all through-hole.

This file is the design: every part, its footprint, where it sits and what
each pin connects to. mk_pcb.py builds the KiCad board from it, mk_sch.py the
schematic, and check_board.py checks it (pinouts, nets, decoding).

Memory map
    $0000-$7EFF  RAM, AS6C62256 (32 KB, the top 256 bytes are I/O)
    $7F00-$7F0F  VIA1  W65C22N  radio ports 1 and 2
    $7F10-$7F1F  VIA2  W65C22N  LCD, PS/2 keyboard, flash bank, LEDs
    $7F20-$7F2F  ACIA  W65C51N  serial to the USB module
    $7F30-$7F5F  /CS3, /CS4, /CS5 on the I/O header (16 bytes each)
    $7F60-$7FFF  free (nothing selected)
    $8000-$FFFF  flash, SST39SF010A: one of four 32 KB banks (VIA2 PA6/PA7,
                 pulled low, so bank 0 at reset). JP1 write-protects it.
Clock: 3.6864 MHz oscillator (socketed), the same as the TNC code expects.
"""

# ------------------------------------------------------------ footprints
FP = {
    'DIP8': 'Package_DIP:DIP-8_W7.62mm_Socket',
    'DIP14': 'Package_DIP:DIP-14_W7.62mm_Socket',
    'DIP16': 'Package_DIP:DIP-16_W7.62mm_Socket',
    'DIP28': 'Package_DIP:DIP-28_W15.24mm_Socket',
    'DIP32': 'Package_DIP:DIP-32_W15.24mm_Socket',
    'DIP40': 'Package_DIP:DIP-40_W15.24mm_Socket',
    'OSC': 'Oscillator:Oscillator_DIP-8',
    'R': 'Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal',
    'C': 'Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm',
    'CP5': 'Capacitor_THT:CP_Radial_D5.0mm_P2.00mm',
    'CP8': 'Capacitor_THT:CP_Radial_D8.0mm_P3.50mm',
    'TO92': 'Package_TO_SOT_THT:TO-92_Inline_Wide',
    'TO220': 'Package_TO_SOT_THT:TO-220-3_Vertical',
    'D41': 'Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal',
    'LED': 'LED_THT:LED_D3.0mm',
    'POT': 'Potentiometer_THT:Potentiometer_Bourns_3296W_Vertical',
    'SW': 'Button_Switch_THT:SW_PUSH_6mm',
    'JACK': 'Connector_BarrelJack:BarrelJack_Horizontal',
    'TB2': 'TerminalBlock_Phoenix:TerminalBlock_Phoenix_MKDS-1,5-2_1x02_P5.00mm_Horizontal',
    'TB5': 'TerminalBlock_Phoenix:TerminalBlock_Phoenix_MKDS-1,5-5_1x05_P5.00mm_Horizontal',
    'H1x2': 'Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical',
    'H1x3': 'Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical',
    'H1x4': 'Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical',
    'H1x6': 'Connector_PinHeader_2.54mm:PinHeader_1x06_P2.54mm_Vertical',
    'H1x16': 'Connector_PinHeader_2.54mm:PinHeader_1x16_P2.54mm_Vertical',
    'H2x10': 'Connector_PinHeader_2.54mm:PinHeader_2x10_P2.54mm_Vertical',
    'HOLE': 'MountingHole:MountingHole_3.2mm_M3',
}

BOARD_W, BOARD_H = 185.0, 125.0

PARTS = []          # dicts: ref, value, fp, x, y, rot, pins {pad: net}, part, note


def part(ref, value, fp, x, y, rot=0, pins=None, mpn='', note='', dnp=False):
    PARTS.append(dict(ref=ref, value=value, fp=fp, x=x, y=y, rot=rot,
                      pins={str(k): v for k, v in (pins or {}).items()},
                      mpn=mpn, note=note, dnp=dnp))


def bus(prefix, n, start=0):
    return ['%s%d' % (prefix, i) for i in range(start, start + n)]


A = bus('A', 16)
D = bus('D', 8)

# ------------------------------------------------------------ CPU and memory
# W65C02S (DIP-40). RDY has a pull-up because WAI drives it low.
part('U1', 'W65C02S6TPG-14', 'DIP40', 62, 12, pins={
    1: None, 2: 'RDY', 3: None, 4: '~{IRQ}', 5: None, 6: '~{NMI}', 7: None, 8: '+5V',
    9: 'A0', 10: 'A1', 11: 'A2', 12: 'A3', 13: 'A4', 14: 'A5', 15: 'A6', 16: 'A7',
    17: 'A8', 18: 'A9', 19: 'A10', 20: 'A11', 21: 'GND', 22: 'A12', 23: 'A13', 24: 'A14',
    25: 'A15', 26: 'D7', 27: 'D6', 28: 'D5', 29: 'D4', 30: 'D3', 31: 'D2', 32: 'D1',
    33: 'D0', 34: 'RW', 35: None, 36: '+5V', 37: 'PHI2', 38: '+5V', 39: None, 40: '~{RES}'},
    mpn='WDC W65C02S6TPG-14', note='40-pin socket')

# AS6C62256 32K x 8 SRAM (DIP-28, JEDEC 62256 pinout)
part('U2', 'AS6C62256-55PCN', 'DIP28', 84, 12, pins={
    1: 'A14', 2: 'A12', 3: 'A7', 4: 'A6', 5: 'A5', 6: 'A4', 7: 'A3', 8: 'A2', 9: 'A1', 10: 'A0',
    11: 'D0', 12: 'D1', 13: 'D2', 14: 'GND', 15: 'D3', 16: 'D4', 17: 'D5', 18: 'D6', 19: 'D7',
    20: '~{RAMCS}', 21: 'A10', 22: '~{RD}', 23: 'A11', 24: 'A9', 25: 'A8', 26: 'A13',
    27: '~{WR}', 28: '+5V'}, mpn='Alliance AS6C62256-55PCN', note='28-pin 0.6" socket')

# SST39SF010A 128K x 8 flash (DIP-32, JEDEC). A15/A16 = bank select.
part('U3', 'SST39SF010A-70-4C-PHE', 'DIP32', 106, 12, pins={
    1: None, 2: 'FA16', 3: 'FA15', 4: 'A12', 5: 'A7', 6: 'A6', 7: 'A5', 8: 'A4', 9: 'A3',
    10: 'A2', 11: 'A1', 12: 'A0', 13: 'D0', 14: 'D1', 15: 'D2', 16: 'GND', 17: 'D3', 18: 'D4',
    19: 'D5', 20: 'D6', 21: 'D7', 22: '~{ROMCS}', 23: 'A10', 24: '~{RD}', 25: 'A11', 26: 'A9',
    27: 'A8', 28: 'A13', 29: 'A14', 30: None, 31: '~{FWE}', 32: '+5V'},
    mpn='Microchip SST39SF010A-70-4C-PHE', note='32-pin 0.6" socket (ZIF if you reflash a lot)')

# ------------------------------------------------------------ I/O chips
def via(common, extra):
    d = dict(common)
    d.update(extra)
    return d


VIA_COMMON = {1: 'GND', 20: '+5V', 21: '~{IRQ}', 22: 'RW', 24: '+5V', 25: 'PHI2',
              26: 'D7', 27: 'D6', 28: 'D5', 29: 'D4', 30: 'D3', 31: 'D2', 32: 'D1', 33: 'D0',
              34: '~{RES}', 35: 'A3', 36: 'A2', 37: 'A1', 38: 'A0'}

# VIA1: the two radio ports. Comparator outputs also on CA1/CB1 (edge interrupts).
part('U4', 'W65C22N6TPG-14', 'DIP40', 128, 12, pins=via(VIA_COMMON, {
    2: 'R1_D0', 3: 'R1_D1', 4: 'R1_D2', 5: 'R1_D3', 6: 'R1_KEY', 7: 'R1_SQ', 8: 'V1_PA6',
    9: 'R1_RX', 10: 'R2_D0', 11: 'R2_D1', 12: 'R2_D2', 13: 'R2_D3', 14: 'R2_KEY',
    15: 'R2_SQ', 16: 'V1_PB6', 17: 'R2_RX', 18: 'R2_RX', 19: 'V1_CB2', 23: '~{CS0}',
    39: 'V1_CA2', 40: 'R1_RX'}), mpn='WDC W65C22N6TPG-14 (N = open-drain IRQ)',
    note='must be the N version: IRQ outputs are wire-ORed')

# VIA2: LCD (4-bit), flash bank, LEDs, PS/2 keyboard on CA1 (clock) / CA2 (data).
part('U5', 'W65C22N6TPG-14', 'DIP40', 150, 12, pins=via(VIA_COMMON, {
    2: 'LCD_D4', 3: 'LCD_D5', 4: 'LCD_D6', 5: 'LCD_D7', 6: 'LCD_RS', 7: 'LCD_E',
    8: 'FA15', 9: 'FA16', 10: 'LED0', 11: 'LED1', 12: 'LED2', 13: 'LED3', 14: 'V2_PB4',
    15: 'V2_PB5', 16: 'V2_PB6', 17: 'V2_PB7', 18: 'V2_CB1', 19: 'V2_CB2', 23: '~{CS1}',
    39: 'KB_DATA', 40: 'KB_CLK'}), mpn='WDC W65C22N6TPG-14 (N = open-drain IRQ)',
    note='must be the N version: IRQ outputs are wire-ORed')

# ACIA, clocked by its own 1.8432 MHz oscillator into XTLI.
part('U6', 'W65C51N6TPG-14', 'DIP28', 150, 72, pins={
    1: 'GND', 2: '+5V', 3: '~{CS2}', 4: '~{RES}', 5: None, 6: 'ACIA_CLK', 7: None,
    8: 'SER_RTS', 9: 'SER_CTS', 10: 'SER_TX', 11: None, 12: 'SER_RX', 13: 'A0', 14: 'A1',
    15: '+5V', 16: 'GND', 17: 'GND', 18: 'D0', 19: 'D1', 20: 'D2', 21: 'D3', 22: 'D4',
    23: 'D5', 24: 'D6', 25: 'D7', 26: '~{IRQ}', 27: 'PHI2', 28: 'RW'},
    mpn='WDC W65C51N6TPG-14', note='transmit-empty flag is stuck: send with a timed delay')

# ------------------------------------------------------------ glue logic
# U7 74HC00: ~A15, ~RW, ~RD = NAND(PHI2,RW), ~WR = NAND(PHI2,~RW)
part('U7', '74HC00', 'DIP14', 64, 72, pins={
    1: 'A15', 2: 'A15', 3: '~{ROMCS}', 4: 'RW', 5: 'RW', 6: 'NRW', 7: 'GND',
    8: '~{RD}', 9: 'PHI2', 10: 'RW', 11: '~{WR}', 12: 'PHI2', 13: 'NRW', 14: '+5V'},
    mpn='74HC00 (TI SN74HC00N)')
# U8 74HC00: ~RAMCS = NAND(~A15, ~IOSEL); spare gates tied off
part('U8', '74HC00', 'DIP14', 76, 72, pins={
    1: '~{ROMCS}', 2: '~{IOSEL}', 3: '~{RAMCS}', 4: 'GND', 5: 'GND', 6: None, 7: 'GND',
    8: None, 9: 'GND', 10: 'GND', 11: None, 12: 'GND', 13: 'GND', 14: '+5V'},
    mpn='74HC00 (TI SN74HC00N)')
# U9 74HC30: ~IOSEL low for $7Fxx: A8..A14 = 1 and A15 = 0 (~A15 = 1)
part('U9', '74HC30', 'DIP14', 88, 72, pins={
    1: 'A8', 2: 'A9', 3: 'A10', 4: 'A11', 5: 'A12', 6: 'A13', 7: 'GND', 8: '~{IOSEL}',
    9: None, 10: None, 11: 'A14', 12: '~{ROMCS}', 13: None, 14: '+5V'},
    mpn='74HC30 (TI SN74HC30N)')
# U10 74HC138: 16-byte selects in $7F00-$7F7F (A7 = 0)
part('U10', '74HC138', 'DIP16', 100, 72, pins={
    1: 'A4', 2: 'A5', 3: 'A6', 4: '~{IOSEL}', 5: 'A7', 6: '+5V', 7: None, 8: 'GND',
    9: None, 10: '~{CS5}', 11: '~{CS4}', 12: '~{CS3}', 13: '~{CS2}', 14: '~{CS1}',
    15: '~{CS0}', 16: '+5V'}, mpn='74HC138 (TI SN74HC138N)')

# Oscillators: pin 1 (enable on some parts) to +5V, 4 GND, 5 out, 8 +5V
part('X1', '3.6864MHz', 'OSC', 113, 92, pins={1: '+5V', 4: 'GND', 5: 'PHI2', 8: '+5V'},
     mpn='ECS-100AX-036 or any 5 V HCMOS full/half-can', note='8-pin socket: change the CPU clock here')
part('X2', '1.8432MHz', 'OSC', 135, 92, pins={1: '+5V', 4: 'GND', 5: 'ACIA_CLK', 8: '+5V'},
     mpn='ECS-100AX-018 or any 5 V HCMOS half-can', note='8-pin socket')

# Reset: DS1813 supervisor (open drain, internal pull-up, debounces the button)
part('U11', 'DS1813-10+', 'TO92', 64, 100, pins={1: '~{RES}', 2: '+5V', 3: 'GND'},
     mpn='Analog Devices DS1813-10+', note='flat face toward the board edge')
part('SW1', 'RESET', 'SW', 72, 97, pins={1: '~{RES}', 2: 'GND'}, mpn='6 mm tactile switch')
part('SW2', 'NMI', 'SW', 86, 97, pins={1: '~{NMI}', 2: 'GND'}, mpn='6 mm tactile switch')
part('R30', '3.3k', 'R', 64, 66, pins={1: '+5V', 2: '~{NMI}'})
part('C30', '100nF', 'C', 98, 104, pins={1: '~{NMI}', 2: 'GND'}, note='debounces NMI')
part('R31', '3.3k', 'R', 64, 69, pins={1: '+5V', 2: '~{IRQ}'})
part('R32', '3.3k', 'R', 78, 66, pins={1: '+5V', 2: 'RDY'})

# Flash write protect: JP1 1-2 = writable, 2-3 = protected
part('JP1', 'FLASH WE', 'H1x3', 120, 70, pins={1: '~{WR}', 2: '~{FWE}', 3: '+5V'},
     note='1-2 write, 2-3 protect')
part('R33', '10k', 'R', 120, 80, rot=90, pins={1: 'FA15', 2: 'GND'}, note='bank 0 at reset')
part('R34', '10k', 'R', 124, 80, rot=90, pins={1: 'FA16', 2: 'GND'})

# ------------------------------------------------------------ serial (USB module)
# 6-pin FTDI-style header: GND CTS VCC TXD RXD RTS (TTL-232R-5V / CH340 boards)
part('J5', 'USB-SERIAL', 'H1x6', 175, 70, pins={
    1: 'GND', 2: 'SER_RTS', 3: 'USB_5V', 4: 'SER_RX', 5: 'SER_TX', 6: 'SER_CTS'},
    note='GND CTS VCC TXD RXD RTS, 5 V TTL module (FTDI TTL-232R-5V, CH340G board)')
part('R35', '10k', 'R', 160, 104, pins={1: 'SER_CTS', 2: 'GND'}, note='CTS active without a module')
part('JP2', 'USB PWR', 'H1x2', 170, 92, pins={1: 'USB_5V', 2: '+5V'},
     note='fit only when the board has no other supply')

# ------------------------------------------------------------ power
part('J1', '9-15V', 'TB2', 4, 20, rot=270, pins={1: 'VRAW', 2: 'GND'},
     mpn='Phoenix MKDS 1,5/2-5,08 or any 5 mm screw terminal')
part('D1', '1N5819', 'D41', 20, 16, pins={1: 'VIN', 2: 'VRAW'}, note='reverse polarity protection')
part('C1', '100uF 25V', 'CP8', 34, 7, pins={1: 'VIN', 2: 'GND'})
part('U12', 'LM7805', 'TO220', 40, 16, pins={1: 'VIN', 2: 'GND', 3: '+5V'},
     mpn='LM7805 (TO-220) with a clip-on heatsink')
part('C2', '10uF', 'CP5', 50, 9, pins={1: '+5V', 2: 'GND'})
part('C3', '100nF', 'C', 50, 22, pins={1: '+5V', 2: 'GND'})
part('D2', 'PWR', 'LED', 24, 24, pins={1: 'NLEDP', 2: '+5V'}, mpn='3 mm LED, green')
part('R36', '1k', 'R', 30, 28, pins={1: 'NLEDP', 2: 'GND'})

# decoupling: one 100 nF per chip
for ref, x, y in (('C10', 58, 62), ('C11', 80, 48), ('C12', 102, 54), ('C13', 124, 62),
                  ('C14', 146, 62), ('C15', 145, 100), ('C16', 71, 86), ('C17', 83, 86),
                  ('C18', 95, 88), ('C19', 108, 90), ('C20', 47, 74), ('C21', 112, 104),
                  ('C22', 134, 104)):
    part(ref, '100nF', 'C', x, y, pins={1: '+5V', 2: 'GND'})
part('C23', '10uF', 'CP5', 160, 98, pins={1: '+5V', 2: 'GND'})

# ------------------------------------------------------------ LEDs on VIA2 PB0-PB3
for i in range(4):
    part('D%d' % (10 + i), 'LED', 'LED', 128 + 6 * i, 107, pins={1: 'NL%d' % i, 2: 'LED%d' % i},
         mpn='3 mm LED')
    part('R%d' % (40 + i), '1k', 'R', 128 + 6 * i, 94, rot=90, pins={1: 'NL%d' % i, 2: 'GND'})

# ------------------------------------------------------------ LCD, keyboard, I/O header
# HD44780 20x4 in 4-bit mode, write only (R/W to GND)
part('J3', 'LCD 20x4', 'H1x16', 128, 3, rot=270, pins={
    1: 'GND', 2: '+5V', 3: 'LCD_V0', 4: 'LCD_RS', 5: 'GND', 6: 'LCD_E', 7: None, 8: None,
    9: None, 10: None, 11: 'LCD_D4', 12: 'LCD_D5', 13: 'LCD_D6', 14: 'LCD_D7',
    15: 'LCD_BL', 16: 'GND'}, note='HD44780 16-pin: VSS VDD V0 RS RW E D0-D7 A K')
part('RV3', '10k', 'POT', 122, 6, pins={1: '+5V', 2: 'LCD_V0', 3: 'GND'}, note='LCD contrast')
part('R37', '33', 'R', 104, 4, pins={1: '+5V', 2: 'LCD_BL'}, note='LCD backlight')

# PS/2 keyboard: to a PS/2 socket breakout (VCC GND CLK DATA)
part('J4', 'PS/2 KBD', 'H1x4', 175, 20, pins={1: '+5V', 2: 'GND', 3: 'KB_CLK', 4: 'KB_DATA'},
     note='+5V GND CLK DATA, to a PS/2 socket breakout')
part('R38', '4.7k', 'R', 168, 36, rot=90, pins={1: '+5V', 2: 'KB_CLK'})
part('R39', '4.7k', 'R', 172, 36, rot=90, pins={1: '+5V', 2: 'KB_DATA'})

# I/O header 2x10
part('J6', 'I/O', 'H2x10', 172, 76 + 0, rot=0, pins={
    1: '+5V', 2: 'GND', 3: 'V2_PB4', 4: 'V2_PB5', 5: 'V2_PB6', 6: 'V2_PB7', 7: 'V2_CB1',
    8: 'V2_CB2', 9: 'V1_PA6', 10: 'V1_PB6', 11: 'V1_CA2', 12: 'V1_CB2', 13: '~{CS3}',
    14: '~{CS4}', 15: '~{IRQ}', 16: '~{RES}', 17: 'PHI2', 18: 'RW', 19: '~{CS5}', 20: 'GND'})

# ------------------------------------------------------------ radio ports
# Same circuit as ../radio_interface.svg (proven with the TNC), two copies.
# LM393: comparator A = radio 1, B = radio 2; one shared reference.
part('U13', 'LM393', 'DIP8', 44, 64, pins={
    1: 'R1_RX', 2: 'VREF', 3: 'R1_NA', 4: 'GND', 5: 'R2_NA', 6: 'VREF', 7: 'R2_RX', 8: '+5V'},
    mpn='LM393N')
part('R4', '10k', 'R', 36, 54, rot=90, pins={1: '+5V', 2: 'VREF'}, note='VREF = 2.0 V')
part('R5', '6.8k', 'R', 40, 54, rot=90, pins={1: 'VREF', 2: 'GND'})
part('C4', '10uF', 'CP5', 50, 56, pins={1: 'VREF', 2: 'GND'})


def radio(n, y0):
    """One radio port: J (ANI GND PTT ANO SQC), comparator input, SQC, PTT, DAC."""
    p = 'R%d_' % n
    b = 100 * n                     # reference numbers: radio 1 = 1xx, radio 2 = 2xx
    part('J%d' % (6 + n), 'RADIO %d' % n, 'TB5', 4, y0, rot=270, pins={
        1: p + 'ANI', 2: 'GND', 3: p + 'PTT', 4: p + 'ANO', 5: p + 'SQC'},
        mpn='5 mm 5-way screw terminal',
        note='to the radio data port: ANI (pin 1), GND (2), PTT (3), ANO (5), SQC (6)')
    # receive: AC coupling into the comparator with hysteresis
    part('C%d' % (b + 1), '1uF', 'C', 14, y0 + 13, pins={1: p + 'ANO', 2: p + 'NC1'})
    part('R%d' % (b + 1), '10k', 'R', 22, y0 + 13, pins={1: p + 'NC1', 2: p + 'NA'})
    part('R%d' % (b + 2), '100k', 'R', 22, y0 + 17, pins={1: 'VREF', 2: p + 'NA'})
    part('R%d' % (b + 3), '1M', 'R', 22, y0 + 21, pins={1: p + 'RX', 2: p + 'NA'})
    part('R%d' % (b + 6), '10k', 'R', 22, y0 + 25, pins={1: '+5V', 2: p + 'RX'}, note='comparator pull-up')
    # squelch: series 10k; the 20k divider is only for 3.3 V boards
    part('R%d' % (b + 20), '10k', 'R', 14, y0 - 4, pins={1: p + 'SQC', 2: p + 'SQ'})
    part('R%d' % (b + 21), '20k', 'R', 14, y0 - 8, pins={1: p + 'SQ', 2: 'GND'},
         note='do not fit on this 5 V board', dnp=True)
    # PTT: 2N7000 pulls the radio's PTT line to ground
    part('Q%d' % n, '2N7000', 'TO92', 26, y0 + 1, pins={1: 'GND', 2: p + 'G', 3: p + 'PTT'},
         mpn='2N7000 (TO-92)')
    part('R%d' % (b + 8), '100', 'R', 31, y0 - 4, pins={1: p + 'G', 2: p + 'KEY'})
    part('R%d' % (b + 9), '100k', 'R', 31, y0 - 8, pins={1: p + 'G', 2: 'GND'})
    part('D%d' % (3 + n), 'TX%d' % n, 'LED', 44, y0 - 8, pins={1: p + 'NL', 2: p + 'KEY'},
         mpn='3 mm LED, red')
    part('R%d' % (b + 22), '1k', 'R', 44, y0 - 4, pins={1: p + 'NL', 2: 'GND'})
    # transmit: 4-bit R-2R DAC, low-pass, level pot, divider
    for i, (pa, nd) in enumerate((('D3', 'N3'), ('D2', 'N2'), ('D1', 'N1'), ('D0', 'N0'))):
        part('R%d' % (b + 10 + i), '20k', 'R', 34 + 5 * i, y0 + 4, rot=90,
             pins={1: p + pa, 2: p + nd})
    for i, (a, c) in enumerate((('N3', 'N2'), ('N2', 'N1'), ('N1', 'N0'))):
        part('R%d' % (b + 14 + i), '10k', 'R', 34 + 5 * i + 2.5, y0 + 17, rot=90,
             pins={1: p + a, 2: p + c})
    part('R%d' % (b + 17), '20k', 'R', 52, y0 + 17, rot=90, pins={1: p + 'N0', 2: 'GND'})
    part('R%d' % (b + 7), '4.7k', 'R', 14, y0 + 30, pins={1: p + 'NF', 2: p + 'N3'})
    part('C%d' % (b + 3), '10nF', 'C', 28, y0 + 30, pins={1: p + 'NF', 2: 'GND'})
    part('C%d' % (b + 4), '1uF', 'C', 14, y0 + 34, pins={1: p + 'NF', 2: p + 'NE'})
    part('RV%d' % n, '10k', 'POT', 30, y0 + 35, pins={1: p + 'NE', 2: p + 'NW', 3: 'GND'},
         note='TX audio level')
    part('R%d' % (b + 18), '100k', 'R', 34, y0 + 30, pins={1: p + 'NW', 2: p + 'ANI'})
    part('R%d' % (b + 19), '2.2k', 'R', 34, y0 + 34, pins={1: p + 'ANI', 2: 'GND'})


radio(1, 24)
radio(2, 62)

# mounting holes
for i, (x, y) in enumerate(((4, 4), (BOARD_W - 4, 4), (4, BOARD_H - 4), (BOARD_W - 4, BOARD_H - 4))):
    part('H%d' % (i + 1), 'M3', 'HOLE', x, y)


def nets():
    """net -> [(ref, pad)]"""
    out = {}
    for p in PARTS:
        for pad, net in p['pins'].items():
            if net:
                out.setdefault(net, []).append((p['ref'], pad))
    return out


POWER_NETS = {'GND', '+5V', 'VIN', 'VRAW', 'USB_5V'}


# ------------------------------------------------------------ placement
# (x, y, rotation) of each footprint's origin, mm from the board's top-left.
PLACE = {
    # power, top left
    'J1': (6, 11, 270), 'D1': (14, 9, 0), 'C1': (31, 11, 0), 'U12': (40, 12, 0),
    'C2': (51, 12, 0), 'C3': (56.5, 12, 0), 'D2': (15, 19.5, 0), 'R36': (21, 19.5, 0),
    # comparator and its reference, bottom left
    'U13': (16, 104, 0), 'R4': (30, 114, 90), 'R5': (34, 114, 90), 'C4': (39, 108, 0),
    'C20': (16, 118, 0),
    # the five big chips, top row
    'U1': (68, 12, 0), 'U2': (90, 12, 0), 'U3': (112, 12, 0), 'U4': (134, 12, 0), 'U5': (156, 12, 0),
    'C10': (70, 64.5, 0), 'C11': (92, 49, 0), 'C12': (114, 54.5, 0), 'C13': (136, 64.5, 0),
    'C14': (158, 64.5, 0),
    # LCD header, contrast, backlight, top edge
    'J3': (172, 4.5, 270), 'RV3': (128, 5, 0), 'R37': (106, 5, 0),
    # PS/2, right edge
    'J4': (181, 14, 0), 'R38': (176.5, 36, 90), 'R39': (180, 36, 90),
    # glue logic row
    'U7': (69, 70, 0), 'U8': (81, 70, 0), 'U9': (93, 70, 0), 'U10': (105, 70, 0),
    'C16': (69, 92, 0), 'C17': (81, 92, 0), 'C18': (93, 92, 0), 'C19': (105, 92, 0),
    'X1': (118, 80, 0), 'C21': (118, 86, 0),
    'JP1': (133, 70, 0), 'R33': (133, 90, 90), 'R34': (137, 90, 90),
    # serial
    'U6': (142, 70, 0), 'C15': (144, 108, 0), 'X2': (162, 80, 0), 'C22': (162, 86.5, 0),
    'J5': (181, 72, 0), 'R35': (176, 86, 90), 'JP2': (181, 91, 0), 'C23': (169, 93, 0),
    # reset, NMI, pull-ups
    'U11': (70, 100, 0), 'SW1': (79, 98, 0), 'SW2': (91, 98, 0),
    'R30': (68, 108, 0), 'R31': (68, 112, 0), 'R32': (68, 116, 0), 'C30': (83, 108, 0),
    # I/O header, bottom edge
    'J6': (130, 120, 90),
    'H1': (4, 4, 0), 'H2': (181, 4, 0), 'H3': (4, 121, 0), 'H4': (181, 121, 0),
}
for i in range(4):
    PLACE['D%d' % (10 + i)] = (102 + 6 * i, 100, 0)
    PLACE['R%d' % (40 + i)] = (103 + 6 * i, 118, 90)


def _radio_place(n, y0):
    b = 100 * n
    cols = (14.5, 28.5, 42.5)
    grid = [('R%d' % (b + 20), 'R%d' % (b + 21), 'R%d' % (b + 8)),
            ('R%d' % (b + 9), 'R%d' % (b + 22), 'R%d' % (b + 1)),
            ('R%d' % (b + 2), 'R%d' % (b + 3), 'R%d' % (b + 6)),
            ('R%d' % (b + 10), 'R%d' % (b + 11), 'R%d' % (b + 12)),
            ('R%d' % (b + 13), 'R%d' % (b + 14), 'R%d' % (b + 15)),
            ('R%d' % (b + 16), 'R%d' % (b + 17), 'R%d' % (b + 7)),
            ('R%d' % (b + 18), 'R%d' % (b + 19), None)]
    for k, row in enumerate(grid):
        for c, ref in zip(cols, row):
            if ref:
                PLACE[ref] = (c, y0 + 2 + 4.0 * k, 0)
    PLACE['C%d' % (b + 1)] = (14.5, y0 + 30, 0)
    PLACE['C%d' % (b + 3)] = (24, y0 + 30, 0)
    PLACE['C%d' % (b + 4)] = (33.5, y0 + 30, 0)
    PLACE['J%d' % (6 + n)] = (6, y0 + 12, 270)
    PLACE['Q%d' % n] = (57, y0 + 3, 0)
    PLACE['D%d' % (3 + n)] = (57, y0 + 10, 0)
    PLACE['RV%d' % n] = (59, y0 + 17, 90)


_radio_place(1, 24)
_radio_place(2, 62)

for _p in PARTS:
    if _p['ref'] in PLACE:
        _p['x'], _p['y'], _p['rot'] = PLACE[_p['ref']]
    else:
        raise SystemExit('no placement for ' + _p['ref'])
