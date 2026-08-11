// Vanilla, no bundler. Text prompt dialog + shortcut table — no app state.
export var SHORTCUTS = [
  ["Ctrl/\u2318 + K", "Jump to a view, conversation, run, tool or action"],
  ["?", "This list"],
  ["1 \u2013 8", "Go to a view by number"],
  ["\u2190 \u2192", "Move between tabs when one is focused"],
  ["Ctrl/\u2318 + Enter", "Run the task in the composer"],
  ["Ctrl/\u2318 + \u2190 \u2192", "Move the focused board card between columns"],
  ["Esc", "Close an overlay, or stop a running task"]
];

var _els = null;
var _open = null;
var _close = null;
var _resolve = null;

/* A styled replacement for window.prompt(): resolves to the entered text, or
   null if cancelled or dismissed. opts.suggestions backs the input with a
   datalist so a value that already exists (a workspace name, say) can be
   picked rather than retyped. Must call bindDialog first. */
export function textPrompt(opts) {
  if (!_els || !_open) return Promise.resolve(null);
  opts = opts || {};
  _els.textPromptTitle.textContent = opts.title || "Enter a value";
  _els.textPromptLabel.textContent = opts.label || "Value";
  _els.textPromptInput.value = opts.value || "";
  _els.textPromptHint.textContent = opts.hint || "";
  _els.textPromptOptions.textContent = "";
  (opts.suggestions || []).forEach(function (s) {
    var o = document.createElement("option");
    o.value = s;
    _els.textPromptOptions.appendChild(o);
  });
  _open(_els.textPrompt, _els.textPromptInput);
  _els.textPromptInput.select();
  return new Promise(function (resolve) { _resolve = resolve; });
}

export function finishTextPrompt(value) {
  if (!_els || !_close || _els.textPrompt.hidden) return;
  _close(_els.textPrompt);
  var resolve = _resolve;
  _resolve = null;
  if (resolve) resolve(value);
}

export function bindDialog(els, openFn, closeFn) {
  _els = els;
  _open = openFn;
  _close = closeFn;
  // Populate shortcut table once — lives outside any view's lifecycle.
  if (els.shortcuts && !els.shortcuts._bound) {
    els.shortcuts._bound = true;
    SHORTCUTS.forEach(function (pair) {
      var dt = document.createElement("dt");
      dt.textContent = pair[0];
      var dd = document.createElement("dd");
      dd.textContent = pair[1];
      els.shortcuts.appendChild(dt);
      els.shortcuts.appendChild(dd);
    });
  }
  if (els.textPromptForm && !els.textPromptForm._bound) {
    els.textPromptForm._bound = true;
    els.textPromptForm.addEventListener("submit", function (e) {
      e.preventDefault();
      finishTextPrompt(els.textPromptInput.value);
    });
  }
  if (els.textPromptCancel && !els.textPromptCancel._bound) {
    els.textPromptCancel._bound = true;
    els.textPromptCancel.addEventListener("click", function () { finishTextPrompt(null); });
  }
  if (els.textPrompt && !els.textPrompt._bound) {
    els.textPrompt._bound = true;
    els.textPrompt.addEventListener("mousedown", function (e) {
      if (e.target === els.textPrompt) finishTextPrompt(null);
    });
  }
}
