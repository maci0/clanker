import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "bun:test";

// The Control Cabinet's edges and its type scale are tokens, not literals.
// The source declares five radii (2/3/4px plus the pill) and six type steps, and
// the header comment says why: machined plate edges, "not SaaS cards", with
// every legend plate on one scale. A stray `border-radius: 12px` or
// `font-size: 14px` does not read as a bug, so nothing catches it — the sheet
// just drifts back toward the rounded-card default one declaration at a time.
// That is exactly how the board grew a 12px/8px Trello island and the chat
// composer a 24px pill while the tokens said 4px. These tests pin the
// contract: a size that is not on the scale must be a deliberate, named
// exception here rather than a literal nobody chose.

const here = dirname(fileURLToPath(import.meta.url)),
  pluginsDir = join(here, "..", "plugins");

function sheets() {
  const out = [
    // The one sheet, source not build product: tailwind.css is machine output,
    // and every value a person writes lives in tailwind.src.css — the cabinet's
    // tokens, its element layer and the port's utilities, in one place now that
    // the last cabinet sheet is gone.
    ["app/tailwind.src.css", readFileSync(join(here, "tailwind.src.css"), "utf8")],
    // The win2k skin is fetched only when that theme is applied, but it is
    // still a sheet this page paints with, so it rides the same scale and edge
    // tokens as the two above instead of escaping their pins by living outside
    // the bundle.
    ["themes/win2k.css", readFileSync(join(here, "..", "..", "themes", "win2k.css"), "utf8")],
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
/** @returns {[string, string][]} Each shipped script's display path and source. */
function scripts() {
  /** @type {[string, string][]} */
  const out = [];
  /**
   * @param {string} dir Directory to walk.
   * @param {string} prefix Display path for files under it.
   */
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
/**
 * @param {string} css A stylesheet.
 * @param {string} prop The property to find.
 * @returns {{ value: string, line: number }[]} Each declaration's value and 1-based line.
 */
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

test("task suggestions are flat controls without entrance choreography", () => {
  // The suggestion is a class list in app.js now, so the guard reads it: no
  // shadow of its own, and no animation on the control.
  const app = readFileSync(join(here, "app.js"), "utf8");
  const m = /var SUGGESTION_CLASS = "([^"]*)"/.exec(app);
  assert.ok(m, "the suggestion's class list must exist");
  assert.match(m[1], /shadow-none/);
  assert.doesNotMatch(m[1], /\banimate-/);
});

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

test("the scale the sheets reference is the scale the source declares", () => {
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
  for (const token of ["--step--2", "--step--1", "--step-0", "--step-1", "--step-2", "--step-3"]) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
  for (const token of ["--radius-sm", "--radius", "--radius-lg", "--radius-pill"]) {
    assert.match(appCss, new RegExp(`\\n\\s*${token}\\s*:`), `${token} is used but never declared`);
  }
  assert.match(appCss, /\n\s*--track-label\s*:\s*0\s*;/, "--track-label is the 0 DESIGN.md names: labels are sentence case, untracked");

  for (const token of ["--leading-prose", "--leading-control", "--leading-caption", "--motion-tap", "--motion-slide", "--motion-settle", "--curve-tap", "--curve-slide", "--curve-settle"]) {
    assert.match(appCss, new RegExp(String.raw`\n\s*${token}\s*:`, "u"), `${token} is used but never declared`);
  }
});

/* Tracking, leading, duration and easing are the four axes Tailwind supplies
   defaults for, and a default is a value nobody in this project chose. The
   radius scale was closed first (`--radius-*: initial`, then the four cabinet
   edges), and these four were left open: `tracking-wide` was live in five
   views at Tailwind's 0.025em while the cabinet says labels are untracked,
   and nine call sites were spelling a millisecond count out by hand. So the
   same closure applies, and these checks read the COMPILED sheet, where a raw
   literal would show up as a number rather than as a var().

   The committed sheet is a clean rebuild of the source, so reading it is
   reading what the browser gets: a value written as a var() in the source
   arrives as a var(), and a Tailwind default arrives as a number. */
const tokenScan = {
  /**
   * The closed utilities and the theme keys they read, checked against the
   * token each has to resolve to.
   * @param {string} compiled The compiled sheet.
   * @returns {string[]} Each closed utility or theme key that is not its token.
   */
  closedUtilityStrays(compiled) {
    /* `--tw-*` is the utility's own property, so a value read off it is what
       the rule paints. */
    const closed = {
        "duration-settle": "--motion-settle",
        "duration-tap": "--motion-tap",
        "ease-in": "--curve-tap",
        "ease-in-out": "--curve-settle",
        "ease-out": "--curve-slide",
        "leading-none": "--leading-caption",
        "leading-normal": "--leading-prose",
        "leading-relaxed": "--leading-prose",
        "leading-snug": "--leading-control",
        "leading-tight": "--leading-caption",
        "tracking-normal": "--track-label",
        "tracking-wide": "--track-label",
      },
      /* The theme keys those utilities read, at the top of the sheet. A
         number here is Tailwind's default leaking through a name that
         survived. */
      keys = [
        ["--tracking-normal", "--track-label"],
        ["--tracking-wide", "--track-label"],
        ["--leading-normal", "--leading-prose"],
        ["--leading-snug", "--leading-control"],
        ["--ease-out", "--curve-slide"],
        ["--ease-in-out", "--curve-settle"],
        ["--ease-in", "--curve-tap"],
        ["--default-transition-duration", "--motion-tap"],
        ["--default-transition-timing-function", "--curve-tap"],
      ],
      /** @type {string[]} */
      strays = [];

    /* Not every closed utility is a standalone class: `tracking-normal` is
       written as an arbitrary-variant descendant (`[&_dt]:tracking-normal`),
       which the compiler inlines rather than emitting a `.tracking-normal`
       rule. So the theme keys are what assert the binding, and this loop
       only has to agree with them wherever a rule does exist. */
    for (const [utility, token] of Object.entries(closed)) {
      const body = new RegExp(String.raw`\.${utility}\s*\{(?<body>[^}]*)\}`, "u").exec(compiled)?.groups?.body;

      if (body !== undefined && !body.includes(token)) {
        strays.push(`${utility} does not resolve to ${token}: ${body.trim()}`);
      }
    }

    for (const [key, token] of keys) {
      const value = new RegExp(String.raw`(?:^|[;{\s])${key}\s*:\s*(?<value>[^;}]+)`, "u").exec(compiled)?.groups?.value.trim();

      if (value === undefined) {
        strays.push(`${key} is missing from the compiled sheet`);
      } else if (value !== `var(${token})`) {
        strays.push(`${key} is ${value}, not var(${token})`);
      }
    }

    return strays;
  },

  /** @returns {Promise<string>} The committed compiled sheet. */
  compiledSheet() {
    return Bun.file(join(here, "tailwind.css")).text();
  },

  /**
   * A closed namespace has to actually be closed. Clearing the namespace and
   * re-declaring three rungs only holds if the framework's own rungs are gone
   * from the compiled sheet, and this is the half that is easy to get wrong:
   * the names can be absent from the source's `@theme` and still be emitted
   * by the utility layer (`--duration-*` is exactly that case, which is why
   * the three motion rungs are `@utility` blocks rather than theme keys).
   * @param {string} compiled The compiled sheet.
   * @returns {string[]} Each framework tracking, duration or curve default still in it.
   */
  frameworkDefaultStrays(compiled) {
    /* A millisecond count or a bare easing keyword outside the three tokens,
       in the sheet's own rules or in a utility it emitted. */
    const authored = compiled.replaceAll(/var\(--motion-[a-z]+\)|var\(--curve-[a-z]+\)|var\(--track-label\)|var\(--leading-[a-z]+\)/gu, ""),
      /** @type {string[]} */
      strays = [];

    /* 0.025em is Tailwind's `tracking-wide`, live in five views while the
       cabinet says labels are untracked. */
    for (const literal of [/letter-spacing:\s*0\.025em/u, /letter-spacing:\s*0\.02em(?!\d)/u]) {
      if (literal.test(compiled)) { strays.push(`compiled ${literal.source} is Tailwind's tracking default`); }
    }

    for (const m of authored.matchAll(/(?:transition-duration|--tw-duration):\s*(?<value>[^;}]+)/gu)) {
      const value = (m.groups?.value ?? "").trim();

      if (/^\d+m?s$/u.test(value)) { strays.push(`transition-duration: ${value} is a literal, not a rung`); }
    }

    /* `var(--tw-ease, ...)` is Tailwind's own fallback spelling and is fine;
       what must not appear is a hand-typed curve. */
    for (const m of authored.matchAll(/(?:transition-timing-function|--tw-ease):\s*(?<value>[^;}]+)/gu)) {
      const value = (m.groups?.value ?? "").trim();

      if (value.startsWith("cubic-bezier") && !compiled.includes("var(--curve-settle)")) {
        strays.push(`transition-timing-function: ${value} is a curve nobody put on the panel`);
      }
    }

    return strays;
  },

  /**
   * Naming a rung for the movement it makes is half the discipline: a
   * duration paired with a curve from a different rung is the incoherence the
   * tokens exist to prevent, and it survives review because both halves look
   * reasonable alone (the board's expanding card label shipped a tap speed
   * beside a settle curve). The only pairs that mean anything are the three
   * matching rungs.
   * @returns {string[]} Each script pairing one rung's duration with another's curve.
   */
  mismatchedRungPairs() {
    /** @type {string[]} */
    const paired = [];

    for (const [file, src] of scripts()) {
      for (const m of src.matchAll(/duration-(?<rung>tap|slide|settle)\b[^"'`]*?\[transition-timing-function:var\(--curve-(?<curve>[a-z]+)\)\]/gu)) {
        const { curve, rung } = m.groups ?? {};

        if (curve !== rung) { paired.push(`${file}: duration-${rung} beside --curve-${curve}`); }
      }
    }

    return paired;
  },

  /**
   * The views ask for the rungs by name, so a numbered rung cannot creep back
   * in the one place the compiler would silently honour it. (This file is a
   * scanned source too, so it must not spell one either.)
   * @returns {string[]} Each numbered duration or easing a script names.
   */
  numberedRungStrays() {
    /** @type {string[]} */
    const strays = [];

    for (const [, src] of scripts()) {
      for (const m of src.matchAll(/\bduration-\d+\b|\bease-(?!in-out|out|in\b|linear)\w+\b/gu)) {
        strays.push(`${m[0]} at offset ${m.index}`);
      }
    }

    return strays;
  },

  /**
   * The sheet's own declarations go through the same tokens as the
   * utilities. Fourteen `line-height: 1.6` and five `transition: … 120ms
   * ease-out` are the same unconsidered number the utility closure removes,
   * written where nobody sees a class name.
   * @param {string} appCss The source sheet.
   * @returns {string[]} Each raw leading or motion literal in its own rules.
   */
  rawLiteralStrays(appCss) {
    /** @type {string[]} */
    const strays = [];

    /* A var() or a value other than a bare number is fine; a bare number is
       a leading nobody chose. */
    for (const { value, line } of declarations(appCss, "line-height")) {
      if (!value.startsWith("var(--leading-") && /^1(?:\.\d+)?$/u.test(value)) {
        strays.push(`tailwind.src.css:${line}  line-height: ${value}`);
      }
    }

    for (const { value, line } of declarations(appCss, "transition")) {
      if (/\d+ms/u.test(value)) { strays.push(`tailwind.src.css:${line}  transition: ${value}`); }

      if (value.startsWith("cubic-bezier")) { strays.push(`tailwind.src.css:${line}  transition: ${value}`); }
    }

    /* An animation's own period is a design choice the sheet states in full
       (a lamp breathes on a 1.8s cycle); only a bare millisecond count, which
       cannot be read as a cycle, is a stray. */
    for (const { value, line } of declarations(appCss, "animation")) {
      if (/^\d+m?s\s/u.test(value)) { strays.push(`tailwind.src.css:${line}  animation: ${value}`); }
    }

    return strays;
  },

  /** @returns {Promise<string>} The source sheet, `tailwind.src.css`. */
  sourceSheet() {
    return Bun.file(join(here, "tailwind.src.css")).text();
  },

  /**
   * Preflight declares a root leading of 1.5 that the `leading-*` closure
   * cannot delete, and no amount of a token above makes its number go away:
   * what matters is which of the two declarations wins. Both are in
   * `layer(base)`, so the later one is the applied value, and the last
   * `html, :host` rule has to be the cabinet's. If this ever fails, the
   * element layer has grown a rule that lands after it and the default is
   * live again.
   * @param {string} compiled The compiled sheet.
   * @returns {string} The last `html, :host` rule's body, or why there is none.
   */
  rootLeadingRule(compiled) {
    return [...compiled.matchAll(/html,\s*:host\s*\{(?<body>[^}]*)\}/gu)].at(-1)?.groups?.body ?? "the root leading rule is gone from the compiled sheet";
  },
};

test("the compiled sheet carries no raw tracking, leading, duration or easing default", async () => {
  // Every track, lead, duration and curve is a cabinet token.
  assert.deepEqual(tokenScan.closedUtilityStrays(await tokenScan.compiledSheet()), []);
});

test("no framework default survived the closure", async () => {
  const compiled = await tokenScan.compiledSheet(),
    leading = tokenScan.rootLeadingRule(compiled),
    paired = tokenScan.mismatchedRungPairs(),
    rungs = tokenScan.numberedRungStrays(),
    strays = tokenScan.frameworkDefaultStrays(compiled);

  assert.deepEqual(strays, [], `a speed is a token, not a number typed in a view:\n${strays.join("\n")}`);
  assert.deepEqual(rungs, [], `motion is a rung name, not a Tailwind number:\n${rungs.join("\n")}`);
  assert.deepEqual(paired, [], `a speed and a curve come from the same rung:\n${paired.join("\n")}`);
  assert.match(leading, /line-height:\s*var\(--leading-[a-z]+\)/u, `the applied root leading is not a rung: ${leading.trim()}`);
});

test("no raw leading or motion literal in the sheet's own rules", async () => {
  // The sheet reads the panel's tokens.
  assert.deepEqual(tokenScan.rawLiteralStrays(await tokenScan.sourceSheet()), []);
});

// Engraved labels are one tracking. Headings are untracked. The SaaS pair
// (tight bold titles + 0.1em all-caps micro-labels) is what this pin refuses.
test("letter-spacing is --track-label, optical, or none", () => {
  const allowed = /^(0|normal|0\.01em|0\.02em|\.02em|var\(--track-label\))$/;
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const { value, line } of declarations(css, "letter-spacing")) {
      if (allowed.test(value)) continue;
      strays.push(`${name}:${line}  letter-spacing: ${value}`);
    }
  }
  assert.deepEqual(strays, [], `engraved labels use --track-label; headings stay untracked:\n${strays.join("\n")}`);
});

test("the cabinet sheet does not alias a removed library's theme tokens", () => {
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
  assert.equal(appCss.includes("--pf-t--"), false);
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

// A lamp pinned with `left:` is a lamp that stays on the left when the page
// reads right to left. The sheets already say so: the disclosure chevron's
// comment names `border-inline-end` swapping under `dir="rtl"`, and the same
// file uses `inset-inline-start` for every other marker. A physical `left:`
// does not read as a bug, so nothing caught the three that had crept in
// (`.lamp`, `.rail-tab[aria-selected]`, `.room-row[data-active]`) -- the rail
// and the room list each put their marker on the wrong side, at the far edge
// from the text it marks. Centering is not a direction: `left: 50%` with a
// `translateX(-50%)` lands in the same place in either direction, so it is the
// one exemption and it is named here rather than waved through.
test("a marker is placed with a logical property, so it mirrors under dir=rtl", () => {
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const m of css.matchAll(/(^|[;{\s])(left|right)\s*:\s*([^;}]+)/g)) {
      if (/-50%|50%/.test(m[3]) && /translateX/.test(css.slice(m.index, m.index + 200))) continue;
      strays.push(`${name}:${css.slice(0, m.index).split("\n").length}  ${m[1].trim()} ${m[2]}: ${m[3].trim()}`);
    }
  }
  assert.deepEqual(strays, [], `use inset-inline-start/end, not left/right:\n${strays.join("\n")}`);
});

// The mirror has to be written down where the marker's own rule is, or the
// chevron is the only thing in the sheet with a reading direction: it opens
// toward the reading direction in LTR, and the same `border-inline-end` it
// draws on means the fold is sideways in RTL unless a `[dir="rtl"]` rule
// mirrors the rotation beside it. The comment at the chevron already claimed
// this rule existed; it did not, and an unbacked comment is the one thing
// here that reads as done.
test("a caret built from a rotation has a dir=rtl mirror beside it", () => {
  const src = readFileSync(join(here, "tailwind.src.css"), "utf8");
  for (const sel of [".rail-fold > summary.rail-group::after", ".disclosure-caret > summary::before"]) {
    const at = src.indexOf(sel);
    assert.notEqual(at, -1, `${sel} must exist`);
    const rule = src.slice(at, src.indexOf("}", at));
    if (!/rotate\(/.test(rule)) continue; // An unrotated mask needs no mirror.
    assert.match(src.slice(at, at + 1200), new RegExp(`\\[dir="rtl"\\][^\\n]*${sel.replace(/[.[\]()*+?^$|\\{}]/g, "\\$&")}`),
      `${sel} rotates with the reading direction, so it needs a [dir="rtl"] mirror`);
  }
});

test("spacing that lands on a rung of the scale is written as the token", () => {
  const props = "gap|row-gap|column-gap|padding|margin";
  const re = new RegExp(`(^|[;{\\s])(?:${props})(?:-(?:top|right|bottom|left|block|inline))?\\s*:\\s*([^;}]+)`, "g");
  const strays = [];
  for (const [name, css] of sheets()) {
    for (const m of css.matchAll(re)) {
      for (const part of m[2].split(/[\s(,]+/)) {
        const token = SPACE_STEPS[part];
        // A negative offset has no token; it is a nudge off the rhythm.
        if (!token || m[2].slice(0, m[2].indexOf(part)).endsWith("-")) continue;
        strays.push(`${name}:${css.slice(0, m.index).split("\n").length}  ${part} is var(${token})`);
      }
    }
  }
  assert.deepEqual(strays, [], `spacing on the scale must name its token:\n${strays.join("\n")}`);
});

test("the space scale the sheets reference is the scale the source declares", () => {
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
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
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
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
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
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

// Violet is the axis that kept its name while losing its meaning. app.css
// re-points --violet at --accent twice (the day root and the night block):
// goals and jumps are operator action, and "a cabinet whose whole argument is
// that one blue means one thing cannot carry two blues". The themes shipped the
// palette's own pink/magenta as violet -- frappe's #f4b8e4, tokyonight's
// #bb9af7 -- so a goal chip and a button were two different colours on one
// screen, and a mauve --accent meant the aliases below could not have fixed
// it: the interactive role itself needed re-deriving, which the next test
// pins. Both halves are the same rule, so the theme rides the token rather
// than forking it.
test("violet is the interactive accent in every theme", () => {
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
  assert.match(
    appCss,
    /\n\s*--violet\s*:\s*var\(--accent\)\s*;/,
    "app.css must re-point --violet at --accent (goals are operator action)",
  );
  for (const [file, tokens] of themeTokens()) {
    assert.equal(tokens["--violet"], "var(--accent)", `themes/${file} --violet must ride --accent`);
    assert.equal(tokens["--violet-text"], "var(--accent-text)", `themes/${file} --violet-text must ride --accent-text`);
  }
});

// The accent is the one role no theme may colour for its own sake. The chat
// hues were re-derived per family because eight themes shipped a borrowed ramp;
// the accent was the same borrowing one role up, and it was worse: seven of the
// ten themes put their palette's mauve where the IEC rule says operator blue
// lives (mocha #cba6f7, tokyonight #9d7cd8, latte #8839ef, ...), so the one
// colour the whole system is built on read as a different colour in every theme
// but two, and the day face's #1d5c9e had no sibling on a dark panel. Each
// theme now carries a blue reading of its own palette's blue, picked at or
// above the contrast its mauve had. A named theme is its neutrals and its
// lamps; it is not allowed an accent.
test("the operator accent is a blue reading in every theme", () => {
  for (const [file, tokens] of themeTokens()) {
    const resolve = tokenValue(tokens);
    const accent = tokens["--accent"];
    assert.match(accent, /^#[0-9a-f]{6}$/i, `themes/${file} --accent must be a literal hex`);
    const hue = hueAngle(accent);
    // Blue band, 180-260. hackerman's green CRT and every neutral-free grey are
    // deliberately outside it, so this refuses mauve and magenta only.
    const inBlueBand = hue !== null && hue >= 180 && hue <= 260;
    if (!inBlueBand) {
      // Green-on-black is the one deliberate exception: the theme is a phosphor.
      assert.match(tokens["--fg"] || "", /^#(33ff66|00ff88)/i,
        `themes/${file} --accent ${accent} is not a blue reading (hue ${hue?.toFixed(1)})`);
      continue;
    }
    const surface = resolve(tokens, "--surface") || resolve(tokens, "--paper");
    assert.ok(surface, `themes/${file} must declare --surface/--paper`);
    assert.ok(contrast(accent, surface) >= 4.5,
      `themes/${file} --accent ${accent} on ${surface} is under 4.5:1`);
    // The ink that sits on the accent must clear too, or the button label
    // goes with the fill.
    const ink = resolve(tokens, "--on-accent");
    assert.ok(ink && contrast(accent, ink) >= 4.5,
      `themes/${file} --on-accent ${ink} on --accent ${accent} is under 4.5:1`);
  }
});

// Every text token against every surface a text run can land on. The accent
// test above asks one question (is --accent a blue reading on --surface), and
// the chat-hue test asks another (are the sender enamels legible). Neither
// looks at --danger / --ok / --warn-text on --surface-2, which is where most
// body text actually sits: a card, a pill, a composer lane. That gap shipped
// thirty failing pairs across four themes -- latte's --danger at 3.52:1 on its
// own raised surface, tokyonight-day's --code-fg at 3.52:1 on its own code
// well, light's --ok at 3.85:1 on the page it is printed on. A theme's
// contrast is a property of the *pair*, and only the pair was ever unchecked.
//
// Every token below is one a `text-*` utility reaches for, and every surface
// below is one the sheet paints behind a text run. --accent and --warn are
// held to the text bar rather than the fill bar: they carry white legend as
// fills too, and darkening a fill only raises the contrast of what sits on
// it, so the stricter bar costs nothing and covers the dozens of call sites
// that paint them as words rather than as fills.
test("every text token clears 4.5:1 on every surface it can land on", () => {
  const TEXT_TOKENS = [
    "--fg", "--fg-muted", "--accent", "--accent-text", "--warn", "--warn-text",
    "--danger", "--ok", "--code-fg",
  ];
  const SURFACE_TOKENS = ["--bg", "--paper", "--surface", "--surface-2", "--code-bg"];
  const strays = [];
  for (const [file, tokens] of themeTokens()) {
    const resolve = tokenValue(tokens);
    const surfaces = SURFACE_TOKENS.map((k) => resolve(tokens, k))
      .filter((v) => typeof v === "string" && /^#[0-9a-f]{6}$/i.test(v));
    assert.ok(surfaces.length, `themes/${file} must declare a literal surface to measure against`);
    for (const token of TEXT_TOKENS) {
      const value = resolve(tokens, token);
      // A token this theme does not define falls back to the sheet's own :root
      // reading, which has its own pins; a non-literal is color-mix or a ramp
      // the browser computes, and neither is measurable here.
      if (typeof value !== "string" || !/^#[0-9a-f]{6}$/i.test(value)) continue;
      for (const surface of surfaces) {
        const ratio = contrast(value, surface);
        if (ratio < 4.5) {
          strays.push(`themes/${file}  ${token} ${value} on ${surface} is ${ratio.toFixed(2)}:1, want >= 4.5`);
        }
      }
    }
  }
  assert.deepEqual(strays, [], `text tokens must stay legible on every theme's own surfaces:\n${strays.join("\n")}`);
});

// The accent wash is --accent's hue at a fixed alpha: --accent-dim paints the
// hover and selected-row tint, so it is the same colour as the accent, only
// transparent. The sheet's own day face spells both hexes out, and a theme
// copied that habit, so the two drift the moment one is edited alone: every
// selected row and hover wash in that theme is then tinted with a colour the
// theme uses nowhere else. Note this is NOT the --accent / --accent-text pair:
// those are deliberately two readings (a fill behind white legend, and a
// darker word on a panel), which is why the sheet keeps them apart.
test("each theme's accent wash is the accent reading at the same alpha", () => {
  for (const [file, tokens] of themeTokens()) {
    const wash = tokens["--accent-dim"], accent = tokens["--accent"];
    if (typeof accent !== "string" || !/^#[0-9a-f]{6}$/i.test(accent)) continue;
    if (typeof wash !== "string" || !/^#[0-9a-f]{8}$/i.test(wash)) continue;
    assert.equal(wash, accent + wash.slice(7),
      `themes/${file} --accent-dim must be --accent ${accent} at alpha ${wash.slice(7)}, not ${wash}`);
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
  // Colour emoji (U+1F300-U+1FAFF, plus the variation selector that promotes
  // a symbol such as U+26A0 to colour) and the emoji-keycap range. U+2713/
  // U+25B6-style text symbols render monochrome in the panel's ink and are
  // not what this is about; U+26A0 WARNING SIGN is in the emoji range in every
  // font a browser will pick for it, and a run chip that types one is chrome
  // drawn outside ICON_PATHS -- which is how "⚠ failed check" shipped past
  // this test for as long as the class existed.
  const emoji = /[\u{1F300}-\u{1FAFF}\u{20E3}\u{26A0}\u{2705}\u{274C}\u{2757}]|️/u;
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

test("ICON_PATHS has no sparkle chrome", () => {
  const icons = readFileSync(join(here, "core", "icons.js"), "utf8");
  assert.doesNotMatch(icons, /\baiSparkle\b/, "sparkle is leftover AI-experience chrome");
  assert.doesNotMatch(icons, /\baiInfo\b/, "unused info sparkle sibling; help already draws the circle-i");
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
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");

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
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
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
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
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
  const appCss = readFileSync(join(here, "tailwind.src.css"), "utf8");
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

// A theme token may alias another (`var(--paper)`), so any test that measures
// a colour has to read through the alias. One hop chain is the most the
// catalog actually uses; the depth cap is there so a cycle cannot hang the
// suite.
function tokenValue(tokens) {
  const read = (key, seen = 0) => {
    const v = tokens[key];
    if (!v || !v.startsWith("var(") || seen > 4) return v;
    return read(v.slice(4, -1), seen + 1);
  };
  return (t, key) => read(key);
}

test("every theme declares all eight chat hues, legible on its own surface", () => {
  // A sender hue is drawn twice: as the name's text on the panel face, and as
  // an avatar fill carrying --on-accent as ink (see .avatar-tone-* in app.css).
  // Both readings have to hold, which is why both are measured here. 4.5 is
  // the floor rather than the cards' 5.5 because a sender name is not a badge
  // on a fill and the palette must still spread across eight tellable hues;
  // the borrowed ramp this replaced bottomed out at 4.2.
  for (const [file, tokens] of themeTokens()) {
    const resolve = tokenValue(tokens);
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
    // declaration that opens it to the statement that ends it, not one line.
    // `buildExportCss` is that declaration now that the values are read from
    // the live page rather than carried as a second literal palette; a
    // function body ends at its own closing brace, and a function expression
    // inside it (the token reader's own `;`) must not close the exemption.
    let inExportCss = false;
    src.split("\n").forEach((line, i) => {
      if (/\bexportCss\s*=/.test(line)) inExportCss = "statement";
      else if (/\bfunction buildExportCss\b/.test(line)) inExportCss = "function";
      const exempt = Boolean(inExportCss);
      if (inExportCss === "statement" && /;\s*$/.test(line)) inExportCss = false;
      else if (inExportCss === "function" && line.startsWith("}")) inExportCss = false;
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

// Two artefacts leave the machine carrying their own stylesheet: the run
// export in features/runs.js and `clanker session export` in
// tools/zig/session_export_logic.zig. Neither can read this page's tokens at
// open time, so both pin their own. The run export reads the applied palette
// and falls back to the day cabinet; the Zig one has only literals, and its
// lamp colours were still a framework ramp (Material #0b57d0, Tailwind
// amber-700/green-400/amber-400) while the store it says it copied had moved
// to RAL 5017/1004/6002. Same product, two blues, one of them the artefact an
// operator emails to someone.
test("the export stylesheets wear the theme store's readings", () => {
  const themesDir = join(here, "..", "..", "themes");
  const light = JSON.parse(readFileSync(join(themesDir, "light.json"), "utf8")).tokens;
  const dark = JSON.parse(readFileSync(join(themesDir, "dark.json"), "utf8")).tokens;

  const runs = readFileSync(join(here, "features", "runs.js"), "utf8");
  const fallback = runs.match(/var EXPORT_FALLBACK = \{[^}]*\}/);
  assert.ok(fallback, "runs.js must declare EXPORT_FALLBACK");
  for (const [exported, token] of [["--bg", "--bg"], ["--fg", "--fg"], ["--fg-muted", "--fg-muted"],
                                   ["--border", "--border"], ["--surface", "--surface"], ["--code-bg", "--code-bg"]]) {
    const got = fallback[0].match(new RegExp(`"${exported}":\\s*"([^"]+)"`));
    assert.ok(got, `EXPORT_FALLBACK has no ${exported}`);
    assert.equal(got[1], light[token], `EXPORT_FALLBACK ${exported} must be themes/light.json ${token}`);
  }
  assert.match(runs, /buildExportCss\(readToken\)/, "the export must read the palette on screen, not carry one");

  const zig = readFileSync(join(here, "..", "..", "tools", "zig", "session_export_logic.zig"), "utf8");
  const day = zig.match(/\\\\:root\{[^}]*\}/);
  const night = zig.match(/prefers-color-scheme:dark\)\{:root\{([^}]*)\}/);
  assert.ok(day && night, "the session export must declare a day and a night palette");
  const read = (block) => Object.fromEntries([...block.matchAll(/--([a-z-]+):(#[0-9a-f]{6})/g)].map((m) => [m[1], m[2]]));
  const exported = { day: read(day[0]), night: read(night[1]) };
  for (const [face, theme] of [["day", light], ["night", dark]]) {
    for (const [exported_name, token] of [["bg", "--bg"], ["fg", "--fg"], ["muted", "--fg-muted"],
                                         ["line", "--rule"], ["edge", "--border"], ["card", "--surface"],
                                         ["code", "--code-bg"], ["act", "--accent"], ["ok", "--ok"], ["warn", "--warn"]]) {
      assert.equal(exported[face][exported_name], theme[token],
        `session export ${face} --${exported_name} must be ${token} (${theme[token]})`);
    }
  }
});

// The two export stylesheets are outside `sheets()`, so the sheet-level pins
// above never see them, and both had the same drift: `letter-spacing` and
// `text-transform:uppercase` on their meta and role labels. That is the
// all-caps letter-spaced micro-label the brand guide and DESIGN.md both
// forbid, applied to markup that is already sentence case, so it was
// decoration over correct text. This reads the CSS out of each artefact and
// holds both to the rules the cabinet holds itself to: sentence case,
// untracked labels, and both font stacks declared once as tokens rather than
// retyped at every call site.
test("the export stylesheets keep the cabinet's sentence case and font tokens", () => {
  const zig = readFileSync(join(here, "..", "..", "tools", "zig", "session_export_logic.zig"), "utf8");
  const runs = readFileSync(join(here, "features", "runs.js"), "utf8");

  // Each artefact spells its sheet differently: the Zig one as a run of
  // `\\`-prefixed line literals, the JS one as concatenated string pieces.
  const zigSheet = [...zig.matchAll(/^ {4}\\\\([^\n]*)$/gm)].map((m) => m[1]).join("\n");
  const jsSheet = readExportCssFromRuns(runs);
  assert.ok(zigSheet.length > 200 && jsSheet.length > 100,
    "both export stylesheets must be readable for the type pins below");

  for (const [name, sheet] of [["session export", zigSheet], ["run export", jsSheet]]) {
    const strays = [];
    for (const m of sheet.matchAll(/letter-spacing:\s*([^;}]+)/g)) {
      const value = m[1].trim();
      if (value === "0" || value === "normal") continue;
      strays.push(`${name}  letter-spacing: ${value}`);
    }
    for (const m of sheet.matchAll(/text-transform:\s*([^;}]+)/g)) {
      const value = m[1].trim();
      if (value === "none") continue;
      strays.push(`${name}  text-transform: ${value}`);
    }
    assert.deepEqual(strays, [],
      `exports are sentence case and untracked, like every other clanker surface:\n${strays.join("\n")}`);

    // A stack typed inline at each use is how the two faces drifted apart in
    // the first place; one --sans and one --mono, referenced everywhere. The
    // :root declaration is where the two stacks legitimately live, so it is
    // removed before counting bare references to them.
    const body = sheet.replace(/:root\{[^}]*\}/, "");
    const bare = (body.match(/ui-monospace|ui-sans-serif|system-ui/g) || []).length;
    const declared = (sheet.match(/--(sans|mono):/g) || []).length;
    assert.equal(declared, 2, `${name} must declare exactly --sans and --mono once each`);
    assert.equal(bare, 0, `${name} must reference its font stacks only through --sans/--mono`);
  }
});

/* The run export builds its sheet by concatenating string literals inside
   `buildExportCss`, so the pieces are pulled out rather than hand-copied: what
   this returns is what the button writes into the downloaded file. */
function readExportCssFromRuns(src) {
  const start = src.indexOf("export function buildExportCss");
  assert.notEqual(start, -1, "runs.js must keep buildExportCss");
  const body = src.slice(start, src.indexOf("\n}", start));
  return [...body.matchAll(/"((?:[^"\\]|\\.)*)"/g)]
    .map((m) => m[1].replace(/\\"/g, '"'))
    .join("");
}

test("the office canvas paints the cabinet's signal colours, not a borrowed ramp", () => {
  const office = readFileSync(join(pluginsDir, "office", "app.js"), "utf8");

  // Every status lamp on the whiteboard is an IEC role: healthy, abnormal,
  // fault. Those three readings were Google's green/amber/red, which appear
  // nowhere in the palette and matched neither the board's status colours nor
  // the same three lamps in any other view.
  for (const role of ["ok", "warn", "danger"]) {
    assert.ok(office.includes(`cssVar("--${role}"`), `the office lamps must read --${role} from the cabinet`);
  }

  // One stable colour per clanker name is a promise the Board already makes
  // through --chat-hue-N; the office cannot keep a private HSL wheel and still
  // be the same product.
  assert.match(office, /cssVar\("--chat-hue-"/, "agent colours must come from the shared chat-hue palette");
  assert.doesNotMatch(office, /hsl\(/, "a private hue wheel is a second identity for the same people");

  // Any colour the office paints as chrome (a surface, an edge, a reading) is
  // a token read; a literal hex is the drift this pins. Drop every cssVar call
  // first, since its second argument is a checked fallback below. What is left
  // is object paint on the pixel-art sheet: cork, desk timber, the portrait.
  const objectPaint = /#(?:8b5e34|8a6a44|6d5335|4a3722|f4d9b0|2a1c10)/g;
  const found = [];
  office.split("\n").forEach((line, i) => {
    const kept = line.replace(/cssVar\(.*?"#[0-9a-f]{6}"\)/g, "").replace(objectPaint, "");
    for (const hex of kept.match(/#[0-9a-fA-F]{6}/g) || []) found.push(`office/app.js:${i + 1}  ${hex}`);
  });
  assert.deepEqual(found, [], `canvas chrome must read the cabinet tokens:\n${found.join("\n")}`);

  // And those fallbacks are the cabinet's own day readings, so a context with
  // no computed style still draws the cabinet rather than an imported ramp.
  const src = readFileSync(join(here, "tailwind.src.css"), "utf8");
  // The day face only: the sheet restates the tokens in its dark blocks and
  // each theme/ has its own, so the first :root is the reading a fallback must
  // quote.
  const dayBlock = src.slice(src.indexOf(":root"), src.indexOf("}", src.indexOf(":root")));
  const tokens = Object.fromEntries(
    [...dayBlock.matchAll(/(--[a-z0-9-]+):\s*(#[0-9a-f]{6})/g)].map((m) => [m[1], m[2]]));
  const fallbacks = [...office.matchAll(/cssVar\("(--[a-z0-9-]+)",\s*"(#[0-9a-f]{6})"\)/g)];
  assert.ok(fallbacks.length, "the office reads tokens; it must carry fallbacks");
  for (const [, token, value] of fallbacks) {
    if (token.startsWith("--chat-hue-")) continue;
    assert.equal(value, tokens[token],
      `office fallback for ${token} must be the day face ${tokens[token]}, not ${value}`);
  }
});

test("a peer is one of the eight enamels, not a hue wheel", () => {
  const utils = readFileSync(join(here, "core", "utils.js"), "utf8");
  const peer = /export function peerColor\([^)]*\)\s*\{[^}]*\}/.exec(utils);

  assert.ok(peer, "utils.js must keep peerColor");
  assert.match(peer[0], /themeToken\("--chat-hue-"/,
    "peerColor must read a --chat-hue-N enamel, so a name is one colour in every view");
  assert.doesNotMatch(peer[0], /hsl\(/, "a private hue wheel is a second identity for the same people");

  // The 3D stage lit the same names through the same helper, so a combatant
  // is one colour in both stages; it painted a raw hue through three instead.
  const arena3d = readFileSync(join(pluginsDir, "arena3d", "app.js"), "utf8");

  assert.match(arena3d, /new THREE\.Color\(peerColor\(/,
    "arena3d must build its lit materials from peerColor");
  assert.doesNotMatch(arena3d, /setHSL\(/, "three must not re-derive a name's colour at its own lightness");

  // Every canvas that paints a peer reads the same eight, so neither arena
  // nor the fleet can drift from the board's avatars.
  for (const [name, src] of scripts()) {
    for (const line of src.split("\n")) {
      if (/fillStyle|strokeStyle|\.background\s*=/.test(line) && /hsl/i.test(line)) {
        assert.fail(`${name}: a canvas paints a name with its own hue: ${line.trim().slice(0, 72)}`);
      }
    }
  }
});

test("a glyph is a stroked path on the one grid, never a filled shape set beside it", () => {
  // The file browser carried a private icon set: filled octicon shapes on a
  // 16-unit grid, sitting beside the page's 24-unit 1.75 monoline grid. One
  // column of the same list was then drawn at a different size, weight and fill
  // than every other glyph here, which is what makes a set read as a drop-in
  // rather than as this product's. Filled-glyph data is the tell: the cabinet
  // strokes, so a path painted with currentColor is a foreign grammar and has no
  // business beside it. (A marker head or a chart canvas is not a glyph, so this
  // asks only about path fill, never about a viewBox.)
  const strays = [];
  for (const [name, src] of scripts()) {
    src.split("\n").forEach((line, i) => {
      if (/setAttribute\("fill",\s*"currentColor"/.test(line)) {
        strays.push(`${name}:${i + 1}  filled glyph instead of a stroked path`);
      }
    });
  }
  assert.deepEqual(strays, [], `glyphs are stroked paths, not a second icon set:\n${strays.join("\n")}`);

  // And the file browser must actually be drawing its rows with the shared
  // helper rather than having quietly kept a private one.
  const files = readFileSync(join(pluginsDir, "files", "app.js"), "utf8");
  assert.match(files, /api\.icon\(kindOf\(/, "the file browser draws its rows with the shared grid");
});