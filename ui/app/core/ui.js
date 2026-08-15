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

/* PatternFly button bridge (step 4): add pf-v6-c-button + variant modifiers and
   wrap label/icon children without removing cabinet classes yet. */
var pfButtonSkip = {
  "rail-tab": 1, "rail-item": 1, "tool-name": 1, "suggestion": 1,
  "palette-item": 1, "board-header-btn": 1, "rail-pin": 1, "label-picker-item": 1,
  /* Status lamps and model pills are labels, not actuators. Upgrading them to
     pf-m-primary painted the masthead solid PatternFly blue. */
  "chip": 1, "header-model": 1, "model-pill": 1,
  /* Masthead chips and icon chrome: PF plain keeps light-scheme greys that
     ignore cabinet tokens even when --fg-muted is correct. Stay cabinet-native. */
  "chip-btn": 1, "slack-btn-icon": 1, "slack-sidebar-toggle": 1,
};

function pfButtonVariant(el) {
  if (el.classList.contains("secondary") && el.classList.contains("danger")) return "secondary-danger";
  if (el.classList.contains("secondary") || el.classList.contains("scroll-bottom")) return "secondary";
  if (el.classList.contains("danger")) return "danger";
  /* Explicit primary only: submit, .primary, and the rail's New chat CTA. */
  if (el.classList.contains("primary") || el.classList.contains("rail-new") ||
      el.id === "submit" || el.type === "submit") return "primary";
  return "secondary";
}

function looseButtonText(el) {
  var s = "";
  for (var i = 0; i < el.childNodes.length; i++) {
    var n = el.childNodes[i];
    if (n.nodeType === 3) s += n.textContent;
  }
  return s.trim();
}

function wrapPfButtonContent(el) {
  var textSpan = el.querySelector(":scope > .pf-v6-c-button__text");
  var iconSpan = el.querySelector(":scope > .pf-v6-c-button__icon");
  var loose = looseButtonText(el);
  if (textSpan) {
    if (loose) textSpan.textContent = loose;
    for (var i = el.childNodes.length - 1; i >= 0; i--) {
      if (el.childNodes[i].nodeType === 3) el.removeChild(el.childNodes[i]);
    }
    return;
  }
  if (iconSpan) return;
  var svg = el.querySelector("svg");
  var text = loose || (el.textContent || "").trim();
  if (svg && (!text || el.getAttribute("aria-label"))) {
    el.textContent = "";
    var iconWrap = document.createElement("span");
    iconWrap.className = "pf-v6-c-button__icon";
    iconWrap.appendChild(svg);
    el.appendChild(iconWrap);
    return;
  }
  if (!text) return;
  el.textContent = "";
  var span = document.createElement("span");
  span.className = "pf-v6-c-button__text";
  span.textContent = text;
  el.appendChild(span);
}

export function upgradePfButton(el) {
  if (!el || el.tagName !== "BUTTON") return el;
  for (var cls in pfButtonSkip) {
    if (el.classList.contains(cls)) return el;
  }
  /* Composer Run/Cancel must follow --accent/--on-accent across themes; PF
     primary paints a fixed brand blue that survives token remaps. */
  if (el.id === "submit" || el.id === "cancel") return el;
  if (!el.classList.contains("pf-v6-c-button")) {
    var variant = pfButtonVariant(el);
    el.classList.add("pf-v6-c-button");
    if (variant === "plain") el.classList.add("pf-m-plain");
    else if (variant === "secondary") el.classList.add("pf-m-secondary");
    else if (variant === "danger") el.classList.add("pf-m-danger");
    else if (variant === "secondary-danger") el.classList.add("pf-m-secondary", "pf-m-danger");
    else if (variant === "primary") el.classList.add("pf-m-primary");
  }
  wrapPfButtonContent(el);
  return el;
}

export function upgradePfButtons(root) {
  var scope = root || document;
  scope.querySelectorAll("button").forEach(function (btn) { upgradePfButton(btn); });
  return scope;
}

/* PatternFly form bridge (step 5): pf-v6-c-form on forms, pf-v6-c-form-control on
   inputs, pf-v6-c-check on checkbox labels. Cabinet layout classes stay until step 9. */
var pfControlSkip = { hidden: 1, file: 1, button: 1, submit: 1, reset: 1, image: 1 };

export function upgradePfFormControl(el) {
  if (!el) return el;
  var tag = el.tagName;
  if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT") return el;
  if (tag === "INPUT" && pfControlSkip[el.type]) return el;
  if (el.classList.contains("sr-only") || el.getAttribute("aria-hidden") === "true") return el;
  if (el.type === "checkbox" || el.type === "radio") return upgradePfCheckInput(el);
  if (!el.classList.contains("pf-v6-c-form-control")) el.classList.add("pf-v6-c-form-control");
  return el;
}

export function upgradePfCheckInput(input) {
  if (!input || (input.type !== "checkbox" && input.type !== "radio")) return input;
  var label = input.closest("label");
  if (!label && input.id) label = document.querySelector('label[for="' + CSS.escape(input.id) + '"]');
  if (!label) return input;
  label.classList.add("pf-v6-c-check");
  input.classList.add("pf-v6-c-check__input");
  label.querySelectorAll(":scope > span").forEach(function (s) {
    if (!s.classList.contains("pf-v6-c-check__label")) s.classList.add("pf-v6-c-check__label");
  });
  Array.prototype.slice.call(label.childNodes).forEach(function (n) {
    if (n.nodeType !== 3 || !n.textContent.trim()) return;
    var span = document.createElement("span");
    span.className = "pf-v6-c-check__label";
    span.textContent = n.textContent.trim();
    label.replaceChild(span, n);
  });
  return input;
}

export function upgradePfLabel(el) {
  if (!el || el.tagName !== "LABEL" || !el.htmlFor) return el;
  if (el.querySelector("input, textarea, select")) return el;
  if (!el.classList.contains("pf-v6-c-form__label")) el.classList.add("pf-v6-c-form__label");
  return el;
}

export function upgradePfForm(el) {
  if (!el || el.tagName !== "FORM") return el;
  if (el.hidden || el.hasAttribute("hidden")) return el;
  if (!el.classList.contains("pf-v6-c-form")) el.classList.add("pf-v6-c-form");
  return el;
}

export function upgradePfForms(root) {
  var scope = root || document;
  scope.querySelectorAll("form").forEach(upgradePfForm);
  scope.querySelectorAll("input, textarea, select").forEach(upgradePfFormControl);
  scope.querySelectorAll("label[for]").forEach(upgradePfLabel);
  scope.querySelectorAll('input[type="checkbox"], input[type="radio"]').forEach(upgradePfCheckInput);
  return scope;
}

/* PatternFly modal bridge (step 6): backdrop + modal wrapper around overlay-box. */
export function upgradePfOverlay(el) {
  if (!el || !el.classList.contains("overlay")) return el;
  if (!el.classList.contains("pf-v6-c-backdrop")) el.classList.add("pf-v6-c-backdrop");
  var box = el.querySelector(":scope > .overlay-box");
  if (!box) return el;
  var modal = box.parentElement;
  if (!modal.classList.contains("pf-v6-c-modal")) {
    var wrap = document.createElement("div");
    wrap.className = "pf-v6-c-modal";
    if (el.getAttribute("aria-labelledby")) {
      wrap.setAttribute("aria-labelledby", el.getAttribute("aria-labelledby"));
      el.removeAttribute("aria-labelledby");
    }
    if (el.getAttribute("role") === "dialog") {
      wrap.setAttribute("role", "dialog");
      wrap.setAttribute("aria-modal", "true");
      el.removeAttribute("role");
      el.removeAttribute("aria-modal");
    }
    el.insertBefore(wrap, box);
    wrap.appendChild(box);
  }
  if (!box.classList.contains("pf-v6-c-modal-box")) box.classList.add("pf-v6-c-modal-box");
  var head = box.querySelector(":scope > .run-detail-head");
  if (head && !head.classList.contains("pf-v6-c-modal__header")) {
    head.classList.add("pf-v6-c-modal__header");
    var title = head.querySelector(".run-detail-title");
    if (title) title.classList.add("pf-v6-c-modal__title");
  }
  box.querySelectorAll("input, textarea, select").forEach(upgradePfFormControl);
  box.querySelectorAll("label[for]").forEach(upgradePfLabel);
  return el;
}

export function upgradePfOverlays(root) {
  var scope = root || document;
  scope.querySelectorAll(".overlay").forEach(upgradePfOverlay);
  scope.querySelectorAll("dialog.slack-dialog").forEach(function (dlg) {
    var form = dlg.querySelector("form");
    if (form) upgradePfForm(form);
  });
  return scope;
}

/* PatternFly label bridge (step 7): status chips in the masthead and elsewhere. */
export function upgradePfChip(el) {
  if (!el) return el;
  /* Model controls are actuators with a chevron, not status lamps. */
  if (el.classList.contains("model-pill") || el.id === "header-model" || el.id === "composer-model") return el;
  if (!el.classList.contains("chip") && !el.classList.contains("header-model")) return el;
  if (!el.classList.contains("pf-v6-c-label")) el.classList.add("pf-v6-c-label");
  if (!el.querySelector(":scope > .pf-v6-c-label__content")) {
    var text = (el.textContent || "").trim();
    if (text) {
      el.textContent = "";
      var content = document.createElement("span");
      content.className = "pf-v6-c-label__content";
      content.textContent = text;
      el.appendChild(content);
    }
  }
  var state = el.getAttribute("data-state");
  el.classList.remove("pf-m-success", "pf-m-danger", "pf-m-blue", "pf-m-orange");
  if (state === "live") el.classList.add("pf-m-success");
  else if (state === "down") el.classList.add("pf-m-danger");
  else el.classList.add("pf-m-blue");
  return el;
}

export function upgradePfChips(root) {
  var scope = root || document;
  scope.querySelectorAll("#instance-chip, #peers-chip, #session-chip, .chip:not(.model-pill):not(.header-model)").forEach(upgradePfChip);
  return scope;
}

function upgradePfToastNode(node) {
  if (!node || !node.classList.contains("toast")) return node;
  node.classList.add("pf-v6-c-alert", "pf-m-inline", "pf-m-custom");
  if (node.hasAttribute("data-kind")) node.classList.add("pf-m-danger");
  if (!node.querySelector(".pf-v6-c-alert__title")) {
    var title = document.createElement("span");
    title.className = "pf-v6-c-alert__title";
    title.textContent = node.textContent;
    node.textContent = "";
    node.appendChild(title);
  }
  return node;
}

/** Run all PatternFly DOM upgrades (steps 4–7) on static markup and a subtree. */
export function upgradePfUi(root) {
  var scope = root || document;
  upgradePfButtons(scope);
  upgradePfForms(scope);
  upgradePfOverlays(scope);
  upgradePfChips(scope);
  scope.querySelectorAll(".toast").forEach(upgradePfToastNode);
  return scope;
}

// A fixed timer is too short to read a long message, so hovering or
// focusing a toast (mouse or keyboard) holds it on screen.
export function toast(msg, kind) {
  if (!msg || typeof document === "undefined") return null;
  var host = document.getElementById("toasts");
  if (!host) return null;
  var node = document.createElement("div");
  node.className = "toast pf-v6-c-alert pf-m-inline pf-m-custom";
  node.tabIndex = 0;
  node.setAttribute("role", "status");
  node.setAttribute("aria-live", "polite");
  if (kind === "bad" || /fail|error|could not|refus|denied|no such/i.test(msg)) node.setAttribute("data-kind", "bad");
  var title = document.createElement("span");
  title.className = "pf-v6-c-alert__title";
  title.textContent = msg;
  node.appendChild(title);
  upgradePfToastNode(node);
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
    dlg.className = "slack-dialog pf-v6-c-modal-box";
    var form = document.createElement("form");
    form.method = "dialog";
    form.className = "slack-dialog-form pf-v6-c-form pf-v6-c-modal__body";
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
    upgradePfButton(cancel);
    cancel.addEventListener("click", function () { done(false); });
    actions.appendChild(cancel);
    var ok = document.createElement("button");
    ok.type = "button";
    ok.className = opts.danger ? "danger" : "";
    ok.textContent = opts.confirmLabel || "OK";
    upgradePfButton(ok);
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
    upgradePfFormControl(input);
    upgradePfLabel(label);
    var actions = document.createElement("div");
    actions.className = "slack-dialog-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "secondary";
    cancel.textContent = "Cancel";
    upgradePfButton(cancel);
    cancel.addEventListener("click", function () { done(null); });
    actions.appendChild(cancel);
    var ok = document.createElement("button");
    ok.type = "button";
    ok.textContent = opts.confirmLabel || "Save";
    upgradePfButton(ok);
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
    var cls = "pf-v6-c-button ";
    if (opts.kind === "plain") cls += "pf-m-plain chip-btn";
    else if (opts.kind === "primary") cls += "pf-m-primary";
    else if (opts.kind === "danger") cls += "pf-m-danger danger";
    else if (opts.kind === "secondary-danger") cls += "pf-m-secondary pf-m-danger secondary danger";
    else cls += "pf-m-secondary secondary";
    var icon = iconFn || function(){ return document.createElement("span"); };
    var attrs = {
      type: "button",
      class: cls.trim(),
      onclick: onclick
    };
    if (opts.label) attrs["aria-label"] = opts.label;
    if (opts.title) attrs.title = opts.title;
    if (opts.icon) {
      var node = T.button(attrs,
        T.span({ class: "pf-v6-c-button__icon" }, icon(opts.icon, 14)),
        label ? T.span({ class: "pf-v6-c-button__text" }, label) : null);
      return node;
    }
    return T.button(attrs, T.span({ class: "pf-v6-c-button__text" }, label));
  },
  field: function (id, label, control) {
    if (control && control.classList) upgradePfFormControl(control);
    return T.div({ class: "pf-v6-c-form__group" },
      T.label({ class: "pf-v6-c-form__label", for: id }, label),
      T.div({ class: "pf-v6-c-form__group-control" }, control));
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
