import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, posix } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// Web-delivery weight budget: what a visitor actually downloads, and what it is
// allowed to grow to. The audience is an operator panel served from the machine
// itself or a LAN (`clanker serve` binds 127.0.0.1 by default), so these are
// not public-mobile budgets — they exist to catch silent accretion, not to
// squeeze the last byte. They pin the shipped files as embedded (the same
// bytes ui/webui.zig compiles in and the serve layer gzips once per process),
// and the eager JS set as the transitive static import closure of the page's
// script tags: everything a visit that never leaves Chat downloads.
//
// When a number below drifts far enough to trip its budget, decide whether the
// bytes are worth it (and raise the budget on purpose) rather than deleting
// the check — the record of what the page used to weigh is the point.

const here = dirname(fileURLToPath(import.meta.url));

const KiB = 1024;

function fileBytes(rel) {
  return readFileSync(join(here, rel));
}

function gzKib(bytes) {
  return gzipSync(bytes, { level: 9 }).length / KiB;
}

// Resolve a `/webui/...` src or preload to the file under ui/. Vendored files
// live under ui/vendor/, everything else under ui/app/.
function resolveAsset(webPath) {
  if (webPath.startsWith("/webui/vendor/")) { return join("..", "vendor", webPath.slice("/webui/vendor/".length)); }

  return "." + webPath.slice("/webui".length);
}

const html = fileBytes("index.html").toString("utf8");

const scriptSrcs = [...html.matchAll(/<script type="module" src="(\/webui\/[^"]+)">/g)].map((m) => m[1]);

const preloads = [...html.matchAll(/<link rel="modulepreload" href="(\/webui\/[^"]+)">/g)].map((m) => m[1]);

// The eager set is the *transitive static import closure* of the page's script
// tags, not the tags themselves. A module reached only through `import ... from`
// inside app.js is downloaded on exactly the same visits as one with its own
// tag, so counting tags alone under-reports the wire weight and lets a new
// static import of app.js land entirely outside this budget. `core/slash.js`,
// `core/run-metrics.js` and `lib/runs-list.js` had done precisely that: 12.9 KB
// raw / 4.5 KB gz and three requests that every chat-only visit paid for and no
// test could see. Only `import ... from` is followed; a dynamic `import()` is
// the deferral this budget exists to encourage.
//
// Both spellings of a first-party specifier count, because both are downloaded
// on every visit. The relative form (`./core/ui.js`) was the only one
// followed, so an absolute one (`/webui/vendor/signals-core.module.js`, which
// the import map rewrites to the tagged URL at runtime) fell out of the walk
// entirely: `preact-boot.js` imports all three vendor primitives that way and
// `core/ui.js` reaches signals-core that way, and 17.1 KB raw / 6.9 KB gz of
// every-visit bytes sat outside the count. It read as correct only because
// something else also happened to list those three in the head's preload
// hints, which the total unions in, so a hint and an import were silently
// covering for each other and deleting either one would have dropped real
// bytes from the budget with nothing failing. A bare specifier ("preact") is
// not a web path, so it is skipped rather than resolved instead of sending the
// walk off to read a file that does not exist.
const static_import_re = /^\s*import\s[^;]*?from\s+"([^"]+)"/gm;

function resolveSpecifier(fromWebPath, spec) {
  if (spec.startsWith("/webui/")) { return posix.normalize(spec); }

  if (!spec.startsWith(".")) { return null; }

  return posix.resolve(posix.dirname(fromWebPath), spec);
}

function importClosure(roots) {
  const seen = new Set();
  const stack = [...roots];

  while (stack.length) {
    const webPath = stack.pop();

    if (seen.has(webPath)) { continue; }

    seen.add(webPath);
    const src = fileBytes(resolveAsset(webPath)).toString("utf8");

    for (const m of src.matchAll(static_import_re)) {
      const resolved = resolveSpecifier(webPath, m[1]);

      if (resolved) { stack.push(resolved); }
    }
  }

  return [...seen];
}

const eager = [...new Set([...importClosure(scriptSrcs), ...preloads])];

const sizes = {};

for (const src of eager) {
  const raw = fileBytes(resolveAsset(src));
  sizes[src] = { rawKib: raw.length / KiB, gzKib: gzKib(raw) };
}

const eagerJsGz = eager.reduce((sum, src) => sum + sizes[src].gzKib, 0);

// tailwind.css is in the critical path by design: the utilities are the layer
// that replaced the cabinet sheet, so they have to
// arrive before the first draw. It costs its bytes every visit, which is why
// the first-paint budget below counts it.
const firstPaintGz = gzKib(fileBytes("index.html")) + gzKib(fileBytes("tailwind.css"));

console.log("-- web delivery weight (gzip level 9, what the wire carries) --");

for (const src of eager.sort()) {
  console.log(`   ${sizes[src].rawKib.toFixed(1).padStart(7)}K raw ${sizes[src].gzKib.toFixed(1).padStart(6)}K gz  ${src}`);
}

console.log(`   eager JS (${eager.length} requests): ${eagerJsGz.toFixed(1)}K gz`);

console.log(`   first paint (index.html + tailwind.css): ${firstPaintGz.toFixed(1)}K gz`);

console.log(`   tailwind.css: ${(fileBytes("tailwind.css").length / KiB).toFixed(1)}K raw ${gzKib(fileBytes("tailwind.css")).toFixed(1)}K gz`);

test("the head preloads the whole eager graph, heaviest first", function () {
  // The head list used to be a hand-picked few, on the theory that a longer
  // one dilutes priority for the modules that gate first paint. Every module
  // it names is a static import of app.js, so all of them are requested on
  // every visit and every one of them gates interactivity, not just the first
  // frame. The cost of leaving them off is concrete: their <script> tags sit
  // at the end of a 107 KB body, so the preload scanner cannot see them until
  // the whole document has arrived, and the graph then starts a full
  // document-transfer late. Listing them costs no extra bytes (each is
  // fetched anyway, and the hint reuses the same response) and starts the
  // fetches while the HTML is still streaming. The byte budget above is what
  // bounds this set; the count only has to keep a bound on the hints
  // themselves.
  assert.ok(
    preloads.length <= 40,
    `modulepreloads grew to ${preloads.length}; a module outside the eager graph does not belong here`
  );
  // HTTP/1.1 has no request priority, so when the six-connection pool is full
  // the queue is served in the order the hints appear. The entry and its two
  // heaviest dependencies therefore have to come first: a light module ahead
  // of app.js delays the only module nothing else can run without.
  assert.equal(preloads[0], "/webui/app.js", "the entry must be the first hint, so it is fetched first");

  for (const heavy of ["/webui/core/ui.js", "/webui/core/utils.js", "/webui/core/modelpicker.js", "/webui/lib/markdown.js"]) {
    assert.ok(
      preloads.indexOf(heavy) <= 8,
      `${heavy} is one of the largest eager modules and must sit in the first wave of hints`
    );
  }
});

test("the head hints and the import graph name the same modules", function () {
  // The two lists answer one question from opposite ends: the closure says
  // what a visit downloads, the hints say what the scanner may see of it. A
  // module in only one of them is a defect either way, and each was invisible
  // until the other covered for it. A hint with no import behind it pulls a
  // full module off the wire that nothing runs, and it does so at the front of
  // the six-connection queue, ahead of the modules that do. An eager module
  // with no hint is requested one document-transfer late, since its <script>
  // tag is at the end of a 107 KB body the scanner cannot read past yet. This
  // is the assertion that keeps either list honest on its own: the totals
  // below union the two, so a module missing from both is the case that would
  // otherwise go uncounted, and a mismatch here names it.
  const closure = new Set(importClosure(scriptSrcs));
  const hinted = new Set(preloads);

  for (const src of closure) {
    assert.ok(hinted.has(src), `${src} is downloaded on every visit but has no modulepreload, so the scanner finds it a document-transfer late`);
  }

  for (const src of preloads) {
    assert.ok(closure.has(src), `${src} is preloaded but nothing imports it, so its bytes are fetched for a module no visit runs`);
  }
});

test("eager JS stays inside its weight budget", function () {
  // Everything a chat-only visit downloads. 144 KiB of gzipped first-party JS
  // is ~190 ms on a 6 Mbit/s uplink and the bulk of time-to-interactive. The
  // budget follows the wins down: it was 192K while the Runs view sat inline
  // in app.js, and a budget left far above the real number stops catching the
  // accretion it exists to catch. The 2026-08-29 stopgap raised it to 145
  // when the measured 144.1 blocked every gated change (see
  // docs/reports/bugs/2026-08-27-webui-weight-budget-exceeded-by-100-bytes.md);
  // deferring core/logs.js out of the eager set trimmed the real number to
  // 143.8, so the budget is back at 144, the floor above it, per that
  // stopgap's own instruction. The fleet run rows' real <button> for screen
  // readers (44abfedd, ~0.1K gz) is inside that 144. The locale-aware
  // currency/percent/compact formatters in core/utils.js are the next 0.4K:
  // they replace hardcoded "$" + toFixed and K/M suffixes at every price,
  // rate and token count, which cannot shrink without giving the formatting
  // back. Raised to 145 for that, the same deliberate step the 2026-08-29
  // stopgap describes.
  // 148, raised from 145 on purpose by the Tailwind port: a ported module
  // states its shapes as class strings, so the bytes move out of the sheets
  // and into the eager closure of whichever module is on the critical path.
  // The message row's class lists live in app.js, so a view that moves over
  // grew this number while shrinking the cabinet sheet: the port is done, so the
  // cabinet sheets are gone and the strings are the only home for a view's
  // shapes. 152 is that growth, measured with the message row in.
  // core/usage.js is preloaded (its grid strings), and core/kit.js is reached
  // from core/plugins.js, which every visit loads (the variant tables and the
  // record-row surface, so a plugin styles itself the way the page does). The
  // number comes back down when the port is done and the last sheet is gone;
  // until then a raise here is a deliberate act per this test's instruction,
  // never a quiet one.
  // 158, raised from 156 for the plugin surface core/plugins.js grew by handing
  // a plugin the core helpers a built-in view already imports (chrome rows, the
  // overlay, the stream splitter, the colour and goal helpers, and the rest of
  // the formatters). Every one of those modules was already in the eager
  // closure, so the whole cost is the 2K gz of re-exports: a built-in view
  // migrating to ui/plugins/ no longer has to keep a second copy of any of
  // them, which is what ui/plugins/capabilities.test.mjs now pins. Paying that
  // on a chat-only visit is the same trade kit.js already makes, for the same
  // reason.
  /* 160, raised from 158 for the rail's icons: every destination, built-in
     or plugin, wears one drawn on the icons.js grid, and the collapsed rail
     shows nothing else, so the paths are needed on the first paint of any view. */
  /* 161, raised from 160 for two fixes a reader hits and a chat visit cannot
     route around. core/chat.js carries the Chat search box's answer ordering:
     the input handler debounces over HTTP, so a slow earlier answer used to
     land on top of a newer one and name hits for a phrase already replaced
     (~1.0K gz). core/vendor.js's copy fallback parked an offscreen field when
     the value being copied has no visible node to select, so a plain-http
     origin — where the clipboard API is withheld, so every copy button took
     that path — ended at "Copy unavailable" with no way onward instead of the
     select-to-copy hand-off every other copy button here offers (~0.3K gz).
     Neither is reachable by a chat-only visit that never opens the search box
     or shares a link, and both would cost a new asset kind and a served
     module to defer, which is a larger cost than the bytes. Raised to 162 for
     two locale fixes, neither of which any byte of the served body carries:
     `webui_strip.zig` strips first-party comments before a response is
     written, so the cost is disk weight only. core/utils.js's inventory-status
     predicate matched ASCII digits and commas while the counts on the other
     side of that test come from Intl, so a German ("1.204"), French (U+202F)
     or Arabic-Indic listing toasted its own row count on every load.
     lib/markdown.js's citation class truncated a non-ASCII path to its ASCII
     tail ("dokumentation/Übersicht.zig:12" matched as "bersicht.zig:12"), so
     the chip opened the wrong file in the callgraph (~0.2K gz).
     Raised to 163 because two later commits shipped without re-tightening it:
     b413ab47 made the channel topic a keyboard-operable <button> (a screen
     reader now reads the same label the screen shows, and a DM's control is
     disabled instead of focusable) and 4c283665 made silent actions speak and
     one number format the counts everywhere. Neither added a request, and the
     gz grew by 39 bytes over the 162K line, so the wire cost of both is
     noise. */
  // Raised to 163 for core/utils.js's `capBytes`, which cuts a board card
  // title in bytes because the guest enforces that limit in bytes
  // (cards.max_title_len, counted with `.len` in Zig). The call site it
  // replaced, `slice(0, 512)`, counts UTF-16 units, so it met the limit for
  // ASCII only: a 300-character objective of two-byte letters is 600 bytes,
  // passed the cut whole, and was refused by the guest anyway, pinning the
  // goal mirror as "requested" forever (~0.4K gz).
  assert.ok(eagerJsGz <= 163, `eager JS is ${eagerJsGz.toFixed(1)}K gz; budget is 163K`);
});

test("first paint stays inside its weight budget", function () {
  // index.html and the compiled Tailwind sheet are the render-blocking
  // critical path. The deferred view sheet is gone (its last rule moved into the
  // Tailwind source), so this is the whole style cost a visitor pays.
  assert.ok(firstPaintGz <= 64, `first paint is ${firstPaintGz.toFixed(1)}K gz; budget is 64K`);
});

test("the compiled Tailwind sheet stays inside its budget", function () {
  // It is generated from the class names in ui/app and ui/plugins, so this
  // number grows with nothing but the port itself. A jump that is not a view
  // moving over means the scan picked up a tree it should not: `@source`
  // reaching beyond ui/ (docs, changelogs, .scratch) turns every prose word
  // that looks like a utility into a rule.
  const css = fileBytes("tailwind.css").length / KiB;
  // 200, raised from 48 nineteen times, each named in CHANGELOG: the run graph, the
  // board lane, the card face, its chips, its members, the detail panel, the
  // tool rows, the rooms sidebar, the message row, the rooms main column, the
  // transcript's turn, the dialog backdrop views.css held last, the rail, the
  // masthead's chips, the model and theme pickers, the chat column, its job
  // buttons, the rendered document and the chrome vocabulary plugins also
  // write by name, and finally app.css's token block and element layer —
  // the last cabinet sheet, whose deletion is why first paint falls while this
  // number rises. This is
  // accounting, not a ceiling — the sheet absorbs the cabinet sheets' rules as
  // utilities while both still ship (app.css is still ~150K raw), and phase 6
  // deletes those sheets, leaving this one holding the whole UI. The binding
  // number for a visitor is first paint, asserted above, which counts this
  // sheet plus app.css plus index.html. What this one catches is growth that is
  // *not* a view moving over: an `@source` glob reaching beyond ui/ turns prose
  // in docs or .scratch into rules.
  assert.ok(css <= 200, `tailwind.css is ${css.toFixed(1)}K raw; budget is 200K`);
});

test("single large files stay inside their budgets", function () {
  // The raw figure is disk weight, not wire weight: webui_strip.zig strips
  // first-party comments before a response is written, and ~63 KB of app.js is
  // exactly that (the prose above and beside each step). It was tightened to
  // 264 at 6d4bab05, where app.js stood at 269.5K, and two commits since then
  // added the channel-topic control and the silent-action/count fixes without
  // re-tightening it, so the shipped file sat 174 bytes over a line nothing
  // re-asserted. 265 records that weight; the number moves on purpose, never by
  // accreting edits nobody looked at.
  const appJsRaw = fileBytes("app.js").length / KiB;
  assert.ok(appJsRaw <= 265, `app.js is ${appJsRaw.toFixed(1)}K raw; budget is 265K`);
  const htmlRaw = fileBytes("index.html").length / KiB;
  assert.ok(htmlRaw <= 108, `index.html is ${htmlRaw.toFixed(1)}K raw; budget is 108K`);
});

test("web UI plugins stay off the load path unless they opt in", function () {
  // An addon's tab, title and group come from its plugin.json, so the page can
  // offer the addon without its code (`registerDeferredView` in
  // core/plugins.js); app.js and app.css arrive when the tab is first opened.
  // `eager: true` opts out, for an addon that does work outside its own view.
  // It costs every visit, chat-only ones included, so it stays rare on purpose:
  // this pins that it is a deliberate act, not a default that crept back.
  const dir = join(here, "..", "plugins");
  const names = readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  let eagerGz = 0;
  let deferredGz = 0;
  const eagerNames = [];

  for (const name of names) {
    let manifest;

    try { manifest = JSON.parse(readFileSync(join(dir, name, "plugin.json"), "utf8")); } catch { continue; }

    let gz = 0;

    for (const asset of ["app.js", "app.css"]) {
      try { gz += gzKib(readFileSync(join(dir, name, asset))); } catch { /* optional */ }
    }

    if (manifest.eager) { eagerNames.push(name); eagerGz += gz; } else { deferredGz += gz; }
  }

  console.log(`   plugins deferred to first open: ${deferredGz.toFixed(1)}K gz`);
  console.log(`   plugins loaded eagerly (${eagerNames.join(", ") || "none"}): ${eagerGz.toFixed(1)}K gz`);
  assert.ok(eagerNames.length <= 1, `${eagerNames.length} plugins load on every visit (${eagerNames.join(", ")}); each one needs a reason to run outside its own view`);
  assert.ok(eagerGz <= 8, `eager plugin weight is ${eagerGz.toFixed(1)}K gz; budget is 8K`);
});
