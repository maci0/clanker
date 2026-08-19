import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
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

test("a long saved conversation replays in chunks, not one long task", function () {
  // Opening a conversation rebuilds every turn card: a markdown parse of the
  // question, a fence pass and a card of buttons over each answer. A
  // 500-message session did all of it in one synchronous forEach — a
  // main-thread block during which the page was frozen and the status line
  // still said "Loading conversation…". The replay must return a promise and
  // yield between time-boxed chunks, and the callers that report status or
  // jump to a search hit afterwards must chain on it.
  const fn = app.match(/function renderSessionHistory\([\s\S]*?\n\}/);
  assert.ok(fn, "renderSessionHistory exists");
  assert.match(fn[0], /return new Promise\(/);
  assert.match(fn[0], /performance\.now\(\) < until/);
  assert.match(fn[0], /window\.setTimeout\(step, 0\)/);
  // switchSession's tail (empty-state, "Loaded N messages.", draft restore,
  // search jump) runs after the replay resolves, not while cards are still
  // being built; a replay failure reaches the same catch a sync one did.
  assert.match(
    app,
    /return renderSessionHistory\(data\.messages \|\| \[\]\)\.then\(function \(\) \{/,
    "switchSession must chain its post-replay tail on the replay promise"
  );
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

test("a plugin's mount or refresh throw is contained to its own panel", function () {
  // A plugin's mount is third-party code running inside the tab switch: a
  // throw that rides up through the view loader breaks the switch itself and
  // the whole page looks dead (PRD 0012 Known issues / Failure modes). Every
  // spec.mount / spec.refresh invocation in plugins.js must go through
  // runPluginHook, which catches, names the plugin and the exception in the
  // panel via showLoadError, and offers a retry that re-runs the loader.
  const plugins = readFileSync(join(here, "core", "plugins.js"), "utf8");
  const hookBody = plugins.match(/function runPluginHook\([\s\S]*?\n\}/);
  assert.ok(hookBody, "runPluginHook exists");
  assert.match(hookBody[0], /try \{[\s\S]*?\} catch \(e\) \{/);
  assert.match(hookBody[0], /showLoadError\(section, "The " \+ label \+ " plugin failed: " \+ msg, retryFn\)/);
  // No bare hook invocation survives outside the guard.
  const bare = plugins
    .split("\n")
    .filter((l) => /spec\.(mount|refresh)\.call\(/.test(l) && !/runPluginHook/.test(l));
  for (const line of bare) {
    assert.match(
      plugins,
      new RegExp("runPluginHook\\([^)]*function \\(\\) \\{\\s*\\n\\s*" + line.trim().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
      "unguarded plugin hook call: " + line.trim()
    );
  }
  assert.ok(
    (plugins.match(/runPluginHook\(section,/g) || []).length >= 4,
    "both loaders guard both mount and refresh"
  );
});

test("every named static import resolves to an export of its module", function () {
  // Lazy view modules were split out of app.js with their imports trimmed to
  // what each actually uses, and two of them called helpers they no longer
  // imported: system.js's empty MCP list threw ReferenceError on upgradePfButton
  // before appending its "Add server" button, and runs.js's node detail and
  // graph controls all threw on upgradePfButton/showLoadError. Nothing ran the
  // modules at build time (the guest embeds the JS as bytes), so the break
  // shipped. Static import/export resolution is the cheapest pin that catches
  // the class: a name a module binds from another module must be exported there.
  const dirs = ["core", "lib", "features"];
  const modules = [];
  for (const dir of dirs) {
    const base = join(here, dir);
    for (const entry of readdirSync(base)) {
      if (!entry.endsWith(".js")) continue;
      modules.push({ file: join(base, entry), rel: dir + "/" + entry });
    }
  }
  const exportNames = new Map();
  for (const m of modules) {
    const names = new Set();
    const src = readFileSync(m.file, "utf8");
    for (const mm of src.matchAll(/export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) names.add(mm[1]);
    for (const mm of src.matchAll(/export\s+(?:const|let|var|class)\s+([A-Za-z_$][\w$]*)/g)) names.add(mm[1]);
    for (const mm of src.matchAll(/export\s*\{([^}]*)\}/g)) {
      for (const name of mm[1].split(",")) {
        const n = name.trim().split(/\s+as\s+/).pop().trim();
        if (n) names.add(n);
      }
    }
    exportNames.set(m.file, names);
  }
  const resolved = new Map();
  function targetFile(fromFile, spec) {
    const key = fromFile + "|" + spec;
    if (resolved.has(key)) return resolved.get(key);
    const base = dirname(fromFile);
    const target = join(base, spec);
    const hit = modules.find((m) => m.file === target);
    resolved.set(key, hit ? hit.file : null);
    return hit ? hit.file : null;
  }
  let checked = 0;
  for (const m of modules) {
    const src = readFileSync(m.file, "utf8");
    for (const mm of src.matchAll(/import\s*\{([^}]*)\}\s*from\s*["'](\.\.?\/[^"']+)["']/g)) {
      const target = targetFile(m.file, mm[2]);
      assert.ok(target, `${m.rel} imports "${mm[2]}" which is not a sibling module file`);
      const exports_ = exportNames.get(target);
      for (const name of mm[1].split(",")) {
        const exported = name.trim().split(/\s+as\s+/)[0].trim();
        if (!exported) continue;
        checked++;
        assert.ok(
          exports_.has(exported),
          `${m.rel} imports ${name.trim()} from ${mm[2]}, but that module does not export ${exported}`
        );
      }
    }
  }
  assert.ok(checked >= 20, `static import resolution covered ${checked} imported names`);
});

test("shared UI helpers are called only where they are imported or defined", function () {
  // The link-time check above only proves imports resolve; it cannot see a
  // module *calling* a helper it never imported, which is not a link error —
  // it is a ReferenceError at the first call site, after the view rendered
  // partway. Both shipped breaks were exactly that shape: system.js called
  // upgradePfButton while rendering the empty MCP list, runs.js called
  // upgradePfButton/showLoadError in every node-detail and graph control. Pin
  // the shared helper names against each module's imports and local
  // declarations, so a view that stops importing one and keeps calling it
  // fails here instead of in the browser.
  const helperSources = ["core/ui.js", "core/utils.js", "core/vendor.js", "core/icons.js"];
  const helpers = new Set();
  for (const rel of helperSources) {
    const src = readFileSync(join(here, rel), "utf8");
    for (const mm of src.matchAll(/export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) helpers.add(mm[1]);
    for (const mm of src.matchAll(/export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) helpers.add(mm[1]);
  }
  const dirs = ["core", "lib", "features"];
  for (const dir of dirs) {
    for (const entry of readdirSync(join(here, dir))) {
      if (!entry.endsWith(".js")) continue;
      const file = join(here, dir, entry);
      const raw = readFileSync(file, "utf8");
      const src = raw
        .replace(/\/\*[\s\S]*?\*\//g, " ")
        .replace(/\/\/[^\n]*/g, " ")
        .replace(/"(?:\\.|[^"\\])*"/g, '""')
        .replace(/`(?:\\.|[^`\\])*`/g, "``");
      const imported = new Set();
      for (const mm of raw.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']\.\.?\/[^"']+["']/g)) {
        for (const name of mm[1].split(",")) imported.add(name.trim().split(/\s+as\s+/)[1] || name.trim().split(/\s+as\s+/)[0]);
      }
      const defined = new Set();
      for (const mm of src.matchAll(/(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) defined.add(mm[1]);
      for (const mm of src.matchAll(/(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) defined.add(mm[1]);
      for (const mm of src.matchAll(/(?:function\s+[A-Za-z_$][\w$]*\s*\(|function\s*\(|\([^)]*\)\s*=>)\s*([^)]*)/g)) {
        for (const p of mm[1].split(",")) {
          const t = p.trim().split(/\s*=\s*/)[0].trim();
          if (/^[A-Za-z_$][\w$]*$/.test(t)) defined.add(t);
        }
      }
      for (const h of helpers) {
        if (imported.has(h) || defined.has(h)) continue;
        const calls = [...src.matchAll(new RegExp(`(?<![\\w$.])${h}\\s*\\(`, "g"))];
        if (calls.length) {
          assert.fail(`${dir}/${entry} calls ${h}( without importing or defining it`);
        }
      }
    }
  }
});
