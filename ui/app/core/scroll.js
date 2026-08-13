// Vanilla, no bundler. Scroll helpers — near-bottom check and scroll-button state.
export function nearBottom() {
  return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120;
}

export function prefersReducedMotion() {
  return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function syncScrollButton(transcriptEl, scrollButtonEl) {
  var show = !nearBottom() && transcriptEl && transcriptEl.querySelector(".turn") !== null;
  if (scrollButtonEl) scrollButtonEl.hidden = !show;
}
