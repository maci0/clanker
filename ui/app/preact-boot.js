/* Preact, htm, and signals ship as ES modules; app.js and the plugins are
   loaded as modules too, but plugin code receives its API at runtime rather
   than importing vendor paths itself. This boot module puts the primitives
   on window so the plugin API (core/plugins.js) can hand them over. It is a
   file rather than an inline script because the page's Content-Security-Policy
   is `script-src 'self'` with no 'unsafe-inline'.

   The old VanJS globals are gone: first-party code imports T/state/bind/add
   from core/ui.js (implemented on signals), and plugins get the same factory
   through api.van for backward compatibility. */

import { h, render, Fragment } from "/webui/vendor/preact.module.js";
import htm from "/webui/vendor/htm.module.js";
import { signal, computed, effect, batch } from "/webui/vendor/signals-core.module.js";

window.preact = { h: h, render: render, Fragment: Fragment };
window.html = htm.bind(h);
window.signals = { signal: signal, computed: computed, effect: effect, batch: batch };
