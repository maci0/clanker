// Composer slash commands. The catalog is commands/slash.json, served at
// /webui/commands/slash.json so adding a command is a data edit.
//
// The catalog is fetched on first use, not at module scope. It used to be
// fetched from the module body's last line, which is module *evaluation*: the
// browser is still pulling the 32-module eager graph over an HTTP/1.1
// six-connection pool at that moment, and this one request took a connection
// away from modules nothing renders without. Nothing paints from the catalog
// either — it is read only while someone types `/` in the composer, which is
// long after first draw — so the eager request bought nothing and cost a slot
// in the queue that gates interactivity. `slashReady()` is idempotent and
// memoized, so the later caller gets the same single fetch.

export var SLASH_CMDS = [];

var _promise = null;

function loadSlash() {
  return fetch("/webui/commands/slash.json").then(function (r) {
    if (!r.ok) { throw new Error("slash catalog"); }

    return r.json();
  }).then(function (data) {
    SLASH_CMDS = Array.isArray(data) ? data : [];

    return SLASH_CMDS;
  }).catch(function () {
    SLASH_CMDS = [];

    return SLASH_CMDS;
  });
}

export function slashReady() {
  if (!_promise) { _promise = loadSlash(); }

  return _promise;
}

export function runSlashEntry(entry, arg, ctx) {
  if (!entry) { return; }

  if (entry.click) {
    var node = document.getElementById(entry.click);

    if (node) { node.click(); }

    return;
  }

  if (entry.selector) {
    var hit = document.querySelector(entry.selector);

    if (hit) { hit.click(); }

    return;
  }

  if (entry.view && ctx && ctx.showView) {
    ctx.showView(entry.view, true);

    return;
  }

  if (entry.action === "model" && ctx && ctx.runModel) {
    ctx.runModel(arg || "");
  }
}
