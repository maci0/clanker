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
  const layers = (value) => {
    const out = [];
    let depth = 0, buf = "";
    for (const ch of value) {
      if (ch === "(") depth++;
      else if (ch === ")") depth--;
      if (ch === "," && depth === 0) { out.push(buf); buf = ""; continue; }
      buf += ch;
    }
    return out.concat(buf).map((s) => s.trim()).filter(Boolean);
  };
  const hasOffset = (layer) => {
    const lengths = layer.match(/(^|\s)-?[0-9.]+(px|rem|em)?(?=\s|$)/g) || [];
    return lengths.slice(0, 2).some((n) => parseFloat(n) !== 0);
  };
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const { value, line } of declarations(css, "box-shadow")) {
      if (value === "none") continue;
      for (const layer of layers(value)) {
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

test("every theme declares all three elevation rungs", () => {
  // A rung declared only in app.css is a rung the ten themes cannot retune,
  // which is how a light-theme smudge survives on graphite.
  const appCss = readFileSync(join(here, "app.css"), "utf8");
  const rungs = ["--lift-low", "--lift", "--lift-high"];
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
  const scripts = [
    ["app/app.js", join(here, "app.js")],
    ["app/core/chat.js", join(here, "core", "chat.js")],
  ];
  for (const name of readdirSync(pluginsDir, { withFileTypes: true })) {
    if (!name.isDirectory()) continue;
    try {
      const path = join(pluginsDir, name.name, "app.js");
      readFileSync(path, "utf8");
      scripts.push([`plugins/${name.name}/app.js`, path]);
    } catch {
      // Not every plugin ships a script.
    }
  }
  for (const [name, path] of scripts) {
    if (owners.has(name)) continue;
    readFileSync(path, "utf8").split("\n").forEach((line, i) => {
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
  const luminance = (h) => {
    const parts = [1, 3, 5]
      .map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2];
  };
  const contrast = (a, b) => {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
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
