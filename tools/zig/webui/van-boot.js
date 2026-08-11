/* VanJS ships as an ES module and everything else here is a classic script, so
   one module bridges the two. It exists as a file rather than an inline script
   because the page's Content-Security-Policy is `script-src 'self'` with no
   'unsafe-inline', and that is worth more than the three lines it saves.

   Deferred scripts and module scripts both run in document order after
   parsing, so this lands before van-ui.js (which destructures van.tags at load
   time) and before app.js. */

import van from "/webui/vendor/van.js";

window.van = van;
