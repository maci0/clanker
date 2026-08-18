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
