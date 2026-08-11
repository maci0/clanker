// Vanilla, no bundler. Generic overlay helpers — no app state, no `el`.
export var lastFocus = null;

export function openOverlay(node, toFocus) {
  lastFocus = document.activeElement;
  node.hidden = false;
  if (toFocus) toFocus.focus();
}

export function closeOverlay(node) {
  node.hidden = true;
  if (lastFocus && lastFocus.focus) lastFocus.focus();
  lastFocus = null;
}

/* aria-modal="true" claims the rest of the page is unreachable while a dialog
   is open, but nothing enforced that: Tab could walk off the last button in
   the box and land on rail/header controls sitting under the scrim. This
   wraps Tab back to the other end of the dialog instead. */
export function focusableIn(node) {
  return Array.prototype.slice
    .call(node.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'))
    .filter(function (n) { return n.getClientRects().length > 0; });
}

export function trapOverlayTab(e, node) {
  var items = focusableIn(node);
  if (!items.length) { e.preventDefault(); return; }
  var first = items[0], last = items[items.length - 1];
  var atEdge = e.shiftKey ? (document.activeElement === first || !node.contains(document.activeElement))
    : (document.activeElement === last || !node.contains(document.activeElement));
  if (atEdge) {
    e.preventDefault();
    (e.shiftKey ? last : first).focus();
  }
}
