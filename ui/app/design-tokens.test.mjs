import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// The Control Cabinet's edges and its type scale are tokens, not literals.
// app.css declares five radii (2/3/4px plus the pill) and six type steps, and
// the header comment says why: machined plate edges, "not SaaS cards", with
// every legend plate on one scale. A stray `border-radius: 12px` or
// `font-size: 14px` does not read as a bug, so nothing catches it — the sheet
// just drifts back toward the rounded-card default one declaration at a time.
// That is exactly how the board grew a 12px/8px Trello island and the chat
// composer a 24px pill while the tokens said 4px. These tests pin the
// contract: a size that is not on the scale must be a deliberate, named
// exception here rather than a literal nobody chose.

const here = dirname(fileURLToPath(import.meta.url));
const pluginsDir = join(here, "..", "plugins");

function sheets() {
  const out = [
    ["app/app.css", readFileSync(join(here, "app.css"), "utf8")],
    ["app/views.css", readFileSync(join(here, "views.css"), "utf8")],
  ];
  for (const name of readdirSync(pluginsDir, { withFileTypes: true })) {
    if (!name.isDirectory()) continue;
    const path = join(pluginsDir, name.name, "app.css");
    try {
      out.push([`plugins/${name.name}/app.css`, readFileSync(path, "utf8")]);
    } catch {
      // Not every plugin ships a stylesheet.
    }
  }
  return out;
}

// The script half of the same sweep. `sheets()` reaches every stylesheet, so
// a rule that drifts is caught -- but a declaration written into JS as an
// inline style is not in any sheet, and that is exactly where the prompts
// catalogue kept a `font-size:13px` and a `gap:0.5rem` (a step and a rung of
// the scales, spelled as literals) until this walk found them. Every module
// the page ships, not just the two entry points the emoji test started with.
function scripts() {
  const out = [];
  const walk = (dir, prefix) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(path, `${prefix}${entry.name}/`);
        continue;
      }
      if (!entry.name.endsWith(".js")) continue;
      out.push([`${prefix}${entry.name}`, readFileSync(path, "utf8")]);
    }
  };
  walk(here, "app/");
  walk(pluginsDir, "plugins/");
  return out;
}

// Declarations only: `--radius-pill: 999px` in :root is the definition, and
// the custom-property name is what tells the two apart.
function declarations(css, prop) {
  const re = new RegExp(`(^|[;{\\s])${prop}\\s*:\\s*([^;}]+)`, "g");
  const found = [];
  for (const m of css.matchAll(re)) {
    found.push({ value: m[2].trim(), line: css.slice(0, m.index).split("\n").length });
  }
  return found;
}

// Relative luminance and WCAG contrast, shared by the card-ink test and the
// chat-hue test below rather than living in whichever one was written first.
function luminance(h) {
  const parts = [1, 3, 5]
    .map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2];
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// Hue angle in degrees, and the shortest way round the wheel between two of
// them. The chat hues are the card enamels shaded lighter or darker, and
// shading moves lightness, not hue -- so hue angle is what survives the
// derivation and is therefore what pins the two palettes to one vocabulary.
function hueAngle(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  if (max === min) return null; // A neutral has no hue to match against.
  const d = max - min;
  const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return ((h * 60) % 360 + 360) % 360;
}

function hueGap(a, b) {
  const d = Math.abs(a - b) % 360;
  return d > 180 ? 360 - d : d;
}

// A box-shadow is a comma-separated list of layers, and the commas inside
// rgba()/color-mix() are not separators. Both shadow tests walk layers, so the
// split lives here rather than in whichever one was written first.
function splitLayers(value) {
  const out = [];
  let depth = 0, buf = "";
  for (const ch of value) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) { out.push(buf); buf = ""; continue; }
    buf += ch;
  }
  return out.concat(buf).map((s) => s.trim()).filter(Boolean);
}

test("every border-radius is a token, a full circle, or none", () => {
  // 50% is a circle (lamp domes, avatars) and 0 squares a corner off; neither
  // is a size on the scale, so neither has a token to name it.
  const allowed = /^(0|50%|var\(--radius(-sm|-lg|-pill)?\))$/;
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const { value, line } of declarations(css, "border-radius")) {
      if (value.split(/\s+/).every((part) => allowed.test(part))) continue;
      strays.push(`${name}:${line}  border-radius: ${value}`);
    }
  }
  assert.deepEqual(strays, [], `off-token radii (use --radius-sm/--radius/--radius-lg/--radius-pill):\n${strays.join("\n")}`);
});

test("every font-size is a type step, inherited, or the 16px touch-field guard", () => {
  // 16px is the one literal with a reason that is not typographic: iOS zooms
  // the page when a focused field is under 16px, so touch fields and the icon
  // glyphs sized to match them opt out of the scale. See AGENTS.md.
  // `em` is allowed because it is a different mechanism, not a stray: inline
  // code and the "(required)" marker size themselves against whatever text
  // they sit in, which no absolute step can express.
  const allowed = /^(inherit|0|[0-9.]+em|16px|var\(--step-(-1|-2|0|1|2|3)\))$/;
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const { value, line } of declarations(css, "font-size")) {
      if (allowed.test(value)) continue;
      strays.push(`${name}:${line}  font-size: ${value}`);
    }
  }
  assert.deepEqual(strays, [], `off-scale font sizes (use --step--2 … --step-3):\n${strays.join("\n")}`);
});

test("the scale the sheets reference is the scale app.css declares", () => {
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  for (const token of ["--step--2", "--step--1", "--step-0", "--step-1", "--step-2", "--step-3"]) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
  for (const token of ["--radius-sm", "--radius", "--radius-lg", "--radius-pill"]) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
});

// The card cover/label palette is the third axis that drifts, and it drifted
// furthest: one hue was spelled out as a raw hex in four separate rule blocks
// (cover, label, swatch, detail header), which is how cover green (#0a7a2e)
// and label green (#22a24a) ended up being different greens for the same
// card. The values were a web palette borrowed wholesale; the panel greys
// they sit next to come from RAL. These tests pin both halves: the hue is a
// token, and the ink paired with it is legible.

// Spacing is the axis with the most drift, because unlike a radius a stray
// `gap: 0.4rem` is not merely off-scale — it is a rung of the scale, spelled
// as a number. 154 of them had been retyped that way across the two sheets,
// so the rhythm was a coincidence rather than a system and a change to
// --space-2 would have reached a third of the places that meant it.
//
// Only the exact matches are pinned. An optical value that lands between
// rungs (a 1px hairline, a -0.4rem nudge, a 1.15rem lamp offset) is a real
// decision and stays a literal; what cannot stay is a token's own value
// written out longhand.
const SPACE_STEPS = {
  "0.25rem": "--space-1", "0.4rem": "--space-2", "0.6rem": "--space-3",
  "0.9rem": "--space-4", "1.4rem": "--space-5", "2.2rem": "--space-6", "3.4rem": "--space-7",
};

test("spacing that lands on a rung of the scale is written as the token", () => {
  const props = "gap|row-gap|column-gap|padding|margin";
  const re = new RegExp(`(^|[;{\\s])(?:${props})(?:-(?:top|right|bottom|left|block|inline))?\\s*:\\s*([^;}]+)`, "g");
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const m of css.matchAll(re)) {
      for (const part of m[2].split(/[\s(,]+/)) {
        const token = SPACE_STEPS[part];
        // A negative offset has no token; it is a nudge off the rhythm.
        if (!token || /-$/.test(m[2].slice(0, m[2].indexOf(part)))) continue;
        strays.push(`${name}:${css.slice(0, m.index).split("\n").length}  ${part} is var(${token})`);
      }
    }
  }
  assert.deepEqual(strays, [], `spacing on the scale must name its token:\n${strays.join("\n")}`);
});

test("the space scale the sheets reference is the scale app.css declares", () => {
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  for (const token of Object.values(SPACE_STEPS)) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
});

// The lamp is the one boldness the sheet's header says it spends, and it was
// the axis with no token at all: the dome was retyped by hand at five call
// sites and had already drifted to two highlight opacities (0.8 vs 0.85),
// three glow radii (none/6px/7px), and a health-plugin variant that mixed
// against --paper with no glow. A sixth lamp — the arena's — gave up and
// became a flat dot in an amber (#e5b54a) that belonged to no palette. A
// signature that every new instance retypes is not a signature.

test("the lamp dome is a token, never retyped", () => {
  const strays = [];
  for (const [name, css] of sheets()) {
    // Blank out the token's own declaration; every dome left is a retype.
    const rest = css.replace(/--lamp-dome\s*:[^;]*;/g, "");
    for (const m of rest.matchAll(/radial-gradient\(\s*circle at 35% 30%/g)) {
      strays.push(`${name}:${rest.slice(0, m.index).split("\n").length}  hand-typed lamp dome (use var(--lamp-dome))`);
    }
  }
  assert.deepEqual(strays, [], `the lamp dome is --lamp-dome:\n${strays.join("\n")}`);
});

test("the lamp tokens the sheets reference are declared", () => {
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  for (const token of ["--lamp-dome", "--lamp-ring", "--lamp-glow"]) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
});

// Elevation was the fifth axis, and the one that drifted furthest out of the
// theme's reach. Three rungs exist but only two had names, so a plate seated
// on the backplane was retyped as a literal at fifteen sites in five recipes
// (0 1px 2px/3px/4px between 0.04 and 0.12 alpha) -- including the composer,
// which had grown the full SaaS-card pair of a hairline plus a soft 24px
// bloom that raised on focus. A literal shadow is invisible to a theme:
// :root, the system-dark block and all ten themes/*.json redefine --lift and
// --lift-high, so those fifteen kept casting a light-theme black smudge on
// graphite and under hackerman's green-on-black.

test("elevation is a --lift rung, never a retyped shadow", () => {
  // Elevation is the layer with an offset: a plate casts its shadow to one
  // side. A layer with no offset is a different idiom entirely -- a focus
  // ring, an avatar's surface halo, a lamp's glow -- and has its own tokens.
  // Insets are the recessed well and the pressed actuator, also not height.
  const hasOffset = (layer) => {
    const lengths = layer.match(/(^|\s)-?[0-9.]+(px|rem|em)?(?=\s|$)/g) || [];
    return lengths.slice(0, 2).some((n) => parseFloat(n) !== 0);
  };
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const { value, line } of declarations(css, "box-shadow")) {
      if (value === "none") continue;
      for (const layer of splitLayers(value)) {
        if (layer.startsWith("inset") || layer.includes("var(--lift") || !hasOffset(layer)) continue;
        // The mobile drawer casts sideways; no vertical rung says that, so it
        // names the theme's --scrim, which is what it lays over anyway.
        if (layer.includes("var(--scrim)")) continue;
        strays.push(`${name}:${line}  box-shadow layer \`${layer}\``);
      }
    }
  }
  assert.deepEqual(strays, [], `elevation must name a rung (--lift-low/--lift/--lift-high):\n${strays.join("\n")}`);
});

test("a bevel is a --bevel token, never a retyped inset", () => {
  // The inset idioms are the other half of the same contract as --lift: a
  // raised plate's machined edge, the well milled into it, and an actuator
  // held down. They were seven literals in six alphas, and because a literal
  // is invisible to themes/*.json the pressed actuator simply vanished on
  // hackerman, whose shadows are green. A ring (`inset 0 0 0 2px var(--accent)`)
  // and a selection marker (`inset 3px 0 0 var(--accent)`) are different
  // idioms that already name their colour, so the rule is about the literal:
  // an inset that hardcodes a colour is an inset no theme can repaint.
  const colourLiteral = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\s*\(/;
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const { value, line } of declarations(css, "box-shadow")) {
      if (value === "none") continue;
      for (const layer of splitLayers(value)) {
        if (!layer.startsWith("inset")) continue;
        if (!colourLiteral.test(layer)) continue;
        strays.push(`${name}:${line}  inset layer \`${layer}\``);
      }
    }
  }
  assert.deepEqual(
    strays,
    [],
    `bevels must name a token (--bevel-raised/--bevel-inset/--bevel-pressed):\n${strays.join("\n")}`,
  );
});

test("every theme declares all three elevation rungs", () => {
  // A rung declared only in app.css is a rung the ten themes cannot retune,
  // which is how a light-theme smudge survives on graphite. The bevels are on
  // this list for the same reason and by the same rule.
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  const rungs = [
    "--lift-low", "--lift", "--lift-high",
    "--bevel-raised", "--bevel-inset", "--bevel-pressed",
  ];
  for (const token of rungs) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
  const themesDir = join(here, "..", "..", "themes");
  for (const file of readdirSync(themesDir).filter((f) => f.endsWith(".json"))) {
    const { tokens } = JSON.parse(readFileSync(join(themesDir, file), "utf8"));
    for (const token of rungs) {
      assert.ok(tokens[token], `themes/${file} redefines elevation but is missing ${token}`);
    }
  }
});

// The icon grid is the sixth axis, and typed pictographs are how it drifts.
// ICON_PATHS exists because a star glyph and a multiplication sign could not
// share a stroke; its header says so. The music dock still typed its whole
// transport -- bars from U+23xx, a triangle from U+25B6, speakers from
// U+1F50A -- and the last of those are emoji, which a browser paints in its
// own colours whatever the theme says. Emoji are content here (a reaction, a
// room avatar, a :shortcode:), never chrome.

test("colour emoji are chat content, never drawn chrome", () => {
  // Emoji-presentation blocks only. U+2713/U+25B6-style symbols render as
  // monochrome text and are not what this is about.
  const emoji = /[\u{1F300}-\u{1FAFF}]|️/u;
  // The three tables that own emoji as data: the :shortcode: map, the
  // reaction sets, and the room-avatar ring.
  const owners = new Set(["app/app.js", "app/core/chat.js"]);
  const strays = [];
  // Every shipped module, not only the two entry points: features/ and lib/
  // draw chrome too, and nothing was watching them.
  for (const [name, src] of scripts()) {
    if (owners.has(name)) continue;
    src.split("\n").forEach((line, i) => {
      if (emoji.test(line)) strays.push(`${name}:${i + 1}  ${line.trim().slice(0, 72)}`);
    });
  }
  assert.deepEqual(strays, [], `chrome is drawn from ICON_PATHS, not typed:\n${strays.join("\n")}`);
});

test("the icons the music dock names are drawn in the one grid", () => {
  const icons = readFileSync(join(here, "core", "icons.js"), "utf8");
  const dock = readFileSync(join(pluginsDir, "music", "app.js"), "utf8");
  assert.match(dock, /api\.icon\(name, 16\)/, "the dock must draw its glyphs, not type them");
  for (const name of ["play", "pause", "prev", "next", "volume", "mute", "note"]) {
    assert.match(icons, new RegExp(`\\n\\s*${name}: \\[`), `ICON_PATHS.${name} is named by the dock but never drawn`);
  }
});

const CARD_HUES = ["green", "yellow", "orange", "red", "purple", "blue", "sky", "pink", "lime", "black"];

test("card colours are --card-* tokens, never literals", () => {
  const strays = [];
  for (const [name, css] of sheets()) {
    // Any rule keyed on a card colour must reach for the token.
    for (const m of css.matchAll(/\[data-color="([a-z]+)"\][^{]*\{([^}]*)\}/g)) {
      const [, hue, body] = m;
      if (!CARD_HUES.includes(hue)) continue;
      const hex = body.match(/#[0-9a-fA-F]{3,8}\b/);
      if (!hex) continue;
      const line = css.slice(0, m.index).split("\n").length;
      strays.push(`${name}:${line}  [data-color="${hue}"] uses ${hex[0]} (use var(--card-${hue}))`);
    }
  }
  assert.deepEqual(strays, [], `card colours must be tokens:\n${strays.join("\n")}`);
});

test("every card hue is declared once and carries legible ink", () => {
  const appCss = readFileSync(join(here, "app.css"), "utf8");

  const hex = (token) => {
    const m = appCss.match(new RegExp(`\\n\\s*${token}\\s*:\\s*(#[0-9a-fA-F]{6})\\s*;`));
    assert.ok(m, `${token} is not declared as a plain hex in :root`);
    return m[1];
  };
  const inks = { "var(--card-ink-on-dark)": hex("--card-ink-on-dark"), "var(--card-ink-on-light)": hex("--card-ink-on-light") };
  for (const hue of CARD_HUES) {
    const bg = hex(`--card-${hue}`);
    const inkRef = appCss.match(new RegExp(`\\n\\s*--card-${hue}-ink\\s*:\\s*([^;]+);`));
    assert.ok(inkRef, `--card-${hue}-ink is not declared`);
    const fg = inks[inkRef[1].trim()];
    assert.ok(fg, `--card-${hue}-ink must point at one of the two ink tokens, got ${inkRef[1].trim()}`);
    // These carry small bold label text, so hold a margin over the 4.5 AA line
    // rather than sitting on it; the palette this replaced cleared 5.48 worst.
    const ratio = contrast(bg, fg);
    assert.ok(ratio >= 5.5, `--card-${hue} (${bg}) on its ink (${fg}) is only ${ratio.toFixed(2)}:1, want >= 5.5`);
  }
});

test("card hues stay theme-constant", () => {
  // A card's colour must mean the same thing in either theme, so unlike the
  // chat hues these are declared once and never redefined in a dark block.
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  for (const hue of CARD_HUES) {
    const count = [...appCss.matchAll(new RegExp(`\\n\\s*--card-${hue}\\s*:`, "g"))].length;
    assert.equal(count, 1, `--card-${hue} is declared ${count} times; it must be theme-constant`);
  }
});

// The eighth axis, and the one that had drifted furthest from the sheet's own
// stated vocabulary. The card covers twenty lines above are RAL Classic
// enamels, each with its provenance written down and its ink picked by
// measured contrast. The per-sender chat hues sitting right beside them were a
// framework's default ramp used raw -- violet-600, purple-600, emerald-700,
// lime-800 -- on a page whose header says blue is the interactive colour
// because IEC 60073 says so, and which had already re-pointed --violet at
// --accent to keep violet out of the chrome. Two of the eight senders were
// violet anyway.
//
// It was worse across themes: all ten themes/*.json shipped byte-identical
// copies of exactly two hue sets, so hackerman's green-on-black CRT, latte's
// pastels and the cabinet's own graphite all drew senders in the same borrowed
// ramp. A ten-theme system with two palettes for this axis is not ten themes.
//
// These pin both halves of the repair: every chat hue is one of the card
// enamels shaded for its theme family (shading moves lightness, so the hue
// angle survives and is what proves the shared vocabulary), and every one
// stays legible on the surface it draws on.
const CHAT_HUES = [0, 1, 2, 3, 4, 5, 6, 7];

function themeTokens() {
  const dir = join(here, "..", "..", "themes");
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => [f, JSON.parse(readFileSync(join(dir, f), "utf8")).tokens]);
}

// The enamel vocabulary: the chromatic card covers. Signal black is excluded
// because a neutral has no hue angle, so matching against it would let any
// desaturated colour through.
function enamelAngles() {
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  const angles = [];
  for (const m of appCss.matchAll(/\n\s*--card-([a-z]+)\s*:\s*(#[0-9a-fA-F]{6})\s*;/g)) {
    const angle = hueAngle(m[2]);
    if (angle !== null) angles.push({ name: m[1], angle });
  }
  assert.ok(angles.length >= 8, "the card enamels are the vocabulary; none were found");
  return angles;
}

test("every chat hue is a card enamel, shaded", () => {
  const enamels = enamelAngles();
  const strays = [];
  const check = (where, hex) => {
    const angle = hueAngle(hex);
    if (angle === null) {
      strays.push(`${where}  ${hex} is neutral; sender hues come from the enamels`);
      return;
    }
    const near = enamels
      .map((e) => ({ ...e, gap: hueGap(angle, e.angle) }))
      .sort((a, b) => a.gap - b.gap)[0];
    // Shading preserves hue exactly; 3 degrees is rounding to 8-bit channels.
    if (near.gap > 3) strays.push(`${where}  ${hex} (hue ${angle.toFixed(0)}) matches no enamel; nearest is --card-${near.name} at ${near.gap.toFixed(0)} degrees off`);
  };
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  for (const { value, line } of declarations(appCss, "--chat-hue-\\d")) {
    check(`app/app.css:${line}`, value);
  }
  for (const [file, tokens] of themeTokens()) {
    for (const i of CHAT_HUES) {
      const hex = tokens[`--chat-hue-${i}`];
      if (hex) check(`themes/${file} --chat-hue-${i}`, hex);
    }
  }
  assert.deepEqual(strays, [], `sender hues are the card enamels shaded, not a second palette:\n${strays.join("\n")}`);
});

test("every theme declares all eight chat hues, legible on its own surface", () => {
  // A sender hue is drawn twice: as the name's text on the panel face, and as
  // an avatar fill carrying --on-accent as ink (see .avatar-tone-* in app.css).
  // Both readings have to hold, which is why both are measured here. 4.5 is
  // the floor rather than the cards' 5.5 because a sender name is not a badge
  // on a fill and the palette must still spread across eight tellable hues;
  // the borrowed ramp this replaced bottomed out at 4.2.
  const resolve = (tokens, key, seen = 0) => {
    const v = tokens[key];
    if (!v || !v.startsWith("var(") || seen > 4) return v;
    return resolve(tokens, v.slice(4, -1), seen + 1);
  };
  for (const [file, tokens] of themeTokens()) {
    const surface = resolve(tokens, "--surface") || resolve(tokens, "--paper");
    const ink = resolve(tokens, "--on-accent");
    assert.ok(surface && ink, `themes/${file} must declare --surface/--paper and --on-accent`);
    for (const i of CHAT_HUES) {
      const hex = tokens[`--chat-hue-${i}`];
      assert.ok(hex, `themes/${file} is missing --chat-hue-${i}`);
      for (const [what, against] of [["its surface", surface], ["its avatar ink", ink]]) {
        const ratio = contrast(hex, against);
        assert.ok(ratio >= 4.5, `themes/${file} --chat-hue-${i} (${hex}) on ${what} (${against}) is only ${ratio.toFixed(2)}:1, want >= 4.5`);
      }
    }
  }
});

// The seventh axis, and the one the sheet tests structurally cannot see: a
// declaration written into JS. `el.style.cssText = "font-size:13px"` is the
// same drift as a stray rule -- a step of the type scale respelled as a
// literal -- but it lives in a script, so `sheets()` never reads it and the
// radius/type/space tests above all pass while the page renders off-token.
// The prompts catalogue drifted exactly this way. An inline style is allowed
// to position and lay out; it is not allowed to restate a scale.
test("inline styles in scripts carry no off-token size", () => {
  // Only the three axes that have a token scale. `flex`, `display`, `opacity`
  // and friends have no token to be off, and positioning a hidden clipboard
  // shim is not a design decision.
  const sized = /(?:^|[;"'`\s])(border-radius|font-size|box-shadow)\s*:\s*([^;"'`]+)/g;
  const allowed = /^(inherit|0|[0-9.]+em|16px|50%|none|var\(--(radius(-sm|-lg|-pill)?|step-(-1|-2|0|1|2|3)|lift(-low|-high)?|bevel-(raised|inset|pressed))\))$/;
  const strays = [];
  for (const [name, src] of scripts()) {
    if (name.endsWith(".test.mjs")) continue;
    // The export artefacts build a whole self-contained stylesheet for a
    // document that is not this page and cannot read its tokens; they are
    // reviewed against themes/*.json instead. The sheet is assembled as a
    // run of concatenated string literals, so the exemption runs from the
    // `exportCss` declaration to the statement that ends it, not one line.
    let inExportCss = false;
    src.split("\n").forEach((line, i) => {
      if (/\bexportCss\s*=/.test(line)) inExportCss = true;
      const exempt = inExportCss;
      if (inExportCss && /;\s*$/.test(line)) inExportCss = false;
      if (exempt) return;
      for (const m of line.matchAll(sized)) {
        const value = m[2].trim();
        if (value.split(/\s+/).every((part) => allowed.test(part))) continue;
        strays.push(`${name}:${i + 1}  ${m[1]}: ${value}`);
      }
    });
  }
  assert.deepEqual(strays, [], `off-token inline styles (move the rule into a sheet):\n${strays.join("\n")}`);
});
