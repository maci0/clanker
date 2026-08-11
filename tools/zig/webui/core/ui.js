// Vanilla, no bundler. Minimal UI helpers + rail/toast state.
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
// focusing a toast (mouse or keyboard) holds it on screen; it resumes
// counting down once you look away instead of vanishing mid-read.
// app.js's status-observer calls this via window.ckUi.toast, so every
// toast in the app (mutation-observed or direct) goes through one path.
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

if (typeof window !== "undefined") window.ckUi = { bind: bind, toast: toast, skeletonRows: skeletonRows, setTurnPhase: setTurnPhase, T: T };
