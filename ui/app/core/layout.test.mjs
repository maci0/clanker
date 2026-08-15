// Parses the shipped stylesheet: operator views must not share Chat's
// short centered reading cap.
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

test("operator sections do not share Chat's short centered cap", function () {
  const section = ruleBody(".view > section");
  const sectionMax = decl(section, "max-width");
  assert.ok(sectionMax, ".view > section must set max-width");
  assert.match(sectionMax, /^(none|100%|unset|initial)$/);

  const chatHeader = ruleBody("#view-chat .conversation-header");
  const chatComposer = ruleBody("#view-chat .composer");
  const chatMax = decl(chatHeader, "max-width");
  const composerMax = decl(chatComposer, "max-width");
  assert.ok(chatMax, "Chat header needs a reading measure");
  assert.ok(composerMax, "Chat composer needs a reading measure");
  assert.notEqual(chatMax, "none");
  assert.notEqual(composerMax, "none");
  assert.equal(chatMax, composerMax);
  assert.notEqual(sectionMax, chatMax);

  const main = ruleBody("main.pf-v6-c-page__main");
  const mainMax = decl(main, "max-width");
  if (mainMax) assert.match(mainMax, /^(none|100%|unset|initial)$/);
});

test("Chat transcript keeps the same reading measure as the header", function () {
  const headerMax = decl(ruleBody("#view-chat .conversation-header"), "max-width");
  const transcriptBlock = ruleBody("#view-chat .conversation-scroll .transcript,\n#view-chat .conversation-scroll .run-empty")
    || "";
  // Combined selector in the shipped file; fall back to a substring search
  // if the extractor only saw the first half.
  const combined = /#view-chat \.conversation-scroll \.transcript[\s\S]{0,120}max-width:\s*([^;]+)/.exec(css);
  assert.ok(combined, "Chat transcript must set max-width");
  assert.equal(combined[1].trim(), headerMax);
});
