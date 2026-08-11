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

## sprites.png, lower half: the furniture

The offices were furnished out of an exterior pack, so a "desk" was a market
crate and a "sofa" was a hedge. The lower half of the sheet is a second
Kenney pack that is actually indoors.

- **Source:** Roguelike Indoors (`Tilesheets/roguelikeIndoor_transparent.png`)
- **Author:** Kenney Vleugels (kenney.nl)
- **Licence:** Creative Commons Zero (CC0 1.0)
- **Licence text, quoted from the pack's own `License.txt`:**

  > License (Creative Commons Zero, CC0)
  > http://creativecommons.org/publicdomain/zero/1.0/
  >
  > You may use these assets in personal and commercial projects.
  > Credit (Kenney or www.kenney.nl) would be nice but is not mandatory.

- **Modifications:** the source sheet carries a 1px margin between tiles; it
  is repacked flush to a 16px grid and appended below the RPG Urban sheet, so
  one image still serves the whole view. `IN(c, r)` in app.js addresses the
  lower half by the source pack's own coordinates.
- **Attribution:** not required. Credited here because it is nice.

## characters.png

Nine characters, one 16x16 row each: eight agent avatars and the janitor on
the last row. Twelve columns per row, four walk frames for each of down, up
and left. Right is left mirrored, because on the source sheets the two side
columns are pixel-identical, so storing both would only cost bytes.

- **Source:** Superpowers Ninja Adventure asset pack, `ninja-adventure/characters/`
  (sheets 4, 5, 9, 12, 13, 17, 20, 25 for the agents; 14 for the janitor)
- **Repository:** https://github.com/sparklinlabs/superpowers-asset-packs
- **Author:** Pixel-boy, at Sparklin Labs
- **Licence:** Creative Commons Zero (CC0 1.0), the full text in that
  repository's `LICENSE.txt`
- **Licence statement, quoted from the repository README:**

  > The assets in this repository are created at Sparklin Labs by Pixel-boy.
  > They are released under the Creative Commons Zero (CC0) license.
  >
  > You can use the assets found in this repository in your own games,
  > even commercial ones. Attribution is not required but appreciated.
  > Placing a link to http://superpowers-html5.com/ somewhere would be awesome :)

- **Modifications:** each source sheet is 64x112 (four direction columns by
  seven frame rows). We take the three distinct directions and the first four
  frames of each, transpose them into one row per character, and stack the
  nine chosen characters into a single image so the view still costs one
  request. The pixels themselves are unaltered.
- **Attribution:** not required. The link above is the "would be awesome"
  the author asks for, given willingly.

Two packs rather than one because neither has both halves: this one has
animated people and no office, Kenney's has the office and only static
figures. Both are CC0, so combining them owes nothing to either.

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
