// Drives the shipped loadSkills over the DOM stub. The forEach callback used
// to shadow the #skills container with the row's checkbox, so every card was
// appended into its own checkbox (a hierarchy cycle the DOM refuses) and the
// panel rendered "Could not load skills." whenever at least one skill existed.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, test } from "node:test";
import { installDom } from "../lib/dom-stub.mjs";

let restoreDom;

before(function () { restoreDom = installDom(); });

after(function () { restoreDom(); });

const here = dirname(fileURLToPath(import.meta.url));

const src = readFileSync(join(here, "tools.js"), "utf8");

// The real function text, run against the stub document and a stubbed fetch:
// tools.js imports ui.js, whose vendor import node cannot resolve, so the
// module is not importable here and the shipped source is extracted instead
// (the harden.test.mjs pattern).
// The card's class lists are module constants now, so the slice has to carry
// them: a ReferenceError inside the try reads as "could not load skills".
function shippedLoadSkills(elements, fetchImpl) {
  const m = /(var SKILL_CARD_CLASS = [\s\S]*?)(?=\nvar TOOL_CONFIG_CLASS)/.exec(src);
  const fn = /(function loadSkills\(\) \{[\s\S]*?\n\})/.exec(src);
  assert.ok(m, "the skill card's class constants are missing from tools.js");
  assert.ok(fn, "loadSkills missing from tools.js");
  const doc = Object.create(globalThis.document);
  doc.getElementById = function (id) { return elements[id] || null; };

  const factory = new Function(
    "document", "fetch", "_readJson", "utilFmtBytes", "utilPlural", "showLoadError",
    m[1] + "\n" + fn[1] + "\nreturn loadSkills;"
  );

  return factory(
    doc,
    fetchImpl,
    function (x) { return x; },
    function () { return "1 KB"; },
    function (n, forms) { return n + " " + (forms[new Intl.PluralRules().select(n)] || forms.other); },
    function (el, msg) { elements.loadErrorShown = true; elements.loadErrorMsg = msg; }
  );
}

test("a non-empty skills list renders its cards into #skills", async function () {
  const d = globalThis.document;
  const els = { skills: d.createElement("div"), "skills-status": d.createElement("p") };

  const loadSkills = shippedLoadSkills(els, function () {
    return Promise.resolve({ skills: [
      { name: "review.md", bytes: 1024, enabled: true, description: "how to review" },
      { name: "ship.md", bytes: 2048, enabled: false }
    ] });
  });

  await loadSkills();
  assert.equal(els.loadErrorShown, undefined, "the happy path must not fall into the load-error branch");
  // The card carries the ported class list, which starts with the hook the
  // card has always worn.
  const cards = els.skills.childNodes.filter(function (n) { return (n.className || '').startsWith('border-b border-rule'); });
  assert.equal(cards.length, 2);
  cards.forEach(function (card) {
    assert.equal(card.parentNode, els.skills);
    // The checkbox sits inside the card, never the other way around.
    const check = card.childNodes[0];
    assert.equal(check.tagName, "INPUT");
    assert.equal(check.childNodes.length, 0);
  });
  assert.equal(els["skills-status"].textContent, "2 skills.");
});

test("an empty skills list still renders its empty state", async function () {
  const d = globalThis.document;
  const els = { skills: d.createElement("div"), "skills-status": d.createElement("p") };

  const loadSkills = shippedLoadSkills(els, function () {
    return Promise.resolve({ skills: [] });
  });

  await loadSkills();
  assert.equal(els.loadErrorShown, undefined);
  assert.match(els.skills.textContent, /No skills on file/);
  assert.equal(els["skills-status"].textContent, "No skills.");
});

test("a failed load names the reason, so the reader knows which problem it is", async function () {
  const d = globalThis.document;
  const els = { skills: d.createElement("div"), "skills-status": d.createElement("p") };

  const loadSkills = shippedLoadSkills(els, function () {
    return Promise.reject(new Error("host unreachable"));
  });

  await loadSkills();
  assert.equal(els.loadErrorShown, true, "a rejected fetch must reach the load-error branch");
  // The reason travels with the sentence. "Could not load skills." alone
  // reads the same whether the skills module is switched off or the server is
  // not answering, and those need different things from the reader.
  assert.match(els.loadErrorMsg, /Could not load skills: host unreachable/);
  // The status line mirrors the panel rather than saying a shorter second
  // sentence, so the two never disagree about what went wrong.
  assert.equal(els["skills-status"].textContent, els.loadErrorMsg);
});
