// Vanilla, no bundler. Scroll helpers — near-bottom check and scroll-button state.
// Chat owns `.conversation-scroll`. Window scroll is the fallback when that
// column is not in the tree (tests, or a view that still uses the document).
var NEAR_PX = 120;

export function conversationScroller() {
  return document.querySelector("#view-chat .conversation-scroll");
}

export function nearBottom(scroller) {
  var box = scroller || conversationScroller();
  if (box) return box.scrollHeight - box.scrollTop - box.clientHeight < NEAR_PX;
  return window.innerHeight + window.scrollY >= document.body.scrollHeight - NEAR_PX;
}

export function scrollChatToLatest(behavior) {
  var box = conversationScroller();
  var how = behavior || "auto";
  if (box) {
    box.scrollTo({ top: box.scrollHeight, behavior: how });
    return;
  }
  window.scrollTo({ top: document.body.scrollHeight, behavior: how });
}

export function prefersReducedMotion() {
  return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function syncScrollButton(transcriptEl, scrollButtonEl, scroller) {
  var show = !nearBottom(scroller) && transcriptEl && transcriptEl.querySelector(".turn") !== null;
  if (scrollButtonEl) scrollButtonEl.hidden = !show;
}
