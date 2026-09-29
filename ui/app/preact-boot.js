/* Preact, htm, and signals ship as ES modules; app.js and the plugins are
   loaded as modules too, but plugin code receives its API at runtime rather
   than importing vendor paths itself. This boot module puts the primitives
   on the global object so the plugin API (core/plugins.js) can hand them
   over. It is a file rather than an inline script because the page's
   Content-Security-Policy is `script-src 'self'` with no 'unsafe-inline'.

   First-party code imports T/state/bind/add from core/ui.js (implemented on
   signals), and plugins get the same factory through api.van.

   The vendor specifiers are absolute on purpose: the page's import map
   (`webuiImportMapJson` in src/cli.zig) rewrites them to one tagged URL, so
   every module shares a single Preact and a single signal graph. */

// oxlint-disable-next-line import/no-absolute-path -- remapped by the page's import map
import { Fragment, h, render } from "/webui/vendor/preact.module.js";
// oxlint-disable-next-line import/no-absolute-path -- remapped by the page's import map
import htm from "/webui/vendor/htm.module.js";
// oxlint-disable-next-line import/no-absolute-path -- remapped by the page's import map
import { batch, computed, effect, signal } from "/webui/vendor/signals-core.module.js";

// oxlint-disable-next-line typescript/no-deprecated -- a reference, not the deprecated replaceNode overload
globalThis.preact = { Fragment, h, render };

globalThis.html = htm.bind(h);

globalThis.signals = { batch, computed, effect, signal };
