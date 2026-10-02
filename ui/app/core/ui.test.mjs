import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { installDom, serialize } from "../lib/dom-stub.mjs";

// The two list states a panel reports: "loaded, and there is nothing" and
// "could not load". Both are what the chat pins panel needs and neither is a
// one-liner at the call site, so both live here and both are tested against
// the DOM the page builds rather than against their source text.
//
// ui.js imports the vendored signals module by URL, which node cannot
// resolve, so the two functions are lifted out of the file and run against
// the shared stub document.
const here = dirname(fileURLToPath(import.meta.url));

async function loadUi() {
  const src = readFileSync(join(here, "ui.js"), "utf8");
  const wanted = /export function (showEmptyState|showLoadError)\b[\s\S]*?\n}\n/g;
  const lifted = src.match(wanted).join("\n").replace(/^export /gm, "")
    + "\nexport { showEmptyState, showLoadError };\n";
  return import("data:text/javascript;base64," + Buffer.from(lifted).toString("base64"));
}

test("an empty panel says what to do next, in the shared empty shape", async function () {
  const restore = installDom();

  try {
    const ui = await loadUi();
    const panel = document.createElement("div");
    panel.textContent = "Loading…";

    ui.showEmptyState(panel, "No pins here yet. Pin one from a message menu.");

    // `.run-empty` and not an inline colour: this is the one empty shape the
    // page already has, and a hand-rolled copy renders differently.
    assert.equal(panel.childNodes[0].className, "run-empty");
    assert.equal(serialize(panel),
      '<div><p class="run-empty">No pins here yet. Pin one from a message menu.</p></div>');
  } finally {
    restore();
  }
});

test("a failed panel names the reason and offers a retry that reruns the fetch", async function () {
  const restore = installDom();

  try {
    const ui = await loadUi();
    const panel = document.createElement("div");
    let tries = 0;

    ui.showLoadError(panel, "Could not load pins: server said no", function () {
      tries += 1;
    });

    assert.match(serialize(panel), /Could not load pins: server said no/);
    const retry = panel.childNodes[0].childNodes.find((c) => c.tagName === "BUTTON");
    assert.equal(retry.textContent, "Try again");
    // The retry is what a user has instead of closing and reopening the
    // panel, so it has to actually call back into the loader.
    retry.listeners.click[0]();
    assert.equal(tries, 1);
  } finally {
    restore();
  }
});

test("the retry is disabled while it runs and enabled again either way", async function () {
  const restore = installDom();

  try {
    const ui = await loadUi();
    const panel = document.createElement("div");

    ui.showLoadError(panel, "Could not load.", function () { return Promise.reject(new Error("still down")); });
    const retry = panel.childNodes[0].childNodes.find((c) => c.tagName === "BUTTON");

    retry.listeners.click[0]();
    assert.equal(retry.disabled, true, "disabled while the retry is in flight");
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(retry.disabled, false, "re-enabled after a failed retry, so a second try is possible");
  } finally {
    restore();
  }
});
