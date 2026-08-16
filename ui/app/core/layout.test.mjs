// Parses the shipped stylesheet: Chat and operator views fill the main
// column, and Chat's header / transcript / composer stay the same width.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "..", "app.css"), "utf8");

function ruleBody(selector) {
  const needle = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(needle + "\\s*\\{([^}]+)\\}");
  const m = css.match(re);
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

  const main = ruleBody("main.pf-v6-c-page__main");
  const mainMax = decl(main, "max-width");
  if (mainMax) assert.ok(fillsColumn(mainMax), "main should fill, got " + mainMax);
});

test("Chat header, transcript and composer share the full column width", function () {
  const headerMax = decl(ruleBody("#view-chat .conversation-header"), "max-width");
  const composerMax = decl(ruleBody("#view-chat .composer"), "max-width");
  assert.ok(fillsColumn(headerMax), "Chat header should fill, got " + headerMax);
  assert.ok(fillsColumn(composerMax), "Chat composer should fill, got " + composerMax);
  assert.equal(headerMax, composerMax);

  const combined = /#view-chat \.conversation-scroll \.transcript[\s\S]{0,160}max-width:\s*([^;]+)/.exec(css);
  assert.ok(combined, "Chat transcript must set max-width");
  assert.equal(combined[1].trim(), headerMax);
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

  const pre = ruleBody(".code-block pre");
  assert.equal(decl(pre, "background"), "var(--code-bg)");
  assert.equal(decl(pre, "color"), "var(--code-fg)");
  assert.match(ruleBody(".md pre code, .code-block pre code"), /background:\s*none/);
});

test("Rooms log fills the pane instead of a leftover 24rem box", function () {
  const log = /#view-rooms[\s\S]{0,400}\.chat-log\s*\{([^}]+)\}|\.chat-log\s*\{([^}]+)\}/.exec(css);
  assert.ok(log, "missing .chat-log rule");
  const body = log[1] || log[2];
  assert.match(body, /flex:\s*1/);
  assert.doesNotMatch(body, /max-height:\s*24rem/);
});
