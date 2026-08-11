// Vanilla, no bundler. Transcript search helpers — DOM helpers, no app state.
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
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  var targets = [];
  var node;
  while ((node = walker.nextNode())) {
    if (node.nodeValue.toLowerCase().indexOf(needle) !== -1) targets.push(node);
  }
  var hits = 0;
  targets.forEach(function (text) {
    var value = text.nodeValue;
    var frag = document.createDocumentFragment();
    var at = 0;
    var idx = value.toLowerCase().indexOf(needle, at);
    while (idx !== -1) {
      if (idx > at) frag.appendChild(document.createTextNode(value.slice(at, idx)));
      var mark = document.createElement("mark");
      mark.textContent = value.substr(idx, needle.length);
      frag.appendChild(mark);
      hits += 1;
      at = idx + needle.length;
      idx = value.toLowerCase().indexOf(needle, at);
    }
    if (at < value.length) frag.appendChild(document.createTextNode(value.slice(at)));
    text.parentNode.replaceChild(frag, text);
  });
  return hits;
}
