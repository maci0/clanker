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
/* `summary` is in this list because the browser puts it in the tab order on its
   own: a disclosure fold inside a dialog was a tab stop the trap did not know
   about, so Tab from the control before it walked off the end of the dialog and
   into the page under the scrim, which is exactly what the trap exists to stop.
   Every element matched here is a native tab stop, so nothing is added that a
   keyboard user cannot already reach. */
export function focusableIn(node) {
  return Array.prototype.slice
    .call(node.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]:not([tabindex="-1"])'))
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
