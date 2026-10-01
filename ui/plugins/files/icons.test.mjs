// The listing's glyphs come off the one 24-grid the page draws on. That is a
// behavioural contract, not a style one: the view used to carry its own set of
// filled shapes on a 16-unit grid and its own table of file extensions mapped
// onto the state tokens, so one column of the same list was drawn at a
// different size, weight, fill and colour than every other glyph in the app.
//
// A source scan cannot catch a regression here (any of the private helpers can
// come back under a new name), so this mounts the shipped plugin, serves it a
// listing over a minimal DOM, and reads the SVG that actually lands in each row.
import assert from "node:assert/strict";
import { test } from "node:test";

import { ICON_PATHS } from "../../app/core/icons.js";

const ENTRIES = [
  { name: "src", is_dir: true },
  { name: "main.zig", is_dir: false },
  { name: "notes.md", is_dir: false },
  { name: "config.json", is_dir: false },
  { name: "LICENSE", is_dir: false },
];

/// Every element under `el`, at any depth.
function* descendants(el) {
  for (const child of el.children ?? []) {
    yield child;
    yield* descendants(child);
  }
}

/// Just enough DOM for the view to build itself and paint a listing.
function dom() {
  class El {
    constructor(tag) {
      this.tagName = tag.toUpperCase();
      this.children = [];
      this.attributes = {};
      this.dataset = {};
      this.style = {};
      this.classList = {
        add: (...c) => El.list(this.className).push(...c),
        remove: () => {},
        contains: () => false,
      };
      this.className = "";
      this.textContent = "";
      this.hidden = false;
      this.disabled = false;
    }

    set textContent(v) { this.children = []; this._text = String(v); }
    get textContent() {
      return this._text ?? this.children.map((c) => c.textContent ?? "").join("");
    }

    setAttribute(k, v) { this.attributes[k] = String(v); }
    getAttribute(k) { return this.attributes[k] ?? null; }
    removeAttribute(k) { delete this.attributes[k]; }
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
    append(...kids) { kids.forEach((k) => this.appendChild(k)); }
    addEventListener() {}
    removeEventListener() {}
    querySelector() { return null; }
    querySelectorAll() { return []; }
    focus() {}
    matches() { return false; }
    click() {}
    get innerHTML() { return ""; }
    set innerHTML(v) { this.children = []; }
  }

  El.list = (s) => (s ? String(s).split(/\s+/).filter(Boolean) : []);

  const registry = {};
  return {
    El,
    registry,
    document: {
      createElement: (t) => new El(t),
      createElementNS: (_ns, t) => new El(t),
      createTextNode: (t) => ({ nodeType: 3, textContent: String(t), children: [] }),
      getElementById: () => null,
      querySelector: () => null,
      addEventListener: () => {},
    },
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    HTMLElement: El,
  };
}

/// Mounts the shipped plugin and returns the SVGs it painted into the listing.
async function renderedGlyphs() {
  const { document, HTMLElement, registry } = dom();

  // The plugin reads these as globals at module scope and inside mount.
  globalThis.document = document;
  globalThis.window = { location: { search: "" }, addEventListener: () => {} };
  globalThis.clanker = {
    registerView: (v) => { registry[v.id] = v; },
    registerTool: () => {},
    register: () => {},
  };

  await import(`./app.js?glyphs=${Date.now()}`);

  const view = registry.files;
  assert.ok(view, "the Files view registered");

  const api = {
    icon: (name, size) => {
      const svg = document.createElement("svg");
      svg.setAttribute("viewBox", "0 0 24 24");
      svg.setAttribute("stroke", "currentColor");
      svg.setAttribute("stroke-width", "1.75");
      svg.setAttribute("fill", "none");
      svg.setAttribute("width", String(size ?? 16));
      svg.setAttribute("class", "icon");
      svg.dataset.glyph = name;
      for (const d of ICON_PATHS[name] ?? []) {
        const p = document.createElement("path");
        p.setAttribute("d", d);
        svg.appendChild(p);
      }
      return svg;
    },
    fmt: {
      bytes: (n) => `${n} B`,
      plural: (n, o) => (n === 1 ? o.one : o.other),
      time: (ms) => String(ms ?? 0),
      ago: () => "just now",
      fold: (s) => String(s ?? "").toLowerCase(),
      compare: (a, b) => String(a).localeCompare(String(b)),
    },
    workspace: () => null,
    status: () => {},
    getJSON: () => Promise.resolve({
      path: "", root: "workspace", parent: "", at_root: true, entries: ENTRIES,
    }),
    render: { markdown: () => document.createElement("div"), code: () => document.createElement("pre") },
  };

  const container = document.createElement("div");
  await view.mount(container, api);

  const list = descendants(container)
    .find((el) => el.getAttribute?.("role") === "listbox");

  assert.ok(list, "the listing rendered");

  const glyphs = [];
  for (const row of list.children ?? []) {
    const iconCell = row.children?.[0];
    const svg = iconCell?.children?.find((c) => c.tagName === "SVG");
    if (!svg) continue;
    const name = descendants(row)
      .map((el) => el.textContent)
      .find((t) => t && t !== "");
    glyphs.push({ name: name ?? "", svg });
  }
  return glyphs;
}

test("a listing row's glyph is a stroked path on the shared 24-grid", async () => {
  const glyphs = await renderedGlyphs();

  assert.equal(glyphs.length, ENTRIES.length, "every entry painted a glyph");

  for (const { name, svg } of glyphs) {
    assert.equal(svg.getAttribute("viewBox"), "0 0 24 24", `${name}: the shared grid, not a private one`);
    assert.equal(svg.getAttribute("fill"), "none", `${name}: stroked, not filled`);
    assert.equal(svg.getAttribute("stroke"), "currentColor", `${name}: takes the row's colour`);
    assert.equal(svg.getAttribute("stroke-width"), "1.75", `${name}: the one stroke weight`);
    assert.ok(svg.children.length > 0, `${name}: the glyph drew path data`);
    assert.ok(ICON_PATHS[svg.dataset.glyph], `${name}: "${svg.dataset.glyph}" is a drawn icon`);
  }
});

test("a listing row's colour is the row's colour, not a state reading", async () => {
  const glyphs = await renderedGlyphs();

  // The defect was a table of extensions painted with --ok/--warn/--danger, so
  // an ordinary Ruby or shell file arrived red or green. A glyph must never
  // carry an inline colour of its own.
  for (const { name, svg } of glyphs) {
    assert.equal(svg.style?.color, undefined, `${name}: no inline colour on the glyph`);
    assert.equal(svg.attributes.style, undefined, `${name}: no style attribute on the glyph`);
  }
});

test("the kinds a listing distinguishes are shapes drawn for this purpose", async () => {
  const glyphs = await renderedGlyphs();
  const kindOf = (file) => glyphs.find((g) => g.name === file)?.svg.dataset.glyph;

  assert.equal(kindOf("src"), "folder", "a directory");
  assert.equal(kindOf("main.zig"), "code", "source");
  assert.equal(kindOf("notes.md"), "text", "prose");
  assert.equal(kindOf("config.json"), "code", "structured data the viewer highlights");
  assert.equal(kindOf("LICENSE"), "file", "everything else");
});
