// Drives the shipped hidden-form and primary-button rules. A PF form class
// on a [hidden] node paints it; a bare button must not be an accent pill.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "..", "app.css"), "utf8");
const html = readFileSync(join(here, "..", "index.html"), "utf8");
const uiSrc = readFileSync(join(here, "ui.js"), "utf8");

function ruleBody(selector) {
  const needle = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(needle + "\\s*\\{([^}]+)\\}");
  const m = css.match(re);
  assert.ok(m, "missing rule for " + selector);
  return m[1];
}

function loadUpgradePfForm() {
  const m = /export function upgradePfForm\(el\) \{([\s\S]*?)\n\}/.exec(uiSrc);
  assert.ok(m, "upgradePfForm missing from ui.js");
  return new Function("el", m[1]);
}

test("card-form stays in the tree as a hidden compatibility form", function () {
  assert.match(html, /id="card-form"[^>]*\bhidden\b|id="card-form" hidden/);
});

test("author CSS hides a hidden form so PF display cannot leak it", function () {
  const body = ruleBody("form[hidden]");
  assert.match(body, /display:\s*none/);
});

test("upgradePfForm does not stamp pf-v6-c-form onto a hidden form", function () {
  const upgradePfForm = loadUpgradePfForm();
  var added = null;
  upgradePfForm({
    tagName: "FORM",
    hidden: true,
    hasAttribute: function (n) { return n === "hidden"; },
    classList: {
      contains: function () { return false; },
      add: function (c) { added = c; },
    },
  });
  assert.equal(added, null);

  added = null;
  upgradePfForm({
    tagName: "FORM",
    hidden: false,
    hasAttribute: function () { return false; },
    classList: {
      contains: function () { return false; },
      add: function (c) { added = c; },
    },
  });
  assert.equal(added, "pf-v6-c-form");
});

test("accent pill is primary/#submit only, not every unmarked button", function () {
  assert.doesNotMatch(
    css,
    /button:where\(:not\(\.pf-v6-c-button\)\)\s*\{[^}]*background:\s*var\(--accent\)/,
  );
  const primary = ruleBody("button.primary:where(:not(.pf-v6-c-button)),\n#submit:where(:not(.pf-v6-c-button))");
  assert.match(primary, /background:\s*var\(--accent\)/);
});
