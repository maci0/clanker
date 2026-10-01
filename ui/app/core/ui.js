// Vanilla, no bundler. UI primitives: tag factory, reactive state and
// binding (on @preact/signals-core), toasts, skeletons, component
// vocabulary, and the sheet's one visual language for controls.
//
// T builds REAL DOM nodes (not vnodes): the whole sheet appends its results
// directly, so this stays a plain factory. Reactivity comes from signals:
// state() wraps a signal behind VanJS's `.val` spelling (every call site and
// the plugin API already speak it), and bind()/function-children re-run
// inside effect(), which re-tracks whatever signals the render read.

import { signal, effect } from "/webui/vendor/signals-core.module.js";

export function state(initial) {
  var s = signal(initial);
  return {
    get val() { return s.value; },
    set val(x) { s.value = x; },
  };
}

function setAttr(node, key, value) {
  if (value == null || value === false) return;
  if (key.indexOf("on") === 0 && typeof value === "function") {
    node.addEventListener(key.slice(2).toLowerCase(), value);
    return;
  }
  node.setAttribute(key, value === true ? "" : String(value));
}

function appendInto(parent, child) {
  if (child == null || child === false) return;
  if (Array.isArray(child)) { child.forEach(function (c) { appendInto(parent, c); }); return; }
  if (typeof child === "function") {
    // A function child is a live binding: re-evaluated whenever a signal it
    // reads changes. Text results update a text node in place; a Node result
    // replaces the previous one.
    var current = document.createTextNode("");
    parent.appendChild(current);
    effect(function () {
      var v = child();
      if (v instanceof Node) { current.replaceWith(v); current = v; }
      else if (current.nodeType === Node.TEXT_NODE) current.nodeValue = v == null ? "" : String(v);
      else { var t = document.createTextNode(v == null ? "" : String(v)); current.replaceWith(t); current = t; }
    });
    return;
  }
  parent.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
}

export function add(parent) {
  for (var i = 1; i < arguments.length; i++) appendInto(parent, arguments[i]);
  return parent;
}

function isAttrs(a) {
  return a != null && typeof a === "object" && !Array.isArray(a) && !(a instanceof Node);
}

export var T = new Proxy({}, {
  get (_, name) {
    return function () {
      var node = document.createElement(name);
      var i = 0;
      if (arguments.length && isAttrs(arguments[0])) {
        var attrs = arguments[0];
        for (var k in attrs) setAttr(node, k, attrs[k]);
        i = 1;
      }
      for (; i < arguments.length; i++) appendInto(node, arguments[i]);
      return node;
    };
  },
});

export { effect };

export function bind(node, st, render) {
  effect(function () {
    var value = st.val;
    node.textContent = "";
    var built = render(value);
    if (built == null) return;
    appendInto(node, built);
  });
}

/* A toast's text sits in its own flex child so the dismiss control keeps its
   place. */
var TOAST_TITLE_CLASS = "min-w-0 flex-1";

function ensureToastTitle(node) {
  if (!node || !node.classList.contains("toast")) return node;
  if (!node.querySelector(":scope > ." + TOAST_TITLE_CLASS.split(" ")[0])) {
    var title = document.createElement("span");
    title.className = TOAST_TITLE_CLASS;
    title.textContent = node.textContent;
    node.textContent = "";
    node.appendChild(title);
  }
  return node;
}

// A fixed timer is too short to read a long message, so hovering or
// focusing a toast (mouse or keyboard) holds it on screen.
export function toast(msg, kind) {
  if (!msg || typeof document === "undefined") return null;
  var host = document.getElementById("toasts");
  if (!host) return null;
  var node = document.createElement("div");
  node.className = "toast";
  node.tabIndex = 0;
  node.setAttribute("role", "status");
  node.setAttribute("aria-live", "polite");
  if (kind === "bad" || /fail|error|could not|refus|denied|no such/i.test(msg)) node.setAttribute("data-kind", "bad");
  var title = document.createElement("span");
  title.className = TOAST_TITLE_CLASS;
  title.textContent = msg;
  node.appendChild(title);
  var dismiss = document.createElement("button");
  dismiss.type = "button";
  dismiss.className = "toast-dismiss";
  dismiss.textContent = "Dismiss";
  dismiss.addEventListener("click", function (event) {
    event.stopPropagation();
    node.remove();
  });
  node.appendChild(dismiss);
  ensureToastTitle(node);
  node.addEventListener("click", function () { node.remove(); });
  node.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" && event.key !== " " && event.key !== "Escape") return;
    event.preventDefault();
    node.remove();
  });
  node.setAttribute("aria-label", msg + ". Dismiss, or press Enter, Space, or Escape.");
  var timer;
  var ms = node.hasAttribute("data-kind") ? 9000 : 5000;
  function schedule() { timer = window.setTimeout(function () { node.remove(); }, ms); }
  node.addEventListener("mouseenter", function () { window.clearTimeout(timer); });
  node.addEventListener("mouseleave", schedule);
  node.addEventListener("focusin", function () { window.clearTimeout(timer); });
  node.addEventListener("focusout", schedule);
  host.appendChild(node);
  while (host.children.length > 3) host.removeChild(host.firstChild);
  schedule();
  return node;
}

/* A required field holding only spaces passes the browser's `required`, so a
   handler that only checks for an empty value returns silently: the form does
   nothing and says nothing. This is the one refusal every text field makes,
   in the browser's own bubble on the field that needs filling. */
export function requireText(input, message) {
  if (input.value.trim()) { input.setCustomValidity(""); return true; }
  input.setCustomValidity(message);
  input.reportValidity();
  input.setCustomValidity("");
  return false;
}

/* A failed list fetch used to write only the sr-only status line (mirrored
   to a toast that then vanished). The panel looked empty, which reads as
   "nothing here" rather than "could not load". Put the reason and a retry
   where the rows would have been. */
export function showLoadError(container, message, retryFn) {
  if (!container) return null;
  container.hidden = false;
  container.removeAttribute("hidden");
  container.textContent = "";
  var p = document.createElement("p");
  p.className = "run-empty";
  p.appendChild(document.createTextNode(message));
  if (typeof retryFn === "function") {
    p.appendChild(document.createTextNode(" "));
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "secondary";
    btn.textContent = "Try again";
    btn.addEventListener("click", function () {
      btn.disabled = true;
      var done = function () { btn.disabled = false; };
      try {
        var out = retryFn();
        if (out && typeof out.then === "function") out.then(done, done);
        else done();
      } catch (_) { done(); }
    });
    p.appendChild(btn);
  }
  container.appendChild(p);
  return p;
}

/* Themed replacements for window.confirm / window.prompt. Native dialogs
   punch unthemed browser chrome through the page mid-task and block the
   main thread; these reuse the .slack-dialog <dialog> language the create-
   channel flow already established, so every confirmation reads as part of
   the same panel. Promise-shaped because <dialog> is: uiConfirm resolves
   true/false, uiPrompt resolves the string or null (= cancelled), matching
   the natives' contracts so call sites translate one-to-one. */
function openDialog(build) {
  return new Promise(function (resolve) {
    var dlg = document.createElement("dialog");
    dlg.className = "slack-dialog w-[90vw] max-w-[400px] rounded-plate-lg border border-rule bg-surface p-0 shadow-[var(--lift)]";
    var form = document.createElement("form");
    form.method = "dialog";
    form.className = "flex flex-col gap-3 p-6 [&_h3]:m-0 [&_h3]:text-base";
    dlg.appendChild(form);
    build(form, function done(value) {
      dlg.close();
      resolve(value);
    });
    dlg.addEventListener("close", function () {
      dlg.remove();
      resolve(null);
    });
    dlg.addEventListener("cancel", function () { resolve(null); });
    document.body.appendChild(dlg);
    dlg.showModal();
  });
}

// Both dialogs end the same way: a Cancel that answers with the caller's
// "nothing happened" value, then the confirming button.
function dialogActions(form, okLabel, danger, onCancel, onOk) {
  var actions = document.createElement("div");
  actions.className = "mt-2 flex justify-end gap-2 [&_.danger]:border-danger [&_.danger]:bg-danger [&_.danger]:text-on-danger";
  var cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "secondary";
  cancel.textContent = "Cancel";
  cancel.addEventListener("click", onCancel);
  actions.appendChild(cancel);
  var ok = document.createElement("button");
  ok.type = "button";
  ok.className = danger ? "danger" : "secondary";
  ok.textContent = okLabel;
  ok.addEventListener("click", onOk);
  actions.appendChild(ok);
  form.appendChild(actions);
  return { cancel, ok };
}

export function uiConfirm(message, opts) {
  opts = opts || {};
  return openDialog(function (form, done) {
    var title = document.createElement("h3");
    title.textContent = opts.title || opts.confirmLabel || "Confirm";
    form.appendChild(title);
    var p = document.createElement("p");
    p.className = "m-0 text-sm text-fg wrap-anywhere";
    p.textContent = message;
    form.appendChild(p);
    var btns = dialogActions(form, opts.confirmLabel || "OK", opts.danger,
      function () { done(false); }, function () { done(true); });
    window.setTimeout(function () { (opts.danger ? btns.cancel : btns.ok).focus(); }, 0);
  }).then(function (v) { return v === true; });
}

export function uiPrompt(message, initial, opts) {
  opts = opts || {};
  return openDialog(function (form, done) {
    var label = document.createElement("label");
    label.className = "m-0 text-sm text-fg wrap-anywhere";
    label.textContent = message;
    var id = "ui-prompt-" + Math.floor(Math.random() * 1e9);
    label.setAttribute("for", id);
    form.appendChild(label);
    var multiline = !!opts.multiline;
    var input = document.createElement(multiline ? "textarea" : "input");
    if (!multiline) input.type = "text";
    input.id = id;
    input.value = initial == null ? "" : String(initial);
    if (opts.placeholder) input.placeholder = opts.placeholder;
    if (opts.maxlength) input.maxLength = opts.maxlength;
    if (multiline) {
      input.wrap = "soft";
      input.rows = opts.rows || 4;
      input.className = "box-border min-h-24 max-h-[45vh] w-full resize-y leading-normal";
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); done(input.value); }
      });
    } else {
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); done(input.value); }
      });
    }
    form.appendChild(input);
    dialogActions(form, opts.confirmLabel || "Save", false,
      function () { done(null); }, function () { done(input.value); });
    window.setTimeout(function () { input.focus(); input.select(); }, 0);
  });
}

/* A placeholder row while a list loads: a plate with a rule under it, which
   reads as a row of content rather than a spinner. */
var SKELETON_CLASS = "h-10 rounded-plate border border-rule bg-surface-2";
var SKELETON_ROW_CLASS = "flex items-center gap-3 py-1";
var SKELETON_BAR_CLASS = "h-3.5 flex-1 rounded-plate-sm border-b border-rule bg-surface-2";

export function skeletonRows(container, n) {
  if (!container) return;
  container.textContent = "";
  container.setAttribute("aria-busy", "true");
  for (var i = 0; i < n; i++) {
    var row = document.createElement("div");
    row.className = SKELETON_CLASS;
    container.appendChild(row);
    var r = document.createElement("div");
    r.className = SKELETON_ROW_CLASS;
    for (var j = 0; j < 3; j++) {
      var bar = document.createElement("div");
      bar.className = SKELETON_BAR_CLASS;
      r.appendChild(bar);
    }
    container.appendChild(r);
  }
}

export function setTurnPhase(turn, phase) {
  if (!turn || !turn.root || !turn.root.setAttribute) return;
  if (!turn.root.isConnected) return;
  var cur = turn.root.getAttribute("data-phase");
  if (phase) {
    if (cur === phase) return;
    turn.root.setAttribute("data-phase", phase);
  } else {
    if (cur === null) return;
    turn.root.removeAttribute("data-phase");
  }
}

// One vocabulary for the whole sheet, built on T. Every view is written
// in these, so a control cannot drift into its own spelling of a button or
// label — which is how the page once had two Refresh behaviours and three
// status conventions.
import { icon as iconFn } from "./icons.js";
/* The run-detail panel: the graph's node inspector, the fleet roster's answer,
   the knowledge collection's body and the tool detail all render it, so the
   strings are one surface here. */
export var runDetail = {
  box: "mt-4 rounded-plate-lg border border-rule bg-surface p-4 shadow-[var(--lift-low)]",
  head: "flex items-center justify-between gap-2",
  title: "font-sans text-base font-semibold text-fg",
  meta: "text-fg-muted",
  output: "m-0 max-h-80 overflow-y-auto font-mono text-sm whitespace-pre-wrap text-fg wrap-anywhere empty:before:text-fg-muted empty:before:content-['(nothing recorded for this node)']",
  note: "mb-2 rounded-plate-sm bg-surface-2 px-3 py-1 font-mono text-sm text-fg-muted",
};

/* A view: the column a tab shows. Scrolling, the section rhythm and the focus
   ring are the same in every view, and a plugin's shell is built in
   core/plugins.js, so the list lives here rather than on eleven elements. */
export var VIEW_CLASS = "[&:focus]:outline-none [&:focus-visible]:-outline-offset-2 [&:focus-visible]:outline-2 [&:focus-visible]:outline-accent [&:not([hidden])]:min-h-0 [&:not([hidden])]:w-full [&:not([hidden])]:flex-auto [&:not([hidden])]:overscroll-contain [&:not([hidden])]:overflow-y-auto [&>section]:w-full [&>section]:max-w-none [&>section+section]:mt-6 [&>section+section]:border-t [&>section+section]:border-rule [&>section+section]:pt-4 [&>section:first-child]:mt-0 [&>section:first-child]:border-t-0 [&>section:first-child]:pt-0";

/* The gauge chip: a reading in mono behind a lamp, worn by the masthead's
   status line and by any view that reports one. The lamp itself is a component
   rule (`.chip::before`); the states are attributes, so the sheet reads what
   the script writes. */
export var chip = "chip inline-flex items-center gap-1 [&::before]:hidden rounded-plate-sm border border-rule bg-surface-2 px-2 py-0.5 font-mono text-sm text-fg-muted data-[state=live]:text-ok data-[state=down]:text-danger data-[state=pending]:text-warn data-[state=live]:before:shadow-[var(--lamp-ring),var(--lamp-glow)] data-[state=down]:before:shadow-[var(--lamp-ring),var(--lamp-glow)] data-[state=pending]:before:shadow-[var(--lamp-ring),var(--lamp-glow)]";

/* The rail's channel tab: the eight static ones in the markup and every tab a
   plugin registers wear one class list, so the strip cannot drift into two
   looks. The engaged-channel lamp is a component rule in the sheet. */
export var RAIL_TAB_CLASS = "rail-tab relative flex min-h-10 w-full cursor-pointer appearance-none items-center justify-between gap-2 rounded-plate border border-transparent bg-transparent bg-none px-3 pl-5 text-left font-sans text-sm font-medium text-fg-muted shadow-none hover:bg-surface-2 hover:text-fg focus-visible:outline-2 focus-visible:outline-accent focus-visible:-outline-offset-1 aria-[current=page]:border-rule aria-[current=page]:bg-surface-2 aria-[current=page]:font-semibold aria-[current=page]:text-fg enabled:active:translate-y-px motion-reduce:active:transform-none";

/* The tool-row family: the Tools view, the Fleet roster and the run header
   all show a row of name, description and tags, so the strings live here
   rather than in each of them. */
export var toolRow = {
  group: "mt-4 mb-1 flex w-full cursor-pointer items-center gap-2 border-0 border-t border-rule bg-transparent px-0 py-1 text-left font-sans text-xs font-semibold text-fg-muted hover:text-fg first:mt-0 first:border-t-0",
  groupCaret: "w-[1em] flex-none",
  groupName: "min-w-0 flex-1 truncate",
  groupCount: "font-mono tabular-nums",
  row: "flex flex-wrap items-baseline gap-x-3 gap-y-2 border-b border-rule px-0 py-3 transition-colors hover:rounded-plate hover:bg-surface-2 motion-reduce:transition-none motion-reduce:hover:bg-transparent",
  name: "min-w-36 font-mono text-sm font-bold leading-snug text-fg",
  nameButton: "min-h-0 min-w-36 cursor-pointer border-0 bg-transparent p-0 text-left font-mono text-sm font-bold leading-snug text-fg shadow-none hover:text-accent-text focus-visible:rounded-plate-sm focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1",
  desc: "flex-1 basis-72 font-sans text-sm text-fg-muted wrap-anywhere",
  tag: "rounded-capsule border border-dashed border-rule px-2 font-mono text-sm text-fg-muted",
};

export var UI = {
  button (label, onclick, opts) {
    opts = opts || {};
    var cls = opts.kind === "plain" ? "chip-btn"
      : opts.kind === "primary" ? "primary"
      : opts.kind === "danger" ? "danger"
      : opts.kind === "secondary-danger" ? "secondary danger"
      : "secondary";
    var icon = iconFn || function(){ return document.createElement("span"); };
    var attrs = {
      type: "button",
      class: cls,
      onclick
    };
    if (opts.label) attrs["aria-label"] = opts.label;
    if (opts.title) attrs.title = opts.title;
    if (opts.icon) return T.button(attrs, icon(opts.icon, 14), label || null);
    return T.button(attrs, label || null);
  },
  empty (text) {
    return T.p({ class: "run-empty" }, text);
  },
  meta (text) {
    return T.span({ class: "meta" }, text);
  },
  bar (children) {
    return T.div({ class: "toolbar-actions" }, children);
  },
  head (title, controls) {
    return T.div({ class: "section-head" }, T.h2(title), controls || null);
  }
};
