#!/usr/bin/env python3
"""Regenerate the TUI mascot's frame data from the source gif.

Two outputs, one per renderer:

  src/tui/mascot_frames.zig        quantized half-block cells, one set per size
  src/tui/mascot/frame-NN[-f].png  per-frame pngs for the kitty-graphics path

Run from the repo root with the source gif as the only argument:

    python3 src/tui/mascot/gen_frames.py path/to/clanker-zooming.gif

Needs Pillow. The checked-in outputs are what the build uses, so this only has
to be rerun when the artwork itself changes.
"""

import os
import sys

from PIL import Image, ImageEnhance, ImageOps

# Cell grids, smallest first. One terminal row is two stacked pixels, so the
# sample grid for a size is COLS x ROWS*2.
#
# `small` is the floor, not a preference: below roughly 8x4 the robot stops
# being a robot. Swept against the real frames, 6x3 and 5x3 are a featureless
# vertical smear with no eye and no legs, and 3x2 -- which is what a literal
# "a third of 10x5" works out to -- is two grey specks. 7x4 finds the legs but
# the eye survives in only 2 of 11 frames; 8x4 gets it to 4 of 11 and keeps the
# silhouette, so that is where the floor sits.
SIZES = {
    "small": (8, 4),
    "medium": (10, 5),
    "large": (21, 10),
}
DEFAULT_SIZE = "medium"

PNG_SIZE = (192, 192)

# Which mirrored copies to emit for the kitty path. Half-blocks are flipped at
# render time for free, but a kitty placement cannot mirror an image, so each
# orientation needs its own transmitted png.
FLIPS = {
    "": None,
    "-h": Image.FLIP_LEFT_RIGHT,
    "-v": Image.FLIP_TOP_BOTTOM,
}

# Set per size by `main`; `to_cells` reads them.
COLS = SIZES[DEFAULT_SIZE][0]
ROWS = SIZES[DEFAULT_SIZE][1]

# The artwork's own colours, sampled from the gif: dark outline, three body
# greys, the cyan eye, the tan chest patch, and the dust puffs. Quantizing to
# these rather than letting the resampler average is what keeps the thin limbs
# readable at 21x10 -- a plain LANCZOS downsample turns the whole robot into
# uniform grey mush.
PALETTE = [
    (0x2C, 0x30, 0x38),  # 0 outline
    (0x5C, 0x67, 0x76),  # 1 body shadow
    (0x8A, 0x98, 0xAA),  # 2 body mid
    (0xBA, 0xC6, 0xD4),  # 3 body highlight
    (0x4F, 0xD8, 0xE8),  # 4 eye
    (0xC9, 0xA8, 0x78),  # 5 chest patch
    (0xCF, 0xC4, 0xB0),  # 6 dust
]
TRANSPARENT = 0xF
# Below this alpha a sample is background rather than robot. Tuned by eye:
# lower and the antialiased outline smears into a halo, higher and the
# antenna and fingers drop out entirely.
ALPHA_CUTOFF = 0.45

# How much each colour is allowed to punch above its pixel count when a cell is
# decided (see `to_cells`). At 10x5 one cell covers a big patch of source, so a
# straight area-average or a plain majority vote loses every small feature --
# the cyan eye, which is most of what makes the thing read as a robot rather
# than a grey blob, disappeared entirely at this size. These weights let a
# colour that is *present but outnumbered* still claim its cell.
#
# Only the small, semantically load-bearing features are boosted; the three
# body greys deliberately compete on raw area, or the silhouette distorts.
VOTE_WEIGHT = [
    1.0,  # 0 outline
    1.0,  # 1 body shadow
    1.0,  # 2 body mid
    1.0,  # 3 body highlight
    2.5,  # 4 eye        -- tiny, and the whole face
    2.5,  # 5 chest patch -- small, and the only warm colour on the body
    1.2,  # 6 dust        -- wispy, reads as motion
]
# The eye weight was swept rather than guessed, and it is sharp on both sides:
# at 2.0 the eye vanishes in 4 of 11 frames, at 3.0 it spills to two cells and
# reads as a visor poking out past the head. 2.5 gives exactly one cyan cell,
# inside the head, in 9 of 11 frames -- the two it misses land as a blink.


def load_frames(path):
    im = Image.open(path)
    out = []
    for i in range(getattr(im, "n_frames", 1)):
        im.seek(i)
        out.append(im.convert("RGBA"))
    return out


def union_crop(frames):
    """Crop every frame to one shared bbox so the robot doesn't jitter."""
    box = None
    for f in frames:
        b = f.getchannel("A").getbbox()
        if b is None:
            continue
        box = b if box is None else (
            min(box[0], b[0]), min(box[1], b[1]),
            max(box[2], b[2]), max(box[3], b[3]),
        )
    if box is None:
        raise SystemExit("every frame is fully transparent")
    return [f.crop(box) for f in frames]


def nearest(rgb):
    return min(
        range(len(PALETTE)),
        key=lambda i: sum((PALETTE[i][c] - rgb[c]) ** 2 for c in range(3)),
    )


def to_cells(img):
    """One byte per cell: quantize at full resolution, then vote per half-cell.

    Deliberately *not* a resize-then-quantize. Downsampling first averages each
    half-cell's source pixels into one colour, and an average of "mostly grey
    face with a small cyan eye" is grey -- at 10x5 that erased the eye, the
    chest patch and most of the dust in one step. Quantizing first and then
    letting the source pixels vote keeps a small feature able to win its cell,
    which `VOTE_WEIGHT` then tunes.
    """
    img = ImageEnhance.Contrast(img).enhance(1.35)
    img = ImageEnhance.Color(img).enhance(1.5)
    w, h = img.size
    px = img.load()

    # Full-resolution palette indices, computed once per frame. `nearest` is a
    # linear scan over seven colours and this is ~80k pixels, so memoize on the
    # exact rgb: the source is already flat cel-shaded art and repeats heavily.
    cache = {}

    def index_at(x, y):
        p = px[x, y]
        if p[3] / 255.0 < ALPHA_CUTOFF:
            return TRANSPARENT
        key = p[:3]
        got = cache.get(key)
        if got is None:
            got = nearest(key)
            cache[key] = got
        return got

    def sample(cx, cy):
        """Weighted vote over the source rectangle behind one half-cell."""
        x0, x1 = w * cx // COLS, w * (cx + 1) // COLS
        y0, y1 = h * cy // (ROWS * 2), h * (cy + 1) // (ROWS * 2)
        tally = [0.0] * len(PALETTE)
        clear = 0
        total = 0
        for y in range(y0, max(y1, y0 + 1)):
            for x in range(x0, max(x1, x0 + 1)):
                total += 1
                i = index_at(x, y)
                if i == TRANSPARENT:
                    clear += 1
                else:
                    tally[i] += VOTE_WEIGHT[i]
        # Mostly empty stays empty, so the robot keeps a silhouette instead of
        # growing a one-cell halo of whatever colour was nearest the edge.
        if total == 0 or clear * 2 > total:
            return TRANSPARENT
        best = max(range(len(PALETTE)), key=lambda i: tally[i])
        return TRANSPARENT if tally[best] == 0 else best

    out = bytearray()
    for r in range(ROWS):
        for c in range(COLS):
            out.append((sample(c, r * 2) << 4) | sample(c, r * 2 + 1))
    return bytes(out)


def write_zig(path, per_size, frame_count):
    lines = [
        "//! Generated by src/tui/mascot/gen_frames.py -- do not edit by hand.",
        "//!",
        "//! The mascot as terminal cells, for terminals without kitty graphics.",
        "//! One byte per cell, high nibble the upper half-block's colour and low",
        "//! nibble the lower half's, both indices into `palette`; 0xF is",
        "//! transparent (leave whatever is underneath alone).",
        "//!",
        "//! Mirrored copies are not baked: a half-block cell grid flips at render",
        "//! time for the cost of an index reversal (see `mascot.zig`). Only the",
        "//! kitty pngs need real mirrored files, because a placement cannot",
        "//! mirror what it draws.",
        "",
        f"pub const frame_count: usize = {frame_count};",
        "",
        "/// Sampled from the source artwork. Indices, not a ramp: nothing here",
        "/// assumes an ordering.",
        "pub const palette = [_]u24{",
    ]
    for (r, g, b), name in zip(PALETTE, [
        "outline", "body shadow", "body mid", "body highlight",
        "eye", "chest patch", "dust",
    ]):
        lines.append(f"    0x{r:02X}{g:02X}{b:02X}, // {name}")
    lines += [
        "};",
        "",
        "pub const transparent: u8 = 0xF;",
        "",
        "/// One baked cell grid. `cells` is `frame_count` frames of",
        "/// `rows * cols` bytes, laid out row-major and concatenated, so a",
        "/// frame is `cells[i * rows * cols ..][0 .. rows * cols]`.",
        "pub const Variant = struct {",
        "    cols: u16,",
        "    rows: u16,",
        "    cells: []const u8,",
        "};",
        "",
    ]
    for name, (cols, rows, frames_cells) in per_size.items():
        lines.append(f"pub const {name}: Variant = .{{")
        lines.append(f"    .cols = {cols},")
        lines.append(f"    .rows = {rows},")
        lines.append("    .cells = &.{")
        for fi, cells in enumerate(frames_cells):
            lines.append(f"        // frame {fi}")
            for r in range(rows):
                row = cells[r * cols:(r + 1) * cols]
                body = " ".join(f"0x{b:02X}," for b in row)
                lines.append(f"        {body}")
        lines.append("    },")
        lines.append("};")
        lines.append("")
    with open(path, "w") as fh:
        fh.write("\n".join(lines))


def main():
    global COLS, ROWS
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    src = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    frames = union_crop(load_frames(src))

    per_size = {}
    for name, (cols, rows) in SIZES.items():
        COLS, ROWS = cols, rows
        per_size[name] = (cols, rows, [to_cells(f) for f in frames])
    write_zig(
        os.path.join(os.path.dirname(here), "mascot_frames.zig"),
        per_size,
        len(frames),
    )

    pngs = 0
    for i, f in enumerate(frames):
        # Padded to a square so the kitty path and the half-block path frame
        # the robot identically; the cell grids are all very nearly square too.
        # Bottom-aligned, so the robot's feet sit on the same line in every
        # frame rather than the whole body bobbing with the union crop.
        w, h = f.size
        side = max(w, h)
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.alpha_composite(f, ((side - w) // 2, side - h))
        sq = sq.resize(PNG_SIZE, Image.LANCZOS)
        for suffix, how in FLIPS.items():
            out = sq if how is None else sq.transpose(how)
            out.save(os.path.join(here, f"frame-{i:02d}{suffix}.png"), optimize=True)
            pngs += 1

    sizes = ", ".join(f"{n} {c}x{r}" for n, (c, r) in SIZES.items())
    print(f"{len(frames)} frames -> mascot_frames.zig ({sizes}) + {pngs} pngs")


if __name__ == "__main__":
    main()
