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
  if (webPath.startsWith("/webui/vendor/")) return join("..", "vendor", webPath.slice("/webui/vendor/".length));
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
const static_import_re = /^\s*import\s[^;]*?from\s+"([^"]+)"/gm;

function resolveSpecifier(fromWebPath, spec) {
  if (!spec.startsWith(".")) return spec;
  return posix.resolve(posix.dirname(fromWebPath), spec);
}

function importClosure(roots) {
  const seen = new Set();
  const stack = [...roots];
  while (stack.length) {
    const webPath = stack.pop();
    if (seen.has(webPath)) continue;
    seen.add(webPath);
    const src = fileBytes(resolveAsset(webPath)).toString("utf8");
    for (const m of src.matchAll(static_import_re)) stack.push(resolveSpecifier(webPath, m[1]));
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
const firstPaintGz = gzKib(fileBytes("index.html")) + gzKib(fileBytes("app.css"));

console.log("-- web delivery weight (gzip level 9, what the wire carries) --");
for (const src of eager.sort()) {
  console.log(`   ${sizes[src].rawKib.toFixed(1).padStart(7)}K raw ${sizes[src].gzKib.toFixed(1).padStart(6)}K gz  ${src}`);
}
console.log(`   eager JS (${eager.length} requests): ${eagerJsGz.toFixed(1)}K gz`);
console.log(`   first paint (index.html + app.css): ${firstPaintGz.toFixed(1)}K gz`);
console.log(`   views.css deferred: ${gzKib(fileBytes("views.css")).toFixed(1)}K gz`);
console.log(`   patternfly.min.css deferred: ${gzKib(fileBytes(join("..", "vendor", "patternfly.min.css"))).toFixed(1)}K gz`);

test("the page head still preloads the heavy entry, not the light modules", function () {
  // The preload list is the critical-path fetch set; growing it dilutes
  // priority for the modules that actually gate first paint.
  assert.ok(preloads.length <= 8, `modulepreloads grew to ${preloads.length}; each one competes with app.js`);
});

test("eager JS stays inside its weight budget", function () {
  // Everything a chat-only visit downloads. 145 KiB of gzipped first-party JS
  // is ~200 ms on a 6 Mbit/s uplink and the bulk of time-to-interactive. The
  // budget follows the wins down: it was 192K while the Runs view sat inline
  // in app.js, and a budget left far above the real number stops catching the
  // accretion it exists to catch. It was raised 144 -> 145 on 2026-08-27 on
  // purpose: the fleet run rows gained a real <button> for screen readers
  // (44abfedd), adding ~0.1K gz of deliberate bytes. The header says
  // deliberate bytes get a deliberate budget, not a fix shaved to fit.
  assert.ok(eagerJsGz <= 145, `eager JS is ${eagerJsGz.toFixed(1)}K gz; budget is 145K`);
});

test("first paint stays inside its weight budget", function () {
  // index.html + app.css are the render-blocking critical path; the deferred
  // views.css and patternfly must not creep back into them (css-split.test.mjs
  // pins what each sheet may style).
  assert.ok(firstPaintGz <= 64, `first paint is ${firstPaintGz.toFixed(1)}K gz; budget is 64K`);
  const appCssRaw = fileBytes("app.css").length / KiB;
  assert.ok(appCssRaw <= 192, `app.css is ${appCssRaw.toFixed(1)}K raw; budget is 192K`);
});

test("single large files stay inside their budgets", function () {
  const appJsRaw = fileBytes("app.js").length / KiB;
  assert.ok(appJsRaw <= 256, `app.js is ${appJsRaw.toFixed(1)}K raw; budget is 256K`);
  const htmlRaw = fileBytes("index.html").length / KiB;
  assert.ok(htmlRaw <= 96, `index.html is ${htmlRaw.toFixed(1)}K raw; budget is 96K`);
  const viewsRaw = fileBytes("views.css").length / KiB;
  assert.ok(viewsRaw <= 80, `views.css is ${viewsRaw.toFixed(1)}K raw; budget is 80K`);
});

test("deferred vendor CSS stays inside its budget", function () {
  // patternfly is fetched on every visit (media=print, swapped to all by
  // app.js) but must stay off the first-paint path; its gz size is what every
  // visitor pays once the swap lands.
  const pfGz = gzKib(fileBytes(join("..", "vendor", "patternfly.min.css")));
  assert.ok(pfGz <= 80, `patternfly.min.css is ${pfGz.toFixed(1)}K gz; budget is 80K`);
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
    if (manifest.eager) { eagerNames.push(name); eagerGz += gz; } else deferredGz += gz;
  }
  console.log(`   plugins deferred to first open: ${deferredGz.toFixed(1)}K gz`);
  console.log(`   plugins loaded eagerly (${eagerNames.join(", ") || "none"}): ${eagerGz.toFixed(1)}K gz`);
  assert.ok(eagerNames.length <= 1, `${eagerNames.length} plugins load on every visit (${eagerNames.join(", ")}); each one needs a reason to run outside its own view`);
  assert.ok(eagerGz <= 8, `eager plugin weight is ${eagerGz.toFixed(1)}K gz; budget is 8K`);
});
