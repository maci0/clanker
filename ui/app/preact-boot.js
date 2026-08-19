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

/* Arm the two deferred stylesheets. They ship as media="print" so they never
   block the first draw, and something has to flip them back to "all"; CSP
   (`script-src 'self'`, no 'unsafe-inline') rules out the usual
   `onload="this.media='all'"` attribute, so it has to be a module.

   It lives here rather than in app.js because app.js evaluates only after its
   whole 31-module static graph (~146 KB gz) has arrived, and PatternFly is the
   page's layout framework: parking its activation behind that much JS meant
   the frame painted from app.css alone and then reflowed. This module's own
   three imports are modulepreloaded in the head and total ~7 KB gz, so the
   sheets arm roughly an order of magnitude sooner.

   ponytail: still gated on those three vendor modules. A zero-import module of
   its own would arm marginally sooner, at the cost of one more request and an
   entry in every asset list; not worth it until the vendor trio grows. */
(function activateDeferredSheets() {
  [document.querySelector("link[data-pf]"), document.querySelector("link[data-views]")].forEach(function (link) {
    if (!link) return;
    function arm() { link.media = "all"; }
    if (link.sheet) arm();
    else link.addEventListener("load", arm);
  });
})();
