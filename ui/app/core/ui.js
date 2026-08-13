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
  get: function (_, name) {
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

// A fixed timer is too short to read a long message, so hovering or
// focusing a toast (mouse or keyboard) holds it on screen.
export function toast(msg, kind) {
  if (!msg || typeof document === "undefined") return null;
  var host = document.getElementById("toasts");
  if (!host) return null;
  var node = document.createElement("p");
  node.className = "toast";
  node.tabIndex = 0;
  node.setAttribute("role", "status");
  node.setAttribute("aria-live", "polite");
  if (kind === "bad" || /fail|error|could not|refus|denied|no such/i.test(msg)) node.setAttribute("data-kind", "bad");
  node.textContent = msg;
  node.addEventListener("click", function () { node.remove(); });
  node.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" && event.key !== " " && event.key !== "Escape") return;
    event.preventDefault();
    node.remove();
  });
  node.setAttribute("aria-label", msg + ". Press Enter, Space, or Escape to dismiss.");
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
    dlg.className = "slack-dialog";
    var form = document.createElement("form");
    form.method = "dialog";
    form.className = "slack-dialog-form";
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

export function uiConfirm(message, opts) {
  opts = opts || {};
  return openDialog(function (form, done) {
    var p = document.createElement("p");
    p.className = "ui-dialog-message";
    p.textContent = message;
    form.appendChild(p);
    var actions = document.createElement("div");
    actions.className = "slack-dialog-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "secondary";
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", function () { done(false); });
    actions.appendChild(cancel);
    var ok = document.createElement("button");
    ok.type = "button";
    ok.className = opts.danger ? "danger" : "";
    ok.textContent = opts.confirmLabel || "OK";
    ok.addEventListener("click", function () { done(true); });
    actions.appendChild(ok);
    form.appendChild(actions);
    window.setTimeout(function () { (opts.danger ? cancel : ok).focus(); }, 0);
  }).then(function (v) { return v === true; });
}

export function uiPrompt(message, initial, opts) {
  opts = opts || {};
  return openDialog(function (form, done) {
    var label = document.createElement("label");
    label.className = "ui-dialog-message";
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
      input.className = "ui-dialog-textarea";
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); done(input.value); }
      });
    } else {
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); done(input.value); }
      });
    }
    form.appendChild(input);
    var actions = document.createElement("div");
    actions.className = "slack-dialog-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "secondary";
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", function () { done(null); });
    actions.appendChild(cancel);
    var ok = document.createElement("button");
    ok.type = "button";
    ok.textContent = opts.confirmLabel || "Save";
    ok.addEventListener("click", function () { done(input.value); });
    actions.appendChild(ok);
    form.appendChild(actions);
    window.setTimeout(function () { input.focus(); input.select(); }, 0);
  });
}

export function skeletonRows(container, n) {
  if (!container) return;
  container.textContent = "";
  container.setAttribute("aria-busy", "true");
  for (var i = 0; i < n; i++) {
    var row = document.createElement("div");
    row.className = "skeleton";
    container.appendChild(row);
    var r = document.createElement("div");
    r.className = "skeleton-row";
    for (var j = 0; j < 3; j++) {
      var bar = document.createElement("div");
      bar.className = "skeleton-bar";
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
export var UI = {
  button: function (label, onclick, opts) {
    opts = opts || {};
    var cls = "secondary";
    if (opts.kind === "danger") cls += " danger";
    var icon = iconFn || function(){ return document.createElement("span"); };
    var attrs = {
      type: "button",
      class: opts.kind === "primary" ? "" : cls,
      onclick: onclick
    };
    if (opts.label) attrs["aria-label"] = opts.label;
    if (opts.title) attrs.title = opts.title;
    if (opts.icon) return T.button(attrs, icon(opts.icon, 14), label);
    return T.button(attrs, label);
  },
  field: function (id, label, control) {
    return [T.label({ for: id }, label), control];
  },
  empty: function (text) {
    return T.p({ class: "run-empty" }, text);
  },
  meta: function (text) {
    return T.span({ class: "meta" }, text);
  },
  bar: function (children) {
    return T.div({ class: "toolbar-actions" }, children);
  },
  head: function (title, controls) {
    return T.div({ class: "section-head" }, T.h2(title), controls || null);
  }
};
