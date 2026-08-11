// Vanilla, no bundler. UI primitives: VanJS tags, binding, toasts, skeletons,
// component vocabulary, and the sheet's one visual language for controls.
// Extracted from app.js so every view shares the same spelling; the module
// bridges onto window.ckUi because app.js is still a classic script that
// cannot import (the bridge dies with the last classic script).

export var T = (typeof window !== "undefined" && window.van && window.van.tags) ? window.van.tags : null;

export function bind(node, state, render) {
  if (typeof window === "undefined" || !window.van || !window.van.derive) return;
  window.van.derive(function () {
    var value = state.val;
    node.textContent = "";
    var built = render(value);
    if (built == null) return;
    if (Array.isArray(built)) built.forEach(function (n) { if (n) window.van.add(node, n); });
    else window.van.add(node, built);
  });
}

// A fixed timer is too short to read a long message, so hovering or
// focusing a toast (mouse or keyboard) holds it on screen.
export function toast(msg, kind) {
  if (!msg || typeof document === "undefined") return;
  var host = document.getElementById("toasts");
  if (!host) return;
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
  function schedule() { timer = window.setTimeout(function () { node.remove(); }, 5000); }
  node.addEventListener("mouseenter", function () { window.clearTimeout(timer); });
  node.addEventListener("mouseleave", schedule);
  node.addEventListener("focusin", function () { window.clearTimeout(timer); });
  node.addEventListener("focusout", schedule);
  host.appendChild(node);
  while (host.children.length > 3) host.removeChild(host.firstChild);
  schedule();
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

// One vocabulary for the whole sheet, built on VanJS. Every view is written
// in these, so a control cannot drift into its own spelling of a button or
// label — which is how the page once had two Refresh behaviours and three
// status conventions.
export var UI = {
  button: function (label, onclick, opts) {
    opts = opts || {};
    var cls = "secondary";
    if (opts.kind === "danger") cls += " danger";
    var icon = window.ckIcons && window.ckIcons.icon ? window.ckIcons.icon : function(){ return document.createElement("span"); };
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

if (typeof window !== "undefined") window.ckUi = { bind: bind, toast: toast, skeletonRows: skeletonRows, setTurnPhase: setTurnPhase, T: T, UI: UI };
