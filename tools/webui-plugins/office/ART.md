# Art provenance

Every image in this directory, where it came from, and what its licence
permits. CC0 requires no attribution, so this file is not a credit notice: it
is how a future reader knows what may be redistributed and on what terms,
without having to re-derive it.

## sprites.png

- **Source:** RPG Urban Pack 1.0, `Tilemap/tilemap_packed.png`
- **From:** https://kenney.nl/assets/rpg-urban-pack
- **Author:** Kenney (www.kenney.nl)
- **Created:** 2019-01-05
- **Licence:** Creative Commons Zero (CC0 1.0 Universal)
  <http://creativecommons.org/publicdomain/zero/1.0/>
- **Licence text, quoted from the pack's own `License.txt`:**

  > License: (Creative Commons Zero, CC0)
  > http://creativecommons.org/publicdomain/zero/1.0/
  >
  > This content is free to use in personal, educational and commercial
  > projects.
  >
  > Support us by crediting Kenney or www.kenney.nl (this is not mandatory)

- **Modifications:** none. Copied verbatim from the pack.
- **Layout:** 432x288, a 27x18 grid of 16x16 tiles.

## characters.png

Built from two sheets in one pack, stacked into a single image so the view
costs one request rather than two. Row 0 is Gabe, row 1 is Mani; each row is
seven 24x24 frames, frame 0 idle and frames 1-6 a run cycle.

- **Source:** Generic RPG pack v0.4 (alpha), `rpg-pack/chars/gabe/gabe-idle-run.png`
  and `rpg-pack/chars/mani/mani-idle-run.png`
- **Author:** Estudio Vaca Roxa (Bakudas and Gabe Fern)
- **Licence:** Creative Commons Zero (CC0 1.0 Universal)
- **Licence text, quoted from the pack's own `release.txt`:**

  > Licence:
  > CC0 1.0 Universal (CC0 1.0)
  > Public Domain Dedication
  >
  > You can copy, modify, distribute and perform the work, even for commercial
  > purposes, all without asking permission.

- **Modifications:** the two sheets were stacked vertically into one image. The
  frames themselves are unaltered.

Two packs rather than one because neither has both halves: this one has
animated characters and no office interior, Kenney's has the interior and only
static figures. Both are CC0, so combining them owes nothing to either.

## Rejected, and why

Checked and not used, so nobody re-treads it:

- **Pixel Office 32x32** (masalimov-ilnur): the closest fit by subject, but paid
  and its licence says "You cannot resell, redistribute, re-upload or include
  the original asset files in another asset pack" - vendoring it here is
  exactly that.
- **Mystic Woods** (free version): "You can only use these assets in
  non-commercial projects... You can not redistribute or resale, even if
  modified."
- **16x16 RPG characters**: CC BY-SA 3.0. Usable, but share-alike puts a
  copyleft obligation on the art where CC0 puts none.
- **Kenney Roguelike Modern City**: CC0, but city exteriors - no characters and
  no office furniture.

## What was deliberately not used

The project this view borrows its framing from (`maci0/pixel-agents`) draws its
furniture from the Office Interior Tileset by Donarg, which is a paid itch.io
asset, and its characters from JIK-A-4's Metro City pack, which requires
attribution. Neither may be copied into this repository, so neither was. This
pack was chosen instead because CC0 costs the page no attribution it would have
to display and no licence it would have to honour downstream.
