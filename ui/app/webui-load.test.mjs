import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// Web-delivery regression pins: the critical-path preloads in the page head
// and the failure path for lazily loaded view modules. Both are contracts of
// the shipped HTML/JS as served, so they are asserted against the files as
// embedded, not a reimplementation.

const here = dirname(fileURLToPath(import.meta.url));
const app = readFileSync(join(here, "app.js"), "utf8");
const markup = readFileSync(join(here, "index.html"), "utf8");

test("critical-path modulepreloads name modules the page actually loads", function () {
  // A preload that points at a URL no script tag or import ever requests is
  // wasted bytes on every visit; one missing for a module whose script tag
  // sits at the far end of the body delays that module's fetch by the whole
  // HTML transfer. The head must preload the app entry and its heavy deps,
  // and every preload must be for a module the page really fetches.
  const preloads = [...markup.matchAll(/<link rel="modulepreload" href="([^"]+)">/g)].map((m) => m[1]);
  for (const critical of [
    "/webui/app.js",
    "/webui/core/ui.js",
    "/webui/core/utils.js",
    "/webui/vendor/preact.module.js",
    "/webui/vendor/htm.module.js",
    "/webui/vendor/signals-core.module.js",
  ]) {
    assert.ok(preloads.includes(critical), `critical-path module ${critical} must be preloaded in the head`);
  }
  for (const href of preloads) {
    if (href.startsWith("/webui/vendor/")) continue; // consumed via module imports, not script tags
    const script = `<script type="module" src="${href}">`;
    assert.ok(
      markup.includes(script),
      `modulepreload ${href} has no matching <script type="module"> tag in the page`
    );
  }
});

test("a failed view load surfaces an error with a retry instead of a blank panel", function () {
  // The loader rejection handler must not just clear the skeleton: a dead
  // chunk (dynamic import 404, failed API call) looked identical to an
  // empty-but-healthy view. It must say what failed in the view's container
  // and offer a Try again that re-runs the loader.
  assert.match(app, /function \(err\) \{[\s\S]*?clearLoading\(name\);/);
  assert.match(app, /showLoadError\(container, "Could not load the " \+ name \+ " view"/);
  // The retried loader is the same loader, and the view counts as loaded
  // only once it succeeds.
  assert.match(app, /return viewLoaders\[name\]\(\)\.then\(function \(\) \{\s*viewLoaded\[name\] = true;/);
  // The retry must not double-fire the loader for a view that never failed:
  // `viewLoaded` is only ever set true by a successful load.
  assert.doesNotMatch(app, /viewLoaded\[name\] = false;/);
});

test("a failed chunk import is not cached: every lazy view loader drops its promise", function () {
  // Each of the eleven lazily imported modules (arena, fleet, todos, board,
  // goals, prompts, models, knowledge, tools, run-graph, system) caches its import()
  // promise so a second open does not re-fetch. A rejected promise must not
  // stay cached, or the view's Try again and every later open re-throw the
  // same dead promise and the view stays broken for the life of the page.
  const markers = app.match(/null; \/\/ a failed chunk import must be retryable/g) || [];
  assert.equal(markers.length, 11, "all eleven lazy loaders reset their module promise on rejection");
  // The failure still reaches the caller (showView surfaces it) — the reset
  // must rethrow, not swallow.
  const rethrows = app.match(/catch\(function \(err\) \{[\s\S]*?throw err;\s*\}\)|function \(err\) \{[\s\S]*?null; \/\/ a failed chunk import[\s\S]*?throw err;/g) || [];
  assert.ok(rethrows.length >= 11, "every loader rethrows after resetting");
});
