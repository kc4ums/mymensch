"""Generate hardware/radio_interface.svg (MyMENSCH software-TNC radio interface)."""
import sys

out = []
W, H = 1240, 1150
INK = '#1a1a1a'
NOTE = '#555'
ACC = '#0b5cad'


def add(s):
    out.append(s)


def wire(*pts):
    add('<polyline fill="none" stroke="%s" stroke-width="2" points="%s"/>' % (
        INK, ' '.join('%g,%g' % p for p in pts)))


def text(x, y, s, size=13, anchor='start', color=INK, weight='normal', italic=False):
    s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    add('<text x="%g" y="%g" font-size="%d" text-anchor="%s" fill="%s" font-weight="%s"%s>%s</text>' % (
        x, y, size, anchor, color, weight, ' font-style="italic"' if italic else '', s))


def dot(x, y):
    add('<circle cx="%g" cy="%g" r="3.5" fill="%s"/>' % (x, y, INK))


def zig(n=6, amp=6, length=30):
    step = length / n
    return [(i * step + step / 2, amp if i % 2 == 0 else -amp) for i in range(n)]


def res_h(x1, x2, y, name, val, above=True):
    m = (x1 + x2) / 2
    a, b = m - 15, m + 15
    pts = [(x1, y), (a, y)] + [(a + dx, y + dy) for dx, dy in zig()] + [(b, y), (x2, y)]
    wire(*pts)
    ty = y - 12 if above else y + 24
    text(m, ty, '%s %s' % (name, val), 12, 'middle')


def res_v(x, y1, y2, name, val, left=False):
    m = (y1 + y2) / 2
    a, b = m - 15, m + 15
    pts = [(x, y1), (x, a)] + [(x + dy, a + dx) for dx, dy in zig()] + [(x, b), (x, y2)]
    wire(*pts)
    if left:
        text(x - 12, m + 4, '%s %s' % (name, val), 12, 'end')
    else:
        text(x + 12, m + 4, '%s %s' % (name, val), 12)


def cap_h(x1, x2, y, name, val, pol=False, above=True):
    m = (x1 + x2) / 2
    wire((x1, y), (m - 4, y))
    wire((m + 4, y), (x2, y))
    wire((m - 4, y - 11), (m - 4, y + 11))
    wire((m + 4, y - 11), (m + 4, y + 11))
    if pol:
        text(m - 12, y - 8, '+', 12, 'middle')
    text(m, y - 17 if above else y + 28, '%s %s' % (name, val), 12, 'middle')


def cap_v(x, y1, y2, name, val, pol=False, left=False):
    m = (y1 + y2) / 2
    wire((x, y1), (x, m - 4))
    wire((x, m + 4), (x, y2))
    wire((x - 11, m - 4), (x + 11, m - 4))
    wire((x - 11, m + 4), (x + 11, m + 4))
    if pol:
        text(x - 16 if not left else x + 16, m - 7, '+', 12, 'middle')
    if left:
        text(x - 16, m + 4, '%s %s' % (name, val), 12, 'end')
    else:
        text(x + 16, m + 4, '%s %s' % (name, val), 12)


def gnd(x, y):
    wire((x, y), (x, y + 10))
    for i, w in enumerate((12, 8, 4)):
        wire((x - w, y + 10 + i * 4), (x + w, y + 10 + i * 4))


def vcc(x, y):
    """+3V3 net label, wire comes from below to (x, y)."""
    wire((x, y), (x, y - 8))
    wire((x - 9, y - 8), (x + 9, y - 8))
    text(x, y - 13, '+3V3', 12, 'middle', ACC, 'bold')


def pin_l(x, y, label):          # pin on the right edge of the radio box
    add('<circle cx="%g" cy="%g" r="3" fill="white" stroke="%s" stroke-width="2"/>' % (x, y, INK))
    text(x - 10, y + 4, label, 13, 'end', weight='bold')


def pin_r(x, y, num, label):     # pin on the left edge of the J4 box
    add('<circle cx="%g" cy="%g" r="3" fill="white" stroke="%s" stroke-width="2"/>' % (x, y, INK))
    text(x + 10, y + 4, '%s  %s' % (num, label), 13, weight='bold')


# ---------------------------------------------------------------- frame
add('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
    'font-family="Helvetica, Arial, sans-serif">' % (W, H, W, H))
add('<rect width="100%" height="100%" fill="white"/>')
text(W / 2, 34, 'MyMENSCH Rev-C software TNC - Kenwood TM-V71A data port interface (1200 baud AFSK)', 20,
     'middle', weight='bold')
text(W / 2, 56, 'Rev 0.1 draft - J4 pin choices are provisional until regmap.bin confirms VIA_B port A',
     13, 'middle', NOTE, italic=True)

# radio box
RX0 = 210
add('<rect x="40" y="90" width="%d" height="840" rx="8" fill="#f6f6f6" stroke="%s" stroke-width="2"/>' % (RX0 - 40, INK))
text(125, 118, 'KENWOOD TM-V71A', 15, 'middle', weight='bold')
text(125, 136, 'DATA jack, 6-pin mini-DIN (rear)', 11, 'middle', NOTE)
# J4 box
JX = 1010
add('<rect x="%d" y="90" width="200" height="840" rx="8" fill="#f6f6f6" stroke="%s" stroke-width="2"/>' % (JX, INK))
text(JX + 100, 118, 'MyMENSCH J4', 16, 'middle', weight='bold')
text(JX + 100, 136, '3.3 V logic only', 11, 'middle', NOTE)

# section labels
for y, s in ((150, 'RECEIVE  -  audio to logic level (comparator with hysteresis)'),
             (448, 'TRANSMIT  -  4-bit R-2R DAC, low-pass, level set'),
             (712, 'PTT  -  open-drain key, held off during reset')):
    text(RX0 + 30, y, s, 13, color=ACC, weight='bold')

# ---------------------------------------------------------------- receive
YA = 215                  # audio / + input line
pin_l(RX0, YA, '5  PR1 RX audio')
wire((RX0, YA), (250, YA))
cap_h(250, 300, YA, 'C1', '1µF', above=False)
wire((300, YA), (330, YA))
res_h(330, 400, YA, 'R1', '10k', above=False)
NA = 450
wire((400, YA), (NA, YA))
dot(NA, YA)
wire((NA, YA), (560, YA))
# comparator U1A
add('<polygon points="560,190 560,290 660,240" fill="white" stroke="%s" stroke-width="2"/>' % INK)
text(570, YA + 5, '+', 16, weight='bold')
text(570, 270, '−', 18, weight='bold')
text(612, 312, 'U1A ½ LM393', 12, 'middle')
text(612, 326, 'pin 8 +3V3, pin 4 GND', 10, 'middle', NOTE)
# hysteresis R3 over the top
wire((NA, YA), (NA, 180))
res_h(NA, 720, 180, 'R3', '1M')
text(728, 184, 'hysteresis', 11, color=NOTE, italic=True)
NB = 720
wire((720, 180), (NB, 240))
wire((660, 240), (NB, 240))
dot(NB, 240)
# pull-up and output to J4
NC = 800
wire((NB, 240), (NC, 240))
dot(NC, 240)
res_v(NC, 240, 190, 'R6', '10k')   # drawn upward
vcc(NC, 190)
YRX = 240
wire((NC, YRX), (JX, YRX))
pin_r(JX, YRX, '29', 'VIA_B_PA7  RX in')
# bias: R2 from node A down to VREF
YV = 350
res_v(NA, YA, YV, 'R2', '100k', left=True)
wire((560, 265), (530, 265), (530, YV))
wire((300, YV), (530, YV))
dot(NA, YV)
dot(530, YV)
text(490, YV + 16, 'VREF ≈ 1.3 V', 11, 'middle', ACC)
res_v(300, YV, 290, 'R4', '10k', left=True)
vcc(300, 290)
dot(300, YV)
res_v(360, YV, 400, 'R5', '6.8k', left=True)
dot(360, YV)
gnd(360, 400)
cap_v(410, YV, 400, 'C2', '10µF', pol=True)
dot(410, YV)
gnd(410, 400)

# ---------------------------------------------------------------- transmit
SP = 870                  # R-2R spine
ys = [490, 540, 590, 640]  # PA3 (MSB) .. PA0 (LSB)
pins = [('37', 'VIA_B_PA3  DAC b3'), ('39', 'VIA_B_PA2  DAC b2'),
        ('41', 'VIA_B_PA1  DAC b1'), ('43', 'VIA_B_PA0  DAC b0')]
for i, (y, (num, lab)) in enumerate(zip(ys, pins)):
    pin_r(JX, y, num, lab)
    res_h(SP, JX, y, 'R%d' % (10 + i), '20k', above=True)
    dot(SP, y)
for i in range(3):
    res_v(SP, ys[i], ys[i + 1], 'R%d' % (14 + i), '10k', left=True)
res_v(SP, ys[3], 700, 'R17', '20k', left=True)
gnd(SP, 700)
# output from MSB node through filter
wire((SP, ys[0]), (SP, 470), (790, 470))
res_h(720, 790, 470, 'R7', '4.7k', above=True)
ND = 660
wire((720, 470), (ND, 470))
dot(ND, 470)
cap_v(ND, 470, 530, 'C3', '10nF')
gnd(ND, 530)
wire((ND, 470), (600, 470))
cap_h(560, 600, 470, 'C4', '1µF')
NE = 500
wire((560, 470), (NE, 470))
# trimpot RV1 vertical NE 430..530, wiper from left at 480
res_v(NE, 470, 570, 'RV1', '10k level', left=False)
gnd(NE, 570)
YM = 520
wire((RX0, YM), (290, YM))
dot(290, YM)
res_v(290, YM, 580, 'R19', '2.2k', left=True)
gnd(290, 580)
wire((290, YM), (330, YM))
res_h(330, 430, YM, 'R18', '100k', above=True)
wire((430, YM), (470, YM))
add('<polygon points="%g,%g %g,%g %g,%g" fill="%s"/>' % (488, YM, 474, YM - 6, 474, YM + 6, INK))
pin_l(RX0, YM, '1  PKD TX audio')
text(380, YM + 30, 'pad: ~2.5 Vpp -> ~40 mVpp', 10, 'middle', NOTE, italic=True)
pin_l(RX0, 640, '4  PR9  n/c')

# ---------------------------------------------------------------- PTT
YP = 780
pin_r(JX, YP, '35', 'VIA_B_PA4  PTT')
res_h(900, JX, YP, 'R8', '100Ω', above=True)
NG = 840
wire((900, YP), (NG, YP))
dot(NG, YP)
res_v(NG, YP, 840, 'R9', '100k')
gnd(NG, 840)
# 2N7000: gate at x=770, channel x=780
wire((NG, YP), (772, YP))
wire((772, YP - 20), (772, YP + 20))       # gate plate
wire((782, YP - 24), (782, YP + 24))       # channel
wire((782, YP - 18), (800, YP - 18), (800, 740))   # drain up
wire((782, YP + 18), (800, YP + 18), (800, 830))   # source down
add('<polygon points="783,%g 793,%g 793,%g" fill="%s"/>' % (YP + 18, YP + 13, YP + 23, INK))
gnd(800, 830)
text(745, YP + 50, 'Q1 2N7000', 12, 'middle')
YPT = 740
wire((800, YPT), (RX0, YPT))
pin_l(RX0, YPT, '3  PKS PTT')

# grounds and supply pins
YG = 840
pin_l(RX0, YG, '2  GND')
wire((RX0, YG), (300, YG))
gnd(300, YG)
pin_r(JX, 850, '49', 'VSS (GND)')
wire((JX, 850), (960, 850))
gnd(960, 850)
pin_r(JX, 170, '50', 'VDD  +3V3 out')
wire((JX, 170), (960, 170))
vcc(960, 170)

# ---------------------------------------------------------------- squelch
YS = 890
text(330, 874, 'SQUELCH  -  channel busy, 5 V -> 3.3 V divider', 13, color=ACC, weight='bold')
pin_l(RX0, YS, '6  SQC busy')
wire((RX0, YS), (560, YS))
res_h(560, 650, YS, 'R20', '10k', above=False)
wire((650, YS), (700, YS))
dot(700, YS)
res_v(700, YS, 950, 'R21', '20k')
gnd(700, 950)
wire((700, YS), (JX, YS))
pin_r(JX, YS, '33', 'VIA_B_PA5  SQC in')

# ---------------------------------------------------------------- notes
NY = 990
add('<rect x="40" y="%d" width="%d" height="146" rx="8" fill="#fbfbf4" stroke="#bbb"/>' % (NY, W - 80))
notes = [
    'Parts: U1 LM393 (one half used; tie unused inputs +3V3/GND), Q1 2N7000, RV1 10k trimpot, resistors 1/4 W 5% (20k = two 10k in series is fine).',
    'RX: PR1 is fixed-level 1200-baud audio (about 500 mVpp), not affected by the volume knob. C1/R1 put it on VREF; R3 adds ~30 mV hysteresis.',
    'TX: the CPU steps PA0-PA3 through a 16-step sine; R7/C3 (3.4 kHz) smooth it; R18/R19 cut it ~55x since PKD wants ~40 mVpp; RV1 sets deviation (~3 kHz).',
    'PTT: grounding PKS transmits. VIA pins are inputs after reset, so R9 holds Q1 off. Firmware also limits key-down time. SQC tells firmware the channel is busy.',
    'Radio menu: set the DATA band to the band tuned to 144.390 MHz and data speed to 1200. Pin numbers per the TM-V71A manual - check which side the view is from.',
    'A ready-made 6-pin mini-DIN cable avoids soldering the plug (some PS/2 cables have all 6 wires - check with a meter).',
    'All grounds common: radio GND to J4 pin 49. Nothing on J4 may see more than 3.3 V.',
]
for i, n in enumerate(notes):
    text(56, NY + 22 + i * 18, '• ' + n, 12, color='#333')

add('</svg>')
open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(out))
print('wrote', sys.argv[1])
