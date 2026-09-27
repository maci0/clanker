// Parses the shipped stylesheet: Chat and operator views fill the main
// column, and Chat's header / transcript / composer stay the same width.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
// These assertions are about shipped layout; the cabinet sheet is the one left.
const css = readFileSync(join(here, "..", "app.css"), "utf8");
// The rendered document's shapes are a component block in the Tailwind source.
const doc = readFileSync(join(here, "..", "tailwind.src.css"), "utf8");

function ruleBody(selector, sheet) {
  const needle = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(needle + "\\s*\\{([^}]+)\\}");
  const m = (sheet || css).match(re);
  assert.ok(m, "missing rule for " + selector);
  return m[1];
}

function decl(body, prop) {
  const re = new RegExp("(?:^|;)\\s*" + prop.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*:\\s*([^;]+)");
  const m = body.match(re);
  return m ? m[1].trim() : "";
}

function fillsColumn(maxWidth) {
  return /^(none|100%|unset|initial)$/.test(maxWidth);
}

test("operator sections fill the main column", function () {
  const section = ruleBody(".view > section");
  const sectionMax = decl(section, "max-width");
  assert.ok(sectionMax, ".view > section must set max-width");
  assert.ok(fillsColumn(sectionMax), ".view > section should fill the column, got " + sectionMax);

  const main = ruleBody("main");
  const mainMax = decl(main, "max-width");
  assert.ok(mainMax, "main must set max-width");
  assert.ok(fillsColumn(mainMax), "main should fill, got " + mainMax);
});

test("Chat header, transcript and composer share the full column width", function () {
  // The chat column's widths are utilities on the view element now, so the
  // guard reads the markup: the three parts share one list and none of them
  // clamps itself.
  const html = readFileSync(join(here, "..", "index.html"), "utf8");
  const view = /<div class="([^"]*)" id="view-chat"/.exec(html);
  assert.ok(view, "missing the chat view's class list");
  for (const part of ["[&_.conversation-header]", "[&_.composer]", "[&_.suggestions]"]) {
    assert.match(view[1], new RegExp(part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), "Chat " + part + " must be sized by the view");
  }
  const combined = /\[&_\.conversation-scroll_\.transcript\]:max-w-none/.exec(view[1]);
  assert.ok(combined, "Chat transcript must fill the column");
});

const THEME_NAMES = [
  "light", "dark", "mocha", "latte", "frappe", "macchiato",
  "tokyonight", "tokyonight-storm", "tokyonight-day", "hackerman",
];
const LIGHT_THEMES = new Set(["light", "latte", "tokyonight-day"]);
const GITHUB_DARK_WELL = /#0d1117|#1a1e24/i;
const themesDir = join(here, "..", "..", "..", "themes");

function themeTokens(name) {
  const rec = JSON.parse(readFileSync(join(themesDir, name + ".json"), "utf8"));
  assert.ok(rec.tokens, "missing tokens for " + name);
  return rec.tokens;
}

test("every named theme owns a code well in the page luminance family", function () {
  assert.doesNotMatch(css, /:root\[data-theme=/, "named palettes live in themes/*.json, not app.css");
  for (const name of THEME_NAMES) {
    const tokens = themeTokens(name);
    const bg = tokens["--code-bg"];
    const fg = tokens["--code-fg"];
    assert.ok(bg, name + " must set --code-bg");
    assert.ok(fg, name + " must set --code-fg");
    if (LIGHT_THEMES.has(name)) {
      assert.doesNotMatch(bg, GITHUB_DARK_WELL, name + " must not keep the GitHub-dark well, got " + bg);
    }
  }

  const root = css.match(/:root\s*\{([\s\S]*?)\n\}/);
  assert.ok(root, "missing :root token block");
  const rootBg = decl(root[1], "--code-bg");
  assert.doesNotMatch(rootBg, GITHUB_DARK_WELL, ":root default well must follow the light cabinet, got " + rootBg);

  const pre = ruleBody(".code-block pre", doc);
  assert.equal(decl(pre, "background"), "var(--code-bg)");
  assert.equal(decl(pre, "color"), "var(--code-fg)");
  assert.match(ruleBody(".md pre code, .code-block pre code", doc), /background:\s*none/);
});

test("Rooms log fills the pane instead of a leftover 24rem box", function () {
  // The log is utilities in the markup now, so the guard reads the markup: it
  // grows, and no leftover max-height boxes it in.
  const html = readFileSync(join(here, "..", "index.html"), "utf8");
  const m = /id="chat-log"[^>]*/.exec(html) || /class="([^"]*)"[^>]*id="chat-log"/.exec(html);
  const tag = /<div class="([^"]*)" id="chat-log"/.exec(html);
  assert.ok(tag, "missing the rooms log's class list");
  assert.match(tag[1], /\bflex-1\b/);
  assert.doesNotMatch(tag[1], /max-h-\[24rem\]/);
});

// The favicon is the identity in 32 pixels: a panel plate, a machined bezel,
// a lit lamp dome, a legend plate. It was drawn from the cabinet's shapes but
// painted in GitHub-dark's chrome (#0d1117 plate, #555c67 slate bezel) beside
// a green that was already the --ok token, so the one asset that carries the
// mark used two greys the palette does not contain and that run cool against
// its warm RAL family. The code wells were purged of the same borrowed
// palette; this pins the mark to it too.
test("the favicon mark is painted from the cabinet palette", function () {
  const html = readFileSync(join(here, "..", "index.html"), "utf8");
  const icon = /<link rel="icon" href="([^"]+)"/.exec(html);
  assert.ok(icon, "missing favicon");
  const svg = decodeURIComponent(icon[1]);
  assert.doesNotMatch(svg, GITHUB_DARK_WELL, "the mark must not carry GitHub-dark chrome");

  // Every fill and stroke in the mark is a colour the sheet declares, so the
  // mark cannot drift away from the palette one hex at a time.
  const root = css.match(/:root\s*\{([\s\S]*?)\n\}/)[1];
  const dark = css.match(/:root:not\(\[data-theme\]\)\s*\{([\s\S]*?)\n  \}/);
  const declared = new Set(
    [...root.matchAll(/#[0-9a-fA-F]{6}\b/g), ...(dark ? dark[1].matchAll(/#[0-9a-fA-F]{6}\b/g) : [])]
      .map((m) => m[0].toLowerCase()),
  );
  // The dome's specular highlight; the same white the --lamp-dome token uses.
  declared.add("#ffffff");
  // A warm grey between --border and --fg-muted: the engraved bezel and
  // legend plate, which need to read against the plate at 16px.
  declared.add("#5c625b");
  for (const m of svg.matchAll(/#[0-9a-fA-F]{6}\b/g)) {
    assert.ok(declared.has(m[0].toLowerCase()), `mark uses ${m[0]}, which the palette does not declare`);
  }
});
