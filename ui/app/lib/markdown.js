// Vanilla, no bundler. Pure markdown + code rendering; depends on vendor loadHljs/copyText.
// Imported by app.js; keep exports side-effect free.
import { loadHljs, loadMermaid, copyText } from "../core/vendor.js";
import { isSafeLinkUrl, splitRow, prettyJsonIfPossible } from "../core/utils.js";

export var INLINE_RE = /(`[^`]+`)|(!\[[^\]\n]*\]\([^)\s]+\))|(\*\*[^*]+\*\*)|(\*[^*\n]+\*)|(_[^_\n]+_)|(\[[^\]\n]+\]\([^)\s]+\))|(https?:\/\/[^\s<>()]+)/;
export var CITATION_RE = /[a-zA-Z0-9_.\-\/]+\.(?:zig|ts|js|py|rs|go|md|json|toml|css|html|sh|yaml|yml):\d+(?::\d+)?/g;
export var RUN_RE = /\[subagent run:\s*(?:sub|run)-\d+\]|\b(?:sub|run)-\d+\b(?!\.\w)/g;
function runIdOf(m) {
  var mm = /(sub|run)-\d+/.exec(m);
  return mm ? mm[0] : m;
}
/* Run references (`run-<ts>`, `sub-<ns>`, or the trailing `[subagent run:
   sub-…]` a nested run appends to its answer) become chips that open that
   run's graph, the way file:line citations open the callgraph search. */
export function appendRunRefs(parent, text) {
  RUN_RE.lastIndex = 0;
  var last = 0, m;
  while ((m = RUN_RE.exec(text)) !== null) {
    if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    var ref = m[0];
    var id = runIdOf(ref);
    var chip = document.createElement("button");
    chip.type = "button";
    chip.className = "citation-chip run-chip";
    chip.textContent = id;
    chip.setAttribute("data-run", id);
    chip.title = "Open run " + id;
    chip.setAttribute("aria-label", "Open run " + id);
    (function (rid, el) {
      el.addEventListener("click", function (e) {
        e.preventDefault();
        try {
          if (typeof window !== "undefined" && typeof window.clankerOpenRun === "function") { window.clankerOpenRun(rid); return; }
        } catch (_) {}
        try {
          var rf = document.getElementById("run-filter");
          if (rf) { rf.value = rid; rf.dispatchEvent(new Event("input", { bubbles: true })); }
          var runsTab = document.getElementById("tab-runs");
          if (runsTab) runsTab.click();
        } catch (_) {}
      });
    })(id, chip);
    parent.appendChild(chip);
    last = RUN_RE.lastIndex;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
}

export function appendCitedText(parent, text) {
  var re = CITATION_RE;
  re.lastIndex = 0;
  var last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) appendRunRefs(parent, text.slice(last, m.index));
    var ref = m[0];
    var chip = document.createElement("button");
    chip.type = "button";
    chip.className = "citation-chip";
    chip.textContent = ref;
    chip.setAttribute("data-ref", ref);
    chip.title = "Open in callgraph — " + ref;
    chip.setAttribute("aria-label", "Citation " + ref + " — open in callgraph");
    (function(r, el){
      el.addEventListener("click", function(e){
        e.preventDefault();
        try{
          if (typeof window !== "undefined" && typeof window.clankerOpenCitation === "function") { window.clankerOpenCitation(r); return; }
          var inp = document.querySelector(".run-graph-search input");
          if (inp) { inp.value = r.split(":")[0].split("/").pop().split(".")[0]; inp.dispatchEvent(new Event("input", {bubbles:true})); }
          var rf = document.getElementById("run-filter");
          if (rf) { rf.value = r.split(":")[0]; rf.dispatchEvent(new Event("input", {bubbles:true})); }
          var runsTab = document.getElementById("tab-runs");
          if (runsTab) runsTab.click();
        }catch(_){}
      });
    })(ref, chip);
    parent.appendChild(chip);
    last = re.lastIndex;
  }
  if (last < text.length) appendRunRefs(parent, text.slice(last));
}

export function inlineInto(parent, text) {
  while (text.length) {
    var m = INLINE_RE.exec(text);
    if (!m) { appendCitedText(parent, text); return; }
    if (m.index > 0) appendCitedText(parent, text.slice(0, m.index));
    var tok = m[0], node;
    if (tok.charAt(0) === "`") {
      node = document.createElement("code");
      node.textContent = tok.slice(1, -1);
    } else if (tok.slice(0, 2) === "**") {
      node = document.createElement("strong");
      inlineInto(node, tok.slice(2, -2));
    } else if (tok.charAt(0) === "*" || tok.charAt(0) === "_") {
      var before = m.index > 0 ? text.charAt(m.index - 1) : " ";
      var after = text.charAt(m.index + tok.length) || " ";
      if (tok.charAt(0) === "_" && (/[A-Za-z0-9]/.test(before) || /[A-Za-z0-9]/.test(after))) {
        parent.appendChild(document.createTextNode(tok));
        text = text.slice(m.index + tok.length);
        continue;
      }
      node = document.createElement("em");
      inlineInto(node, tok.slice(1, -1));
    } else if (tok.slice(0, 2) === "![") {
      var isplit = tok.indexOf("](");
      var isrc = tok.slice(isplit + 2, -1);
      if (isSafeLinkUrl(isrc)) {
        node = document.createElement("img");
        node.src = isrc;
        node.alt = tok.slice(2, isplit);
        node.className = "md-img";
        node.loading = "lazy";
      } else {
        node = document.createTextNode(tok);
      }
    } else if (tok.charAt(0) === "[") {
      var split = tok.indexOf("](");
      var href = tok.slice(split + 2, -1);
      if (isSafeLinkUrl(href)) {
        node = document.createElement("a");
        node.href = href;
        node.rel = "noreferrer noopener";
        inlineInto(node, tok.slice(1, split));
      } else {
        node = document.createDocumentFragment();
        inlineInto(node, tok.slice(1, split));
      }
    } else {
      node = document.createElement("a");
      node.href = tok;
      node.rel = "noreferrer noopener";
      node.textContent = tok;
    }
    parent.appendChild(node);
    text = text.slice(m.index + tok.length);
  }
}

export function paragraphInto(parent, lines) {
  lines.forEach(function (line, i) {
    if (i) parent.appendChild(document.createElement("br"));
    inlineInto(parent, line);
  });
}

export function tableRow(tr, cells, cellTag) {
  cells.forEach(function (c) {
    var cell = document.createElement(cellTag);
    inlineInto(cell, c.trim());
    tr.appendChild(cell);
  });
}

/* Which lines open a block, asked once so the block dispatcher and the
   paragraph accumulator cannot disagree about it.

   They did disagree. The accumulator stopped at a heading, a list marker and a
   blockquote, but not at a thematic break or a table, and a model writes both
   directly under the line that introduces them — "Here are the results:" and
   then the table, no blank line between. The dispatcher never got the chance
   to look at those lines because the paragraph had already eaten them, so a
   table rendered as the wall of literal `|` characters this file exists to
   avoid, and `---` as three hyphens mid-sentence. */
export function ruleAt(line) {
  return /^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/.test(line);
}

/* A table is its header plus the `|---|---|` line under it: the header alone
   is just a line with pipes in it, so both are needed to tell one from prose. */
export function tableAt(lines, i) {
  return lines[i].indexOf("|") !== -1 &&
    i + 1 < lines.length &&
    /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1]);
}

export function blockAt(lines, i) {
  var line = lines[i];
  return /^(#{1,6})\s/.test(line) ||
    /^\s*[-*+]\s/.test(line) ||
    /^\s*\d+[.)]\s/.test(line) ||
    /^\s*>/.test(line) ||
    ruleAt(line) ||
    tableAt(lines, i);
}

export function renderMarkdown(text) {
  var frag = document.createDocumentFragment();
  var lines = text.split("\n");
  var i = 0;
  function buildList(ordered, indent) {
    var list = document.createElement(ordered ? "ol" : "ul");
    var li = null;
    var first = true;
    while (i < lines.length) {
      var line = lines[i];
      var m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
      if (!m) break;
      var depth = m[1].length;
      if (depth < indent) break;
      if (depth > indent) {
        var childOrdered = /\d/.test(m[2]);
        var child = buildList(childOrdered, depth);
        (li || list).appendChild(child);
        continue;
      }
      var isOrdered = /\d/.test(m[2]);
      if (isOrdered !== ordered) break;
      if (first && ordered) {
        var startAt = parseInt(m[2], 10);
        if (startAt > 1) list.setAttribute("start", String(startAt));
      }
      first = false;
      li = document.createElement("li");
      var txt = m[3];
      var task = /^\[([ xX])\]\s+(.*)$/.exec(txt);
      if (task) {
        var box = document.createElement("input");
        box.type = "checkbox";
        box.checked = task[1] !== " ";
        box.disabled = true;
        li.className = "md-task";
        li.appendChild(box);
        txt = task[2];
      }
      inlineInto(li, txt);
      list.appendChild(li);
      i += 1;
    }
    return list;
  }
  function flushList(ordered) {
    var indent = /^(\s*)/.exec(lines[i])[1].length;
    frag.appendChild(buildList(ordered, indent));
  }
  while (i < lines.length) {
    var line = lines[i];
    if (!line.trim()) { i += 1; continue; }
    var head = /^(#{1,6})\s+(.*)$/.exec(line);
    if (head) {
      var h = document.createElement("h" + Math.min(6, head[1].length + 2));
      h.className = "md-h";
      inlineInto(h, head[2]);
      frag.appendChild(h);
      i += 1;
      continue;
    }
    if (ruleAt(line)) {
      frag.appendChild(document.createElement("hr"));
      i += 1;
      continue;
    }
    if (/^\s*>\s?/.test(line)) {
      var quote = document.createElement("blockquote");
      var qlines = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
        qlines.push(lines[i].replace(/^\s*>\s?/, ""));
        i += 1;
      }
      paragraphInto(quote, qlines);
      frag.appendChild(quote);
      continue;
    }
    if (/^\s*[-*+]\s+/.test(line)) { flushList(false); continue; }
    if (/^\s*\d+[.)]\s+/.test(line)) { flushList(true); continue; }
    if (tableAt(lines, i)) {
      var table = document.createElement("table");
      table.className = "md-table";
      var thead = document.createElement("thead");
      var htr = document.createElement("tr");
      tableRow(htr, splitRow(line), "th");
      thead.appendChild(htr);
      table.appendChild(thead);
      var tbody = document.createElement("tbody");
      i += 2;
      while (i < lines.length && lines[i].indexOf("|") !== -1 && lines[i].trim()) {
        var btr = document.createElement("tr");
        tableRow(btr, splitRow(lines[i]), "td");
        tbody.appendChild(btr);
        i += 1;
      }
      table.appendChild(tbody);
      var wrap = document.createElement("div");
      wrap.className = "md-table-wrap";
      wrap.appendChild(table);
      frag.appendChild(wrap);
      continue;
    }
    var para = [];
    while (i < lines.length && lines[i].trim() && !blockAt(lines, i)) {
      para.push(lines[i]);
      i += 1;
    }
    var p2 = document.createElement("p");
    p2.className = "md-p";
    paragraphInto(p2, para);
    frag.appendChild(p2);
  }
  return frag;
}

export function highlightInto(codeEl, lang, rawText) {
  var pretty = lang ? null : prettyJsonIfPossible(rawText);
  var text = pretty !== null ? pretty : rawText;
  var effectiveLang = pretty !== null ? "json" : (lang || "");
  codeEl.textContent = text;
  if (effectiveLang) {
    codeEl.className = "language-" + effectiveLang;
    loadHljs().then(function () { try { window.hljs.highlightElement(codeEl); } catch (e) {} }).catch(function () {});
  }
  return { text: text, lang: effectiveLang };
}

export function buildCodeBlock(lang, code) {
  var wrap = document.createElement("div");
  wrap.className = "code-block";
  var pre = document.createElement("pre");
  var codeEl = document.createElement("code");
  var shown = highlightInto(codeEl, lang, code);
  pre.appendChild(codeEl);
  var head = document.createElement("div");
  head.className = "code-head";
  var langTag = document.createElement("span");
  langTag.className = "code-lang";
  langTag.textContent = shown.lang;
  head.appendChild(langTag);
  /* An html or svg fence is both code and output: the source stays
     copyable above, and a Preview toggle renders it below. The content is
     model-generated and untrusted, so the frame is fully sandboxed (no
     scripts, opaque origin) and the page CSP still applies to it — a blob
     URL inherits the creating document's policy, which blocks script
     regardless of what the markup tries. */
  var langNorm = (lang || "").toLowerCase();
  var previewBtn = null;
  var panel = null;
  if (langNorm === "html" || langNorm === "svg") {
    previewBtn = document.createElement("button");
    previewBtn.type = "button";
    previewBtn.className = "copy-code-btn";
    previewBtn.textContent = "Preview";
    previewBtn.setAttribute("aria-expanded", "false");
    panel = document.createElement("div");
    panel.className = "md-preview";
    panel.hidden = true;
    previewBtn.addEventListener("click", function () {
      if (panel.hidden) {
        panel.hidden = false;
        if (!panel.querySelector("iframe")) {
          var fr = document.createElement("iframe");
          fr.setAttribute("sandbox", "");
          fr.title = "Rendered preview of " + langNorm;
          try {
            fr.src = URL.createObjectURL(new Blob([code], { type: langNorm === "svg" ? "image/svg+xml" : "text/html" }));
          } catch (_) {
            fr.srcdoc = code;
          }
          panel.appendChild(fr);
        }
        previewBtn.textContent = "Hide preview";
        previewBtn.setAttribute("aria-expanded", "true");
      } else {
        panel.hidden = true;
        previewBtn.textContent = "Preview";
        previewBtn.setAttribute("aria-expanded", "false");
      }
    });
    head.appendChild(previewBtn);
  }
  var copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "copy-code-btn";
  copyBtn.textContent = "Copy";
  copyBtn.addEventListener("click", function () { copyText(shown.text, copyBtn, "Copy", codeEl); });
  head.appendChild(copyBtn);
  wrap.appendChild(head);
  wrap.appendChild(pre);
  if (panel) wrap.appendChild(panel);
  return wrap;
}

/* A `mermaid` fence renders as a diagram, with the source folded under a
   disclosure the way the turn's thinking is — the diagram is the answer, the
   source is the receipt. The raw code is parked in `data-src` until the
   lazily-loaded renderer replaces it, so Copy answer and Export .md still
   read `markdownSource`, never the rendered SVG. */
export function buildMermaidBlock(code) {
  var wrap = document.createElement("div");
  wrap.className = "code-block mermaid-block";
  var box = document.createElement("div");
  box.className = "md-mermaid";
  box.setAttribute("data-src", code);
  box.textContent = "Diagram\u2026";
  box.setAttribute("aria-label", "Diagram loading");
  wrap.appendChild(box);
  var src = document.createElement("details");
  src.className = "mermaid-src";
  var sum = document.createElement("summary");
  sum.textContent = "source";
  var pre = document.createElement("pre");
  pre.textContent = code;
  src.appendChild(sum);
  src.appendChild(pre);
  wrap.appendChild(src);
  return wrap;
}

/* Renders every .md-mermaid in a subtree once the (lazily fetched) renderer
   is in. Dark/light picks the mermaid theme from the page's data-theme so a
   diagram on a night-shift palette is not a white island. Strict security
   keeps diagram text inert under the page's own CSP. */
export function renderMermaidBlocks(root) {
  var boxes = root.querySelectorAll(".md-mermaid");
  if (!boxes.length) return;
  loadMermaid().then(function () {
    var dt = (document.documentElement && document.documentElement.getAttribute("data-theme")) || "";
    var dark = !(/light|system/.test(dt));
    window.mermaid.initialize({
      startOnLoad: false,
      theme: dark ? "dark" : "default",
      securityLevel: "strict",
      fontFamily: "var(--mono)"
    });
    boxes.forEach(function (box) {
      var code = box.getAttribute("data-src") || "";
      var id = "mm-" + Math.random().toString(36).slice(2, 10);
      window.mermaid.render(id, code).then(function (res) {
        // Mermaid ships its theme as a <style> element inside the SVG, which
        // the page's CSP forbids (style-src 'self'). Strip it and let the
        // app's own .md-mermaid rules theme the diagram — every palette the
        // page knows sets the same variables, so the diagram follows along.
        // The node is imported rather than re-parsed (innerHTML) so the
        // structural style="" attributes mermaid sets survive without tripping
        // the CSP's inline-style check a second time.
        var doc = new DOMParser().parseFromString(res.svg, "image/svg+xml");
        doc.querySelectorAll("style").forEach(function (st) { st.remove(); });
        box.appendChild(box.ownerDocument.importNode(doc.documentElement, true));
        box.setAttribute("aria-label", "Mermaid diagram");
        box.removeAttribute("data-src");
      }).catch(function (err) {
        box.classList.add("md-mermaid-error");
        box.textContent = "Diagram failed to render: " + ((err && err.message) || err);
        box.setAttribute("role", "alert");
      });
    });
  }).catch(function () {
    boxes.forEach(function (box) {
      box.classList.add("md-mermaid-error");
      box.textContent = "Could not load the diagram renderer.";
      box.setAttribute("role", "alert");
    });
  });
}

/* Markdown with ``` fences split out as real code/mermaid blocks instead of
   inline `renderMarkdown` text — the one fence-aware renderer, shared by the
   chat transcript (`finalizeAnswer`) and anything else that shows a whole
   markdown document (e.g. the files plugin's viewer) so the two never grow
   two different ideas of what a fence is. */
export function renderMarkdownWithFences(raw) {
  var frag = document.createDocumentFragment();
  var re = /```([a-zA-Z0-9_+-]*)\n?([\s\S]*?)(?:```|$)/g;
  var last = 0, m;
  while ((m = re.exec(raw))) {
    if (m[0] === "") break;
    if (m.index > last) frag.appendChild(renderMarkdown(raw.slice(last, m.index)));
    frag.appendChild(m[1].toLowerCase() === "mermaid" ? buildMermaidBlock(m[2].replace(/\n$/, "")) : buildCodeBlock(m[1], m[2].replace(/\n$/, "")));
    last = re.lastIndex;
  }
  if (last < raw.length) frag.appendChild(renderMarkdown(raw.slice(last)));
  return frag;
}

export function finalizeAnswer(turn) {
  if (turn.answer.querySelector(".failed")) return;
  var raw = turn.root.markdownSource || turn.answer.textContent;
  if (!raw) return;
  turn.answer.textContent = "";
  turn.answer.className = "turn-answer md";
  turn.answer.appendChild(renderMarkdownWithFences(raw));
  renderMermaidBlocks(turn.answer);
}


