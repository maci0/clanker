#!/usr/bin/env python3
"""Generate the office view's sprites.png and characters.png.

Original pixel art, authored as maps in this file and rendered
deterministically, in the visual grammar of late-SNES-lifecycle JRPG
interiors (Chrono Trigger, Terranigma, DQ3 remake, Suikoden): dark warm
outlines instead of black, four-tone ramps off one master palette,
directional light from the top-left, dithered texture, translucent cast
shadows baked into the furniture tiles, chunky chibi proportions. No pixels
are taken from any game or asset pack; the output is this repository's own
work and is released with it.

  uv run --with pillow gen_art.py

sprites.png    112x32, a 7x2 grid of 16x16 tiles (see build_tiles order)
characters.png 192x144, nine rows of twelve 16x16 frames:
               eight agent robots + the janitor, 4 walk frames for each of
               down, up, left (right is left mirrored at draw time)
"""

from PIL import Image

T = 16

# ---------------------------------------------------------------- palette --
K = (43, 34, 51)          # outline: dark warm plum, never pure black
SH = (24, 17, 32, 96)     # translucent cast shadow
WOOD0 = (86, 52, 38)
WOOD1 = (133, 84, 52)
WOOD2 = (178, 120, 70)
WOOD3 = (222, 166, 106)
WALL0 = (54, 58, 80)
WALL1 = (88, 96, 126)
WALL2 = (130, 140, 172)
WALL3 = (166, 176, 205)
GRN0 = (40, 102, 52)
GRN1 = (72, 158, 74)
GRN2 = (132, 212, 118)
POT0 = (134, 66, 42)
POT1 = (196, 108, 60)
POT2 = (228, 152, 96)
MET0 = (68, 73, 88)
MET1 = (116, 123, 140)
MET2 = (178, 186, 200)
WATER = (66, 148, 210)
WATER2 = (158, 216, 240)
RED0 = (112, 38, 52)
RED1 = (172, 62, 72)
RED2 = (222, 110, 96)
PAPER = (236, 228, 202)
CRT = (119, 224, 138)
CRTD = (30, 34, 44)
LAMP = (70, 208, 94)
EYE = (255, 236, 160)
VISOR = (28, 32, 42)

BOOK1 = (180, 70, 78)
BOOK2 = (74, 118, 190)
BOOK3 = (76, 158, 84)
BOOK4 = (214, 162, 64)


def blank(w=T, h=T):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def from_map(rows, legend, base=None):
    im = base or blank(len(rows[0]), len(rows))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == ".":
                continue
            c = legend[ch]
            if len(c) == 3:
                c = c + (255,)
            if c[3] == 255:
                im.putpixel((x, y), c)
            else:
                im.alpha_composite(Image.new("RGBA", (1, 1), c), (x, y))
    return im


# ------------------------------------------------------------------ tiles --

def tile_floor(dark=False):
    """Plank floor, two tones so the room can checker per-tile: every other
    course catches the light, grain and knots dithered in."""
    t1 = WOOD1 if not dark else tuple(max(c - 13, 0) for c in WOOD1)
    t2 = WOOD2 if not dark else tuple(max(c - 13, 0) for c in WOOD2)
    im = Image.new("RGBA", (T, T), t1 + (255,))
    px = im.load()
    for y in range(T):
        for x in range(T):
            if y % 8 == 7:
                px[x, y] = WOOD0 + (255,)                     # course seam
            elif (y // 8 == 0 and x == 5) or (y // 8 == 1 and x == 12):
                px[x, y] = WOOD0 + (255,)                     # butt joint
            elif y % 8 == 0:
                px[x, y] = t2 + (255,)                        # lit edge
            elif y % 8 == 1 and x % 2 == 0:
                px[x, y] = t2 + (255,)                        # dither below it
            elif (x * 5 + y * 11) % 23 == 0:
                px[x, y] = t2 + (255,)                        # grain
            elif (x * 3 + y * 7) % 37 == 0:
                px[x, y] = WOOD0 + (255,)                     # knot
    px[3, 3] = WOOD3 + (255,)                                 # nail glints
    px[13, 11] = WOOD3 + (255,)
    return im


def tile_wall():
    """Wallpaper above a wooden wainscot: crown shadow, dotted paper
    texture, chair rail, panelled base."""
    im = Image.new("RGBA", (T, T), WALL1 + (255,))
    px = im.load()
    for x in range(T):
        px[x, 0] = K + (255,)
        px[x, 1] = WALL0 + (255,)                             # crown shadow
        px[x, 2] = WALL3 + (255,)                             # lit crown edge
        for y in range(3, 9):                                 # paper texture
            if (x + y * 3) % 4 == 0:
                px[x, y] = WALL2 + (255,)
            if (x * 3 + y) % 7 == 0:
                px[x, y] = WALL0 + (255,)
        px[x, 9] = WALL3 + (255,)                             # chair rail
        px[x, 10] = WOOD2 + (255,)
        for y in (11, 12, 13):                                # wainscot
            px[x, y] = WOOD1 + (255,)
        if x % 5 == 0:
            for y in (11, 12, 13):
                px[x, y] = WOOD0 + (255,)                     # panel seams
        px[x, 14] = WOOD0 + (255,)                            # base shadow
        px[x, 15] = K + (255,)
    return im


PLANT = [
    "......KK........",
    "....KKGGK.KK....",
    "...KGgGGgKGGK...",
    "..KGgHGGGgGgK...",
    "..KGGHHGgGGgGK..",
    ".KGgGHGGGGHGGK..",
    ".KGGgGGKGgHGgK..",
    "..KgGgKpKGGgK...",
    "...KKgKpKgKK....",
    "....KpXXppK.....",
    "...KpXPPXppK....",
    "...KpXPPXPpK....",
    "...KpPPPPPpK....",
    "....KpPPPpK.....",
    ".....KKKKK......",
    "...SSSSSSSSS....",
]

BIN = [
    "................",
    "................",
    "................",
    "....KKKKKKK.....",
    "...KmMMMMMHK....",
    "...KMKKKKKMK....",
    "....KmMMMHK.....",
    "....KmMMMHK.....",
    "....KmMMHMK.....",
    "....KmMMHMK.....",
    "....KmMHMMK.....",
    "....KmMHMMK.....",
    "....KmmMMmK.....",
    ".....KKKKK......",
    "....SSSSSSS.....",
    "................",
]

SHELF = [
    "KKKKKKKKKKKKKKKK",
    "KDWWWWWWWWWWWWwK",
    "KDK1K2K3K1K4KKwK",
    "KDK1K2K3K1K4KKwK",
    "KDK1K2K3K1K4KKwK",
    "KDWWWWWWWWWWWWwK",
    "KDK3K1K4K2K3KKwK",
    "KDK3K1K4K2K3KKwK",
    "KDK3K1K4K2K3KKwK",
    "KDWWWWWWWWWWWWwK",
    "KDK2K4K1K3K2KKwK",
    "KDK2K4K1K3K2KKwK",
    "KDK2K4K1K3K2KKwK",
    "KDwwwwwwwwwwwwwK",
    "KKKKKKKKKKKKKKKK",
    ".SSSSSSSSSSSSSS.",
]

COOLER = [
    "....KKKKKK......",
    "...KAaaaaWK.....",
    "...KAaWWaWK.....",
    "...KAaaWaWK.....",
    "...KAAaaAWK.....",
    "....KKKKKK......",
    "...KHMMMMHK.....",
    "...KmMWWMmK.....",
    "...KmMMMMmK.....",
    "...KmKCKKmK.....",
    "...KmMMMMmK.....",
    "...KmMMMMmK.....",
    "...KmmMMmmK.....",
    "....KK..KK......",
    "....SSSSSS......",
    "................",
]

SOFA_L = [
    "................",
    "................",
    "..KKK...........",
    ".KrRhK..........",
    ".KrRrK..........",
    ".KrRrKKKKKKKKKKK",
    ".KrRrhhRRhhRRRRh",
    ".KrRrRRRRRRRRRRR",
    ".KrRrRrrRRrrRRRr",
    ".KrRrrrrrrrrrrrr",
    ".KrRhRRRRhRRRRRh",
    ".KrrRRRRRRRRRRRR",
    ".KKrrrrrrrrrrrrr",
    "..KKKKKKKKKKKKKK",
    "..KwwK..........",
    ".SSSSSSSSSSSSSSS",
]

SOFA_R = [
    "................",
    "................",
    "...........KKK..",
    "..........KhRrK.",
    "..........KrRrK.",
    "KKKKKKKKKKKrRrK.",
    "hRRRRhhRRhhrRrK.",
    "RRRRRRRRRRRrRrK.",
    "rRRrrRRrrRRrRrK.",
    "rrrrrrrrrrrrRrK.",
    "hRRRRhRRRRhrRrK.",
    "RRRRRRRRRRRRrrK.",
    "rrrrrrrrrrrrrKK.",
    "KKKKKKKKKKKKKK..",
    "..........KwwK..",
    "SSSSSSSSSSSSSSS.",
]

DESK = [
    "....KKKKKK......",
    "...KMmmmmMK.....",
    "...KmKKKKmK.....",
    "...KmCCcKmK.....",
    "...KmCccKmK.....",
    "...KmKKKKmK.....",
    "...KMmmmMMK.....",
    "KKKKKKmMKKKKKKK.",
    "KDDDDDDDDDDDDDK.",
    "KWWWWWWWWWWWWWK.",
    "KwKKKKKKKKKKKwK.",
    "KwK.........wK..",
    "KwK.........wK..",
    "KwK.........wK..",
    "KKK.........KK..",
    "SSS.........SS..",
]

CHAIR = [
    "................",
    "................",
    "....KKKKK.......",
    "...KwWWWDK......",
    "...KwK.KDK......",
    "...KwK.KDK......",
    "...KwWWWDK......",
    "...KwwwwwK......",
    "...KWWWWDK......",
    "...KWWWWDK......",
    "....KKKKK.......",
    "...KwK..KwK.....",
    "...KwK..KwK.....",
    "...KwK..KwK.....",
    "....K....K......",
    "...SSS..SSS.....",
]

PICTURE = [
    "................",
    "................",
    "..KKKKKKKKKKK...",
    "..KDwwwwwwwDK...",
    "..KwPPPPPPPwK...",
    "..KwPWWPPGPwK...",
    "..KwPWWPGGPwK...",
    "..KwPPPPGGPwK...",
    "..KwGGGGGGPwK...",
    "..KwPPPPPPPwK...",
    "..KDwwwwwwwDK...",
    "..KKKKKKKKKKK...",
    "................",
    "................",
    "................",
    "................",
]

DOOR = [
    "KKKKKKKKKKKKKKKK",
    "KwwwwwwwwwwwwwwK",
    "KwDDDDwDDDDwDDwK",
    "KwD22DwD22DwD2wK",
    "KwDDDDwDDDDwDDwK",
    "KwDDDDwDDDDwDDwK",
    "KwD22DwD22DwD2wK",
    "KwDDDDwDDDDwDDwK",
    "KwDDDDwDDDDwDEwK",
    "KwD22DwD22DwDDwK",
    "KwDDDDwDDDDwDDwK",
    "KwDDDDwDDDDwDDwK",
    "KwD22DwD22DwD2wK",
    "KwDDDDwDDDDwDDwK",
    "KwwwwwwwwwwwwwwK",
    "KKKKKKKKKKKKKKKK",
]

TILE_LEGEND = {
    "K": K, "S": SH,
    "G": GRN1, "g": GRN0, "H": GRN2,
    "p": POT1, "P": POT0, "X": POT2,
    "M": MET1, "m": MET0,
    "A": WATER, "a": WATER2,
    "R": RED1, "r": RED0, "h": RED2,
    "W": WOOD2, "w": WOOD1, "D": WOOD3, "d": WOOD0,
    "C": CRT, "c": CRTD,
    "E": EYE,
    "1": BOOK1, "2": BOOK2, "3": BOOK3, "4": BOOK4,
}

BIN_L = dict(TILE_LEGEND, H=MET2)
COOLER_L = dict(TILE_LEGEND, H=MET2, W=(255, 255, 255), C=LAMP)
PICTURE_L = dict(TILE_LEGEND, P=PAPER, W=WATER2, G=GRN1)
DESK_L = dict(TILE_LEGEND, D=WOOD3, W=WOOD2, w=WOOD1)
DOOR_L = dict(TILE_LEGEND, D=WOOD2, w=WOOD0, E=EYE, **{"2": WOOD1})


def build_tiles():
    order = [
        tile_floor(False),
        tile_wall(),
        from_map(PLANT, TILE_LEGEND),
        from_map(BIN, BIN_L),
        from_map(SHELF, TILE_LEGEND),
        from_map(COOLER, COOLER_L),
        tile_floor(True),
        from_map(SOFA_L, TILE_LEGEND),
        from_map(SOFA_R, TILE_LEGEND),
        from_map(DESK, DESK_L),
        from_map(CHAIR, TILE_LEGEND),
        from_map(PICTURE, PICTURE_L),
        from_map(DOOR, DOOR_L),
    ]
    cols = 7
    rows = (len(order) + cols - 1) // cols
    sheet = blank(cols * T, rows * T)
    for i, im in enumerate(order):
        sheet.paste(im, ((i % cols) * T, (i // cols) * T))
    return sheet


# ------------------------------------------------------------- characters --
# One chibi robot, three facings, lit from the top-left: highlight band on
# the head's upper-left, shadow along the right edge and under the jaw.
# Eight palette ramps and four head variants make eight distinct agents;
# the ninth row is the janitor (grey ramp, work cap).

BODY_DOWN = [
    "................",
    "....KKKKKKKK....",
    "...KHHHHHHBBK...",
    "...KHBBBBBBbK...",
    "...KBeEeeEebK...",
    "...KBeeeeeebK...",
    "...KbBBBBBbbK...",
    "....KKKKKKKK....",
    "...KMHBBBBbMK...",
    "...KMbBABBbMK...",
    "...KMbBBBBbMK...",
    "....KbbbbbbK....",
    "....KKKKKKKK....",
]

BODY_UP = [
    "................",
    "....KKKKKKKK....",
    "...KHHHHHHBBK...",
    "...KHBBBBBBbK...",
    "...KBBKBBKBbK...",
    "...KBBBBBBBbK...",
    "...KbBBBBBbbK...",
    "....KKKKKKKK....",
    "...KMHBBBBbMK...",
    "...KMbBBBBbMK...",
    "...KMbBBBBbMK...",
    "....KbbbbbbK....",
    "....KKKKKKKK....",
]

BODY_LEFT = [
    "................",
    "....KKKKKKKK....",
    "...KHHHHHHBBK...",
    "...KHBBBBBBbK...",
    "...KeEeBBBBbK...",
    "...KeeeBBBBbK...",
    "...KbBBBBBbbK...",
    "....KKKKKKKK....",
    "....KMHBBBbK....",
    "....KMbABBbK....",
    "....KMbBBBbK....",
    "....KbbbbbbK....",
    "....KKKKKKKK....",
]

LEGS_STAND = [
    "....KmMK.KmMK...",
    "....KmmK.KmmK...",
    ".....KK...KK....",
]
LEGS_L = [
    "....KmMK........",
    "....KmmK.KmMK...",
    ".....KK...KK....",
]
LEGS_R = [
    ".........KmMK...",
    "....KmMK.KmmK...",
    ".....KK...KK....",
]
LEGS_LEFT_STAND = [
    ".....KmMKKmMK...",
    ".....KmmKKmmK...",
    "......KK..KK....",
]
LEGS_LEFT_STRIDE = [
    "...KmMK...KmMK..",
    "...KmmK...KmmK..",
    "....KK.....KK...",
]

HEAD_VARIANTS = [
    ["......AK........", ".......K........"],   # single lamp antenna
    ["....A......A....", "....K......K...."],   # two side antennae
    ["................", "................"],   # flat top
    [".......AA.......", ".......KK......."],   # dome light
]

CAP = [
    "................",
    "....KKKKKKKK....",
    "...KCXCCCCCCK...",
    "...KCCCCCCCCKK..",
]

RAMPS = [
    ((214, 64, 64), (140, 40, 54), (245, 138, 105)),    # red
    ((72, 122, 216), (44, 74, 148), (128, 178, 245)),   # blue
    ((70, 176, 88), (40, 118, 60), (136, 220, 136)),    # green
    ((216, 162, 54), (152, 96, 38), (245, 210, 118)),   # amber
    ((156, 92, 212), (100, 54, 156), (204, 152, 245)),  # purple
    ((58, 186, 204), (34, 126, 144), (140, 230, 236)),  # cyan
    ((222, 120, 46), (158, 76, 30), (248, 178, 108)),   # orange
    ((212, 90, 156), (150, 54, 108), (245, 150, 204)),  # pink
]
JANITOR_RAMP = ((116, 123, 140), (68, 73, 88), (178, 186, 200))
CAP_COLOR = (44, 74, 148)
CAP_HI = (100, 132, 196)


def robot_frame(body, legs, ramp, head_variant, cap=False):
    base, shadow, hi = ramp
    legend = {
        "K": K, "B": base, "b": shadow, "H": hi,
        "M": MET1, "m": MET0, "E": EYE, "e": VISOR, "A": LAMP,
        "C": CAP_COLOR, "X": CAP_HI,
    }
    rows = list(body) + list(legs)
    im = from_map(rows, legend)
    if head_variant is not None:
        im = from_map(head_variant, legend, base=im)
    if cap:
        im = from_map(CAP, legend, base=im)
    return im


def build_chars():
    sheet = blank(12 * T, 9 * T)
    down_legs = [LEGS_STAND, LEGS_L, LEGS_STAND, LEGS_R]
    left_legs = [LEGS_LEFT_STAND, LEGS_LEFT_STRIDE, LEGS_LEFT_STAND, LEGS_LEFT_STRIDE]
    for row in range(9):
        janitor = row == 8
        ramp = JANITOR_RAMP if janitor else RAMPS[row]
        variant = None if janitor else HEAD_VARIANTS[row % 4]
        for f in range(4):
            frames = [
                robot_frame(BODY_DOWN, down_legs[f], ramp, variant, cap=janitor),
                robot_frame(BODY_UP, down_legs[f], ramp, variant, cap=janitor),
                robot_frame(BODY_LEFT, left_legs[f], ramp, variant, cap=janitor),
            ]
            for d, im in enumerate(frames):
                sheet.paste(im, ((d * 4 + f) * T, row * T))
    return sheet


if __name__ == "__main__":
    build_tiles().save("sprites.png")
    build_chars().save("characters.png")
    print("wrote sprites.png (112x32) and characters.png (192x144)")
