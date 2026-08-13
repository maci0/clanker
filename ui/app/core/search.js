// Vanilla, no bundler. Transcript search helpers — DOM helpers, no app state.
import { searchFoldFind } from "./utils.js";

/* A search hit names a *message* index, and the transcript is drawn in turns:
   one question plus everything answered before the next question, so a turn
   covers a run of message indices rather than one. `spans` is what
   renderSessionHistory recorded — `{ from, to }` per rendered turn, in order —
   and this is the lookup back.

   Pure, and total: an index past the end (a conversation that grew since the
   search, or a transcript the server trimmed) resolves to the last turn rather
   than to nothing, because scrolling to roughly the right place beats
   silently not moving. -1 only when there are no turns at all. */
export function turnForMessage(spans, index) {
  if (!spans || !spans.length) return -1;
  if (typeof index !== "number" || !isFinite(index) || index < 0) return -1;
  for (var i = 0; i < spans.length; i++) {
    if (index >= spans[i].from && index <= spans[i].to) return i;
  }
  return spans.length - 1;
}

export function clearMarks(root) {
  var marks = root.querySelectorAll("mark");
  Array.prototype.forEach.call(marks, function (m) {
    var text = document.createTextNode(m.textContent);
    m.parentNode.replaceChild(text, m);
  });
  // Splitting a text node to highlight leaves neighbours behind; rejoining
  // them keeps repeated searches from fragmenting the answer into hundreds
  // of nodes.
  if (root.normalize) root.normalize();
}

export function markMatches(root, needle) {
  if (!needle) return 0;
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  var targets = [];
  var node;
  while ((node = walker.nextNode())) {
    if (searchFoldFind(node.nodeValue, needle) !== null) targets.push(node);
  }
  var hits = 0;
  targets.forEach(function (text) {
    var value = text.nodeValue;
    var frag = document.createDocumentFragment();
    var origFrom = 0;
    var foldFrom = 0;
    for (;;) {
      var hit = searchFoldFind(value, needle, foldFrom);
      if (!hit) break;
      if (hit.start > origFrom) frag.appendChild(document.createTextNode(value.slice(origFrom, hit.start)));
      var mark = document.createElement("mark");
      mark.textContent = value.slice(hit.start, hit.end);
      frag.appendChild(mark);
      hits += 1;
      origFrom = hit.end;
      foldFrom = hit.next;
    }
    if (origFrom < value.length) frag.appendChild(document.createTextNode(value.slice(origFrom)));
    text.parentNode.replaceChild(frag, text);
  });
  return hits;
}
