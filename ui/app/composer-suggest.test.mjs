// The composer's three suggestion lists (`/` prompts, `@` files, `#` knowledge
// collections) all render into one `#prompt-list` listbox owned by the
// `#task-combobox` wrapper, whose `aria-expanded` and `#task`'s
// `aria-activedescendant` are the two halves of "a list is open".
// `hidePromptList()` is the single place that says "no list is open" — and the
// `@` and `#` renderers used to bypass it, flipping `hidden` by hand:
//
//   * the `@` list opened with `aria-expanded="false"` still on the combobox,
//     so a screen reader was never told the popup was there at all;
//   * dismissing the `#` list left `aria-expanded="true"` and an
//     `aria-activedescendant` pointing at an option that was no longer shown.
//
// Both renderers also fired one listing per keystroke with no ordering, so a
// slow reply could paint over a newer query, and swallowed every failure into
// an empty `catch` that left whatever was on screen there.
//
// The functions live at the top level of `app.js`, which imports the whole
// /webui module graph, so — the same way `features/arena.test.mjs` drives
// `ensure3d` — they are lifted out of the shipped source and run in a vm over
// stubs. Nothing is rewritten: the source text is executed verbatim.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(here, "app.js"), "utf8");

function slice(startNeedle, endNeedle) {
  const from = js.indexOf(startNeedle);
  assert.ok(from >= 0, startNeedle + " is still in app.js");
  const to = js.indexOf(endNeedle, from);
  assert.ok(to > from, endNeedle + " still follows " + startNeedle);
  return js.slice(from, to);
}

const fileSrc = slice("function fileMentionQuery() {", "// ---- session status bar");
const hideSrc = slice("function hidePromptList() {", "function runSlashModel(");
const kbSrc = slice("var kbMentionActive = false;", "// Integrated input handler");

// ---------- a DOM with only what these functions touch ----------
function elem(tag) {
  const e = {
    tagName: (tag || "").toUpperCase(),
    id: "",
    className: "",
    hidden: true,
    value: "",
    childNodes: [],
    attrs: {},
    listeners: {},
    appendChild(c) { this.childNodes.push(c); return c; },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    addEventListener(t, f) { this.listeners[t] = f; },
    focus() {},
  };
  let text = "";
  Object.defineProperty(e, "textContent", {
    get() { return text || this.childNodes.map((c) => c.textContent || "").join(""); },
    set(v) { text = String(v == null ? "" : v); this.childNodes = []; },
  });
  return e;
}

function deferred() {
  let settle;
  const p = new Promise((res, rej) => { settle = { res, rej }; });
  return { promise: p, ...settle };
}

// One harness for both lists: `fetches` records every request so a test can
// answer them out of order.
function harness(taskValue) {
  const task = elem("textarea");
  const taskCombobox = elem("div");
  const promptList = elem("ul");
  task.value = taskValue;
  taskCombobox.attrs.role = "combobox";
  taskCombobox.attrs["aria-expanded"] = "false";
  taskCombobox.appendChild(task);
  taskCombobox.appendChild(promptList);
  const fetches = [];
  const ctx = {
    el: { task, taskCombobox, promptList },
    pendingFiles: [],
    renderFileChips() {},
    kbSelected: [],
    document: {
      createElement: elem,
      getElementById: () => null,
    },
    window: { localStorage: { setItem() {}, getItem() { return null; } } },
    fetch(url) {
      const d = deferred();
      fetches.push({ url, reply: (data) => d.res({ json: () => Promise.resolve(data) }), fail: () => d.rej(new Error("offline")) });
      return d.promise;
    },
    console,
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(hideSrc + "\n" + fileSrc + "\n" + kbSrc, ctx);
  return { ctx, task, taskCombobox, promptList, fetches };
}

const settle = () => new Promise((r) => setImmediate(r));

test("the @ file list tells the combobox it opened", async function () {
  const h = harness("look at @sr");
  assert.equal(h.ctx.renderFileMentionList(), true);
  h.fetches[0].reply({ entries: ["src", "srv"] });
  await settle();
  assert.equal(h.promptList.hidden, false, "the list is shown");
  assert.equal(
    h.taskCombobox.getAttribute("aria-expanded"), "true",
    "the combobox must say the listbox is open; it used to stay 'false' for the whole @ flow"
  );
  assert.equal(h.task.getAttribute("aria-activedescendant"), "prompt-item-0");
  assert.equal(h.promptList.childNodes.length, 2);
  assert.equal(h.promptList.childNodes[0].id, "prompt-item-0");
  assert.equal(h.promptList.childNodes[0].getAttribute("aria-selected"), "true");
});

test("picking a file closes the list and clears the ARIA state", async function () {
  const h = harness("look at @sr");
  h.ctx.renderFileMentionList();
  h.fetches[0].reply({ entries: ["src"] });
  await settle();
  h.promptList.childNodes[0].listeners.mousedown({ preventDefault() {} });
  assert.equal(h.promptList.hidden, true);
  assert.equal(h.taskCombobox.getAttribute("aria-expanded"), "false");
  assert.equal(h.task.getAttribute("aria-activedescendant"), null);
  assert.deepEqual(h.ctx.pendingFiles, ["src"]);
});

test("an empty listing closes the list instead of leaving it open", async function () {
  const h = harness("look at @zzz");
  h.ctx.renderFileMentionList();
  h.fetches[0].reply({ entries: ["src"] });
  await settle();
  assert.equal(h.promptList.hidden, true);
  assert.equal(h.taskCombobox.getAttribute("aria-expanded"), "false");
});

test("a failed listing says nothing stale: the list closes", async function () {
  const h = harness("look at @sr");
  h.ctx.renderFileMentionList();
  h.fetches[0].reply({ entries: ["src", "srv"] });
  await settle();
  assert.equal(h.promptList.hidden, false);
  // Another keystroke, and this time the listing fails.
  h.task.value = "look at @srv";
  h.ctx.renderFileMentionList();
  h.fetches[1].fail();
  await settle();
  assert.equal(h.promptList.hidden, true, "an empty catch used to leave the previous list on screen");
  assert.equal(h.taskCombobox.getAttribute("aria-expanded"), "false");
});

test("a slow listing cannot paint over a newer query", async function () {
  const h = harness("look at @sr");
  h.ctx.renderFileMentionList();          // request 0 — dir ".", needle "sr"
  h.task.value = "look at @src/f";
  h.ctx.renderFileMentionList();          // request 1 — dir "src", needle "f"
  assert.equal(h.fetches.length, 2);
  h.fetches[1].reply({ entries: ["file.zig"] });
  await settle();
  h.fetches[0].reply({ entries: ["srOLD"] });   // would still match needle "sr"
  await settle();
  const shown = h.promptList.childNodes.map((n) => n.textContent);
  assert.deepEqual(shown, ["src/file.zig"], "the stale reply must not redraw the list");
});

test("dismissing the # list does not leave #task claiming to be expanded", async function () {
  const h = harness("recall #zi");
  h.ctx.renderKbMentionList();
  h.fetches[0].reply({ collections: [{ id: "zig", title: "zig", doc_count: 3 }] });
  await settle();
  assert.equal(h.taskCombobox.getAttribute("aria-expanded"), "true");
  assert.equal(h.ctx.kbMentionActive, true);

  // Pick the collection. Nothing else fires afterwards — the composer's value
  // is rewritten in code, so no `input` event comes along to tidy up.
  h.promptList.childNodes[0].listeners.mousedown({ preventDefault() {} });
  assert.equal(h.promptList.hidden, true);
  assert.equal(
    h.taskCombobox.getAttribute("aria-expanded"), "false",
    "aria-expanded latched 'true' for the rest of the session after one # pick"
  );
  assert.equal(
    h.task.getAttribute("aria-activedescendant"), null,
    "aria-activedescendant kept pointing at an option that is no longer shown"
  );
  assert.equal(h.ctx.kbMentionActive, false);
});

test("hidePromptList is the only place that hides the suggestion list", function () {
  // Every renderer must close through the one function that also resets the
  // ARIA state and the mention flags. Two of them used to flip `hidden` by
  // hand, which is how the state above went stale.
  const hides = js.match(/promptList\.hidden\s*=\s*true/g) || [];
  assert.equal(hides.length, 1, "found a promptList.hidden = true outside hidePromptList()");
  assert.match(hideSrc, /el\.taskCombobox\.setAttribute\("aria-expanded"/);
  assert.match(hideSrc, /removeAttribute\("aria-activedescendant"\)/);
});

test("aria-expanded is set on the combobox wrapper and never on the textarea", function () {
  // The two halves of "a list is open" live on two elements, so they go through
  // one helper: four renderers and hidePromptList, five call sites plus the
  // definition. A sixth list that sets the attribute by hand is the regression.
  const calls = js.match(/setPromptListOpen\(/g) || [];
  assert.ok(calls.length >= 6, "setPromptListOpen has a definition and five call sites");
  const strays = js.match(/el\.task\.setAttribute\("aria-expanded"/g) || [];
  assert.equal(
    strays.length, 0,
    "aria-expanded belongs to #task-combobox: ARIA does not allow role=combobox on a textarea"
  );
});

test("the composer is a combobox that owns the textbox and the listbox", function () {
  // The relationship, not the attribute strings: #task must be a plain textarea
  // (implicit role textbox, aria-multiline true) inside an element with
  // role=combobox that also holds the listbox it points at. axe-core 4.13
  // reported the old shape as `aria-allowed-role` on #task.
  const html = readFileSync(join(here, "index.html"), "utf8");

  assert.ok(
    !/<textarea[^>]*role="combobox"/.test(html),
    "no textarea may carry role=combobox; a textarea is already a multi-line textbox"
  );

  const taskTag = html.match(/<textarea[^>]*\bid="task"[^>]*>/);
  assert.ok(taskTag, "#task is still a textarea");
  assert.ok(!/\brole=/.test(taskTag[0]), "#task keeps its implicit textbox role");
  assert.ok(!/aria-expanded/.test(taskTag[0]), "the popup state is the combobox's, not the textbox's");
  assert.match(taskTag[0], /aria-autocomplete="list"/);
  assert.match(taskTag[0], /aria-controls="prompt-list"/);
  // Its accessible name still comes from the composer's own label.
  assert.match(html, /<label for="task">/);

  const openAt = html.search(/<div[^>]*\bid="task-combobox"/);
  assert.ok(openAt >= 0, "the combobox wrapper is in the page");
  const openTag = html.slice(openAt).match(/<div[^>]*>/)[0];
  assert.match(openTag, /role="combobox"/);
  assert.match(openTag, /aria-expanded="false"/);
  assert.match(openTag, /aria-haspopup="listbox"/);
  assert.match(openTag, /aria-owns="prompt-list"/);

  // Containment is what makes the wrapper own both, so a browser that ignores
  // aria-owns still reads the same tree.
  const inner = html.slice(openAt, html.indexOf("</div>", openAt));
  assert.match(inner, /<textarea[^>]*\bid="task"/, "the textbox is inside the combobox");
  assert.match(inner, /<ul[^>]*\bid="prompt-list"[^>]*role="listbox"/, "so is the listbox it points at");
});
