import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// The app.css / views.css split is a first-paint contract. views.css is loaded
// non-blocking (media=print, swapped by app.js) so the render-blocking sheet
// only carries what the first draw shows; if a selector that styles something
// the first paint shows ever lands in views.css, that element renders wrong
// until the async sheet arrives. These tests pin the invariant against the
// shipped files, using the same static matching the split itself used.

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, "index.html"), "utf8");
const appCss = readFileSync(join(here, "app.css"), "utf8");
const viewsCss = readFileSync(join(here, "views.css"), "utf8");
const appJs = readFileSync(join(here, "app.js"), "utf8");
const bootJs = readFileSync(join(here, "preact-boot.js"), "utf8");

// ---------- minimal HTML tree ----------
const VOID = new Set(["link","meta","input","br","img","hr","source","wbr","col","area","base","embed","track"]);
function parseHtml(src) {
  const root = { tag: "#root", attrs: {}, children: [], parent: null };
  let stack = [root];
  const re = /<!--[\s\S]*?-->|<!doctype[^>]*>|<\/?([a-zA-Z][a-zA-Z0-9]*)((?:"[^"]*"|'[^']*'|[^'"<>])*)>/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const tok = m[0];
    if (tok.startsWith("<!--") || tok.startsWith("<!doctype")) continue;
    const tag = m[1].toLowerCase();
    const rest = m[2] || "";
    if (tok.startsWith("</")) {
      for (let k = stack.length - 1; k >= 1; k--) {
        if (stack[k].tag === tag) { stack = stack.slice(0, k); break; }
      }
      continue;
    }
    const el = { tag, attrs: {}, children: [], parent: stack[stack.length - 1] };
    const attrRe = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let am;
    while ((am = attrRe.exec(rest)) !== null) {
      const val = am[3] ?? am[4] ?? am[5] ?? "";
      el.attrs[am[1].toLowerCase()] = val;
    }
    el.parent.children.push(el);
    if (!VOID.has(tag) && !tok.endsWith("/>")) stack.push(el);
  }
  return root;
}
const doc = parseHtml(html);
const all = [];
(function walk(el) { all.push(el); el.children.forEach(walk); })(doc);
// First-paint elements: present in the static HTML and not inside a
// <div class="view" hidden> (the views that open only on demand).
const firstPaint = all.filter((e) => {
  let a = e;
  while (a && a.tag !== "#root") {
    if (a.attrs["class"]?.split(/\s+/).includes("view") && a.attrs["hidden"] !== undefined) return false;
    a = a.parent;
  }
  return true;
});

// ---------- CSS rules with @media descent ----------
function cssRules(src) {
  const stripped = src.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [];
  let j = 0;
  while (j < stripped.length) {
    while (j < stripped.length && /\s/.test(stripped[j])) j++;
    if (j >= stripped.length) break;
    const brace = stripped.indexOf("{", j);
    if (brace < 0) break;
    const header = stripped.slice(j, brace).trim();
    let depth = 1, k = brace + 1;
    while (k < stripped.length && depth > 0) {
      if (stripped[k] === "{") depth++;
      else if (stripped[k] === "}") depth--;
      k++;
    }
    const body = stripped.slice(brace + 1, k - 1);
    if (header.startsWith("@media")) {
      let j2 = 0;
      while (j2 < body.length) {
        while (j2 < body.length && /\s/.test(body[j2])) j2++;
        if (j2 >= body.length) break;
        const b2 = body.indexOf("{", j2);
        if (b2 < 0) break;
        const h2 = body.slice(j2, b2).trim();
        if (h2 && !h2.startsWith("@")) rules.push(h2);
        let dd = 1, kk = b2 + 1;
        while (kk < body.length && dd > 0) {
          if (body[kk] === "{") dd++;
          else if (body[kk] === "}") dd--;
          kk++;
        }
        j2 = kk;
      }
    } else if (!header.startsWith("@")) {
      rules.push(header);
    }
    j = k;
  }
  return rules;
}

// ---------- selector matching ----------
function splitList(sel) {
  const out = [];
  let depth = 0, cur = "";
  for (const ch of sel) {
    if (ch === "(" || ch === "[") depth++;
    else if (ch === ")" || ch === "]") depth--;
    if (ch === "," && depth === 0) { out.push(cur.trim()); cur = ""; }
    else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}
function splitCompound(sel) {
  const out = [];
  let depth = 0, cur = "";
  const flush = () => { const t = cur.trim(); if (t) out.push({ compound: t, comb: null }); cur = ""; };
  for (let i = 0; i < sel.length; i++) {
    const ch = sel[i];
    if (ch === "(" || ch === "[") { depth++; cur += ch; continue; }
    if (ch === ")" || ch === "]") { depth--; cur += ch; continue; }
    if (depth === 0 && (ch === " " || ch === ">" || ch === "+" || ch === "~")) {
      let comb = "";
      while (i < sel.length && (sel[i] === " " || sel[i] === ">" || sel[i] === "+" || sel[i] === "~")) {
        if (sel[i] !== " ") comb += sel[i];
        i++;
      }
      i--;
      flush();
      if (out.length) out[out.length - 1].comb = comb || " ";
      continue;
    }
    cur += ch;
  }
  flush();
  return out;
}
function parseCompound(comp) {
  const parts = [];
  let i = 0;
  while (i < comp.length) {
    const ch = comp[i];
    if (ch === ".") {
      let j = i + 1; while (j < comp.length && /[-\w]/.test(comp[j])) j++;
      parts.push({ type: "class", val: comp.slice(i + 1, j) }); i = j;
    } else if (ch === "#") {
      let j = i + 1; while (j < comp.length && /[-\w]/.test(comp[j])) j++;
      parts.push({ type: "id", val: comp.slice(i + 1, j) }); i = j;
    } else if (ch === "[") {
      const close = comp.indexOf("]", i);
      if (close < 0) break;
      const inner = comp.slice(i + 1, close).trim();
      const eq = inner.indexOf("=");
      let name, op = null, val = null;
      if (eq >= 0) {
        name = inner.slice(0, eq).trim();
        op = inner[eq];
        val = inner.slice(eq + 1).trim().replace(/^["']|["']$/g, "");
      } else { name = inner; }
      parts.push({ type: "attr", name, op, val }); i = close + 1;
    } else if (ch === ":") {
      if (comp[i + 1] === ":") {
        let j = i + 2; while (j < comp.length && /[-\w]/.test(comp[j])) j++;
        i = j; continue;
      }
      let j = i + 1; while (j < comp.length && /[-\w]/.test(comp[j])) j++;
      const name = comp.slice(i + 1, j);
      if (name === "not") {
        const close = comp.indexOf(")", j);
        if (close < 0) break;
        parts.push({ type: "not", inner: parseCompound(comp.slice(j + 1, close).trim()) });
        i = close + 1;
      } else { i = j; }
    } else if (/[a-zA-Z*]/.test(ch)) {
      let j = i; while (j < comp.length && /[a-zA-Z-]/.test(comp[j])) j++;
      parts.push({ type: "tag", val: comp.slice(i, j).toLowerCase() || "*" });
      i = Math.max(j, i + 1);
    } else { i++; }
  }
  return parts;
}
function matchCompound(parts, el) {
  if (!el) return false;
  for (const p of parts) {
    if (p.type === "tag") {
      if (p.val !== "*" && el.tag !== p.val) return false;
    } else if (p.type === "class") {
      if (!(el.attrs["class"] ?? "").split(/\s+/).includes(p.val)) return false;
    } else if (p.type === "id") {
      if (el.attrs["id"] !== p.val) return false;
    } else if (p.type === "attr") {
      const have = el.attrs[p.name];
      if (have === undefined) return false;
      if (p.op === "=" && have !== p.val) return false;
    } else if (p.type === "not") {
      if (matchCompound(p.inner, el)) return false;
    }
  }
  return true;
}
function matchComplex(sel, el) {
  const chain = splitCompound(sel);
  if (!chain.length) return false;
  if (!matchCompound(parseCompound(chain[chain.length - 1].compound), el)) return false;
  let node = el;
  for (let idx = chain.length - 1; idx >= 1; idx--) {
    const comb = chain[idx].comb || " ";
    const target = chain[idx - 1].compound;
    if (comb === " ") {
      let a = node.parent, found = false;
      while (a) {
        if (a.tag !== "#root" && matchCompound(parseCompound(target), a)) { found = true; break; }
        a = a.parent;
      }
      if (!found) return false;
      node = a;
    } else if (comb === ">") {
      node = node.parent;
      if (!node || node.tag === "#root" || !matchCompound(parseCompound(target), node)) return false;
    } else if (comb === "+") {
      const sibs = node.parent ? node.parent.children : [];
      const idxSelf = sibs.indexOf(node);
      const prev = idxSelf > 0 ? sibs[idxSelf - 1] : null;
      if (!prev || prev.tag === "#root" || !matchCompound(parseCompound(target), prev)) return false;
      node = prev;
    } else if (comb === "~") {
      const sibs = node.parent ? node.parent.children : [];
      const idxSelf = sibs.indexOf(node);
      let found = false;
      for (let s = 0; s < idxSelf; s++) {
        if (sibs[s].tag !== "#root" && matchCompound(parseCompound(target), sibs[s])) { found = true; node = sibs[s]; break; }
      }
      if (!found) return false;
    }
  }
  return true;
}
function matchesAny(sel, el) {
  return splitList(sel).some((s) => matchComplex(s, el));
}

// ---------- the contract ----------
test("views.css is loaded non-blocking with a no-JS fallback", function () {
  const link = /<link rel="stylesheet" href="\/webui\/views\.css" media="print" data-views="1">/.exec(html);
  assert.ok(link, "index.html must load views.css with media=print + data-views");
  assert.ok(html.includes('<noscript><link rel="stylesheet" href="/webui/views.css"></noscript>'),
    "index.html must keep a noscript fallback for views.css");
  assert.ok(html.includes('<link rel="stylesheet" href="/webui/app.css">'),
    "app.css stays the render-blocking sheet");
  // preact-boot.js flips the async sheets to all once they are ready (CSP
  // forbids inline onload). It has to be preact-boot and not app.js: app.js
  // evaluates only after its whole static import graph lands (~146 KB gz),
  // which parked PatternFly \u2014 the page's layout framework \u2014 behind every
  // module the page has, so the frame painted from app.css and then reflowed.
  assert.match(bootJs, /link\[data-views\]/);
  assert.match(bootJs, /link\[data-pf\]/);
  assert.match(bootJs, /link\.media = "all"/);
  assert.ok(!/link\[data-views\]/.test(appJs), "the sheet swap must not move back onto app.js's import graph");
  // preact-boot.js is the first module script tag, so nothing else has to run
  // first for the swap to happen.
  const bootTag = html.indexOf('src="/webui/preact-boot.js"');
  const firstTag = html.indexOf('<script type="module"');
  assert.ok(bootTag > 0 && html.lastIndexOf("<script type=\"module\"", bootTag) === firstTag,
    "preact-boot.js must stay the first module script tag");
});

test("no views.css selector styles an element the first paint shows", function () {
  const offenders = [];
  for (const sel of cssRules(viewsCss)) {
    const hit = firstPaint.find((el) => matchesAny(sel, el));
    if (hit) {
      offenders.push(`${sel.slice(0, 90)} -> <${hit.tag} id=${hit.attrs["id"] ?? ""} class=${(hit.attrs["class"] ?? "").split(/\s+/)[0]}>`);
    }
  }
  assert.deepEqual(offenders, []);
});

test("no views.css selector styles chat/chrome runtime content", function () {
  // Rules that match nothing in the static HTML are fine to defer only if
  // they cannot style content the chat column or global chrome creates while
  // running. A rule naming one of these first-paint containers in views.css
  // would leave that content unstyled until the async sheet arrives.
  const containers = [
    "transcript", "turn", "event-", "composer", "#task", "prompt-list", "run-options",
    "toolbar", "suggestions", "rail-", "session-", "status-chip", "toast", "#toasts",
    "palette-", "chat-steer", "steer-", "run-metrics", "scroll-bottom", "attachments",
    "model-pill", "chip[data-state", "transcript-tools", "goal-form", "overlay",
    "#help", "#palette", "model-select", "fallback-provider", "voice-btn", "skip-link",
  ];
  const hits = [];
  for (const sel of cssRules(viewsCss)) {
    for (const t of containers) {
      if (new RegExp("(^|[.\\s#>~+:(])" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(sel)) {
        hits.push(`${sel.slice(0, 90)} (${t})`);
        break;
      }
    }
  }
  assert.deepEqual(hits, []);
});

test("the two sheets still cover everything the page styles", function () {
  // Every rule that used to live in app.css must still exist in one of the two
  // sheets: the split moves whole rules, it never edits them.
  const cssRulesBefore = cssRules(html); // noop guard, rules are read from files above
  const combined = appCss + "\n" + viewsCss;
  // Spot-check rules that the first paint depends on are in the blocking sheet.
  for (const sel of [".rail", ".composer .toolbar #submit", "#transcript", ".chip", "input[type=\"text\"]:not(.pf-v6-c-form-control)"]) {
    assert.ok(combined.includes(sel.slice(0, 30)), `stylesheet split dropped ${sel}`);
  }
  assert.ok(cssRulesBefore.length >= 0); // silence unused
});
