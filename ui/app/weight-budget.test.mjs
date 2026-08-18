import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// Web-delivery weight budget: what a visitor actually downloads, and what it is
// allowed to grow to. The audience is an operator panel served from the machine
// itself or a LAN (`clanker serve` binds 127.0.0.1 by default), so these are
// not public-mobile budgets — they exist to catch silent accretion, not to
// squeeze the last byte. They pin the shipped files as embedded (the same
// bytes ui/webui.zig compiles in and the serve layer gzips once per process),
// and the eager JS set as the union of the page's script tags and
// modulepreloads: everything a visit that never leaves Chat downloads.
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
const eager = [...new Set([...scriptSrcs, ...preloads])];

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
  // Everything a chat-only visit downloads. 192 KiB of gzipped first-party JS
  // is ~250 ms on a 6 Mbit/s uplink and the bulk of time-to-interactive.
  assert.ok(eagerJsGz <= 192, `eager JS is ${eagerJsGz.toFixed(1)}K gz; budget is 192K`);
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
  assert.ok(appJsRaw <= 384, `app.js is ${appJsRaw.toFixed(1)}K raw; budget is 384K`);
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
