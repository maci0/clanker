/* files: workspace file browser with split-pane preview.

   Left pane: directory listing with filter, sort, and keyboard navigation.
   Right pane: file preview — markdown (with mermaid fences), source code
   (syntax-highlighted via hljs), or plain text. On narrow screens the panes
   stack vertically.

   Security: every server-supplied string (names, paths, content) attaches via
   textContent. SVG icon paths are all hardcoded here. File content goes
   through api.render.markdown / api.render.code which treat input as data. */

// ─── the listing's shapes ─────────────────────────────────────────────────────
/* Utilities over the cabinet tokens, named because a row, a crumb and a
   filename button each appear in more than one place. The host paints a bare
   `button` as the UA's grey box and `button.primary` as the 40px accent pill,
   so every control here states its own shape from PLAIN_BTN up.

   The one state a utility cannot reach is "the panes when the preview is
   open": that was `:has(.files-right:not([hidden]))` on the parent, so the JS
   sets `data-preview` on the panes beside the pane's own `hidden`. */
var PLAIN_BTN = "bg-transparent p-0 shadow-none text-inherit";
var CRUMB_CLASS = "inline-flex min-h-7 min-w-0 cursor-pointer items-center whitespace-nowrap rounded-plate-sm border border-transparent px-1 py-0.5 font-mono text-xs font-medium text-fg-muted hover:border-accent hover:text-accent max-[40rem]:min-h-11 " + PLAIN_BTN;
var CRUMB_HERE_CLASS = "inline-flex min-h-7 min-w-0 items-center whitespace-nowrap rounded-plate-sm border border-transparent px-1 py-0.5 font-mono text-xs font-semibold text-fg " + PLAIN_BTN;
var SORT_CLASS = "min-h-7 min-w-0 cursor-pointer justify-self-stretch whitespace-nowrap rounded-none border-0 px-1 py-0.5 text-left font-sans text-xs font-semibold text-fg-muted hover:text-fg data-[active=1]:text-accent max-[40rem]:min-h-11 " + PLAIN_BTN;
var OPEN_CLASS = "block min-h-7 w-full cursor-pointer rounded-none border-0 py-1 text-left font-mono text-xs font-medium text-fg wrap-anywhere break-all hover:text-accent max-[40rem]:min-h-11 " + PLAIN_BTN;
var CLEAR_CLASS = "inline min-h-0 min-w-0 cursor-pointer font-sans text-xs text-accent-text underline underline-offset-2 hover:text-accent focus-visible:text-accent " + PLAIN_BTN;
var CRUMBS_CLASS = "mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 rounded-plate-sm border border-rule bg-surface-2 px-3 py-2 font-mono text-xs";
var PANES_CLASS = "grid w-full items-start gap-3 grid-cols-[minmax(0,1fr)] data-[preview=open]:grid-cols-[minmax(16rem,1fr)_minmax(18rem,1.15fr)] max-[700px]:grid-cols-[minmax(0,1fr)]";
var ROW_CLASS = "grid cursor-pointer grid-cols-[1.5rem_minmax(8rem,1fr)_6.5rem_10rem] items-center gap-2 rounded-plate-sm border border-transparent bg-surface-2 px-2 py-1 text-xs transition-colors hover:border-rule focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 aria-selected:border-accent aria-selected:bg-accent-dim max-[40rem]:min-h-11 max-[40rem]:grid-cols-[1.5rem_minmax(0,1fr)]";
/* The header line is the same grid without the plate: no fill, one rule under it. */
var HEADER_ROW_CLASS = "mb-1 grid grid-cols-[1.5rem_minmax(8rem,1fr)_6.5rem_10rem] items-center gap-2 rounded-plate-sm border-x-0 border-t-0 border-b border-rule bg-transparent px-2 pt-0 pb-1 text-xs max-[40rem]:grid-cols-[1.5rem_minmax(0,1fr)]";
var LIST_CLASS = "flex max-h-[70vh] flex-col gap-0.5 overflow-y-auto overscroll-contain rounded-plate-sm outline-none focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-2";
var EMPTY_CLASS = "mt-3 text-xs text-fg-muted";
var CELL_CLASS = "text-right font-mono text-xs text-fg-muted tabular-nums whitespace-nowrap max-[40rem]:hidden";
var VIEWER_CLASS = "max-h-[70vh] overflow-x-auto overflow-y-auto rounded-b-plate-sm border border-t-0 border-rule bg-surface p-3";
var NOTE_CLASS = "m-0 border-x border-rule bg-surface-2 px-3 py-1 text-xs text-fg-muted";
var PLAIN_PRE_CLASS = "m-0 whitespace-pre-wrap wrap-anywhere font-mono text-xs text-fg";
var ICON_CLASS = "h-4 w-4 flex-shrink-0";

// ─── DOM helper ───────────────────────────────────────────────────────────────
function mk(tag, cls, txt) {
  var el = document.createElement(tag);
  if (cls) el.className = cls;
  if (txt != null) el.textContent = txt;
  return el;
}

// ─── language / extension maps ────────────────────────────────────────────────
var LANG = {
  zig:"zig", js:"javascript", mjs:"javascript", cjs:"javascript",
  ts:"typescript", tsx:"typescript", jsx:"javascript",
  py:"python", rs:"rust", go:"go",
  c:"c", h:"c", cpp:"cpp", hpp:"cpp", cc:"cpp",
  java:"java", rb:"ruby", php:"php", kt:"kotlin", swift:"swift",
  sh:"bash", bash:"bash", zsh:"bash", fish:"bash",
  json:"json", toml:"ini", yaml:"yaml", yml:"yaml",
  css:"css", scss:"css", less:"css",
  html:"xml", xml:"xml", svg:"xml",
  sql:"sql", lua:"lua", r:"r",
  ex:"elixir", exs:"elixir", erl:"erlang",
  hs:"haskell", ml:"ocaml", clj:"clojure",
};
var MD = {md:1, markdown:1, mdx:1};

// file-type → accent color
var COLOR = {
  dir: "var(--warn)",
  zig: "var(--accent-text)", js: "var(--accent-text)", mjs: "var(--accent-text)",
  ts: "var(--accent-text)", tsx: "var(--accent-text)", jsx: "var(--accent-text)",
  py: "var(--accent-text)", rs: "var(--fg)", go: "var(--accent-text)",
  c: "var(--fg-muted)", h: "var(--fg-muted)", cpp: "var(--fg)", java: "var(--fg)",
  rb: "var(--danger)", md: "var(--fg)", markdown: "var(--fg)",
  mdx: "var(--fg)", json: "var(--fg-muted)", toml: "var(--fg-muted)",
  yaml: "var(--fg-muted)", yml: "var(--fg-muted)", css: "var(--accent-text)",
  scss: "var(--accent-text)", html: "var(--fg)", xml: "var(--fg)",
  svg: "var(--warn)", sh: "var(--ok)", bash: "var(--ok)", zsh: "var(--ok)",
  wasm: "var(--accent-text)", sql: "var(--warn)", lock: "var(--fg-muted)",
};

function extOf(n) {
  if (/\.(lock\.json|lockb)$/.test(n)) return "lock";
  var d = n.lastIndexOf(".");
  return d < 0 ? "" : n.slice(d+1).toLowerCase();
}
function accentOf(name, isDir) {
  return isDir ? COLOR.dir : (COLOR[extOf(name)] || "var(--fg-muted)");
}

// ─── SVG icons (paths hardcoded, never from server) ───────────────────────────
function svgIcon(paths) {
  var s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox","0 0 16 16");
  s.setAttribute("aria-hidden","true");
  s.setAttribute("class",ICON_CLASS);
  paths.forEach(function(d) {
    var p = document.createElementNS("http://www.w3.org/2000/svg","path");
    p.setAttribute("d", d);
    p.setAttribute("fill","currentColor");
    s.appendChild(p);
  });
  return s;
}

// folder (filled)
var I_DIR  = ["M2 4.25C2 3.56 2.56 3 3.25 3h2.84l1.66 1.5h5C13.44 4.5 14 5.06 14 5.75v6C14 12.44 13.44 13 12.75 13H3.25C2.56 13 2 12.44 2 11.75z"];
// generic document with folded corner
var I_FILE = ["M3.75 0A1.75 1.75 0 0 0 2 1.75v12.5c0 .966.784 1.75 1.75 1.75h8.5A1.75 1.75 0 0 0 14 14.25V4.5L9.5 0zM9.5 1.5 12.5 4.5H9.5z"];
// code brackets </>
var I_CODE = ["M4.72 3.22a.75.75 0 0 1 1.06 1.06L3.06 7l2.72 2.72a.75.75 0 1 1-1.06 1.06L1.47 7.53a.75.75 0 0 1 0-1.06zm6.56 0a.75.75 0 0 0-1.06 1.06L12.94 7l-2.72 2.72a.75.75 0 0 0 1.06 1.06l3.25-3.25a.75.75 0 0 0 0-1.06z"];
// markdown M↓
var I_MD   = ["M1.75 3A1.75 1.75 0 0 0 0 4.75v6.5C0 12.22.784 13 1.75 13h12.5A1.75 1.75 0 0 0 16 11.25v-6.5A1.75 1.75 0 0 0 14.25 3zm.5 1.5h11.5a.25.25 0 0 1 .25.25v6.5a.25.25 0 0 1-.25.25H2.25A.25.25 0 0 1 2 11.25v-6.5A.25.25 0 0 1 2.25 4.5z","M4 9.5V6l2 2 2-2v3.5H9.5V5.5h-1L7 7 5.5 5.5h-1V9.5zm8-2.5-1.5 1.5L9 7v2.5h1.5V8l1 1 1-1v1.5H14V7z"];

function fileIcon(name, isDir) {
  var ext = extOf(name);
  var el = svgIcon(isDir ? I_DIR : MD[ext] ? I_MD : LANG[ext] ? I_CODE : I_FILE);
  el.style.color = accentOf(name, isDir);
  return el;
}

// ─── plugin ───────────────────────────────────────────────────────────────────
clanker.registerView({
  id: "files",
  title: "Files",
  group: "Work",

  mount: function (container, api) {

    // ── state ──
    var cur = { path:"", root:"workspace", parent:"", atRoot:true };
    var generation = 0;
    var allEntries = [];
    var filterText = "";
    var showHidden = false;
    var sortKey = "name";   // "name" | "size" | "mtime"
    var sortDir = 1;        // 1 asc, -1 desc
    var focusIdx = -1;
    var openPath = "";

    // ── chrome ──
    var head = mk("div", "section-head");
    var title = mk("h2", null, this.title || "Files");
    head.appendChild(title);
    container.appendChild(head);

    var crumbs = mk("nav", CRUMBS_CLASS);
    crumbs.setAttribute("aria-label", "Breadcrumb");
    container.appendChild(crumbs);

    var toolbar = mk("div", "mb-3 flex flex-wrap items-center gap-2");

    var filterInput = mk("input", "min-w-24 flex-1 basis-40");
    filterInput.type = "search";
    filterInput.placeholder = "Filter by name…";
    filterInput.setAttribute("aria-label", "Filter entries");
    toolbar.appendChild(filterInput);

    var hiddenBtn = mk("button", "secondary font-mono tracking-label data-[active=1]:border-accent data-[active=1]:text-accent", "Hidden");
    hiddenBtn.type = "button";
    hiddenBtn.title = "Show hidden files";
    hiddenBtn.setAttribute("aria-pressed","false");
    hiddenBtn.setAttribute("aria-label","Toggle hidden files");
    toolbar.appendChild(hiddenBtn);

    var upBtn = mk("button", "secondary", "↑ Up");
    upBtn.type = "button";
    upBtn.setAttribute("aria-label","Go up one directory");
    toolbar.appendChild(upBtn);

    var refreshBtn = mk("button", "secondary", "Refresh");
    refreshBtn.type = "button";
    refreshBtn.setAttribute("aria-label","Refresh");
    toolbar.appendChild(refreshBtn);

    container.appendChild(toolbar);

    // ── column headers ──
    var sortBtns = {};
    function makeSortBtn(label, key, align) {
      var btn = mk("button", SORT_CLASS + (align === "right" ? " text-right" : ""), label);
      btn.type = "button";
      btn.addEventListener("click", function() {
        if (btn.dataset.active) sortDir *= -1; else sortDir = 1;
        sortKey = key;
        refreshSort();
        renderEntries();
      });
      sortBtns[key] = btn;
      return btn;
    }

    function refreshSort() {
      Object.keys(sortBtns).forEach(function(k) {
        var btn = sortBtns[k];
        var active = k === sortKey;
        btn.className = SORT_CLASS;
        // The two numeric columns right-align; the header line and the rows
        // carry the same alignment so the columns read as columns.
        if (k === "size" || k === "mtime") btn.className += " text-right";
        btn.dataset.active = active ? "1" : "";
        btn.textContent = ({ name:"Name", size:"Size", mtime:"Modified" })[k]
          + (active ? (sortDir > 0 ? " ▴" : " ▾") : "");
      });
    }

    // ── split panes ──
    var panes = mk("div", PANES_CLASS);

    // left: listing
    var leftPane = mk("div", "min-w-0");
    var hdrRow = mk("div", HEADER_ROW_CLASS);
    hdrRow.appendChild(mk("span", "flex items-center justify-center"));
    hdrRow.appendChild(makeSortBtn("Name","name"));
    hdrRow.appendChild(makeSortBtn("Size","size","right"));
    hdrRow.appendChild(makeSortBtn("Modified","mtime","right"));
    leftPane.appendChild(hdrRow);

    var list = mk("div", LIST_CLASS);
    list.setAttribute("role","listbox");
    list.setAttribute("aria-label","Directory entries");
    list.setAttribute("tabindex","0");
    leftPane.appendChild(list);

    var emptyMsg = mk("p", EMPTY_CLASS, "This folder is empty.");
    emptyMsg.hidden = true;
    leftPane.appendChild(emptyMsg);

    // right: preview
    var rightPane = mk("div", "min-w-0");
    rightPane.hidden = true;
    // The panes read their own width from this: a `:has()` on the child's
    // [hidden] is the one thing a utility cannot express.
    panes.dataset.preview = "";

    var vHead = mk("div", "flex flex-wrap items-center gap-2 rounded-t-plate-sm border border-rule bg-surface-2 px-3 py-2");
    var vName = mk("span", "min-w-0 flex-1 basis-32 font-mono text-xs font-semibold text-fg wrap-anywhere");
    var vMeta = mk("span", "font-mono text-xs text-fg-muted whitespace-nowrap");
    var copyBtn = mk("button", "secondary text-xs", "Copy path");
    copyBtn.type = "button";
    var closeBtn = mk("button", "secondary text-sm leading-none", "Close");
    closeBtn.type = "button";
    closeBtn.setAttribute("aria-label","Close preview");
    vHead.appendChild(vName);
    vHead.appendChild(vMeta);
    vHead.appendChild(copyBtn);
    vHead.appendChild(closeBtn);
    rightPane.appendChild(vHead);

    var vNote = mk("p", NOTE_CLASS);
    vNote.hidden = true;
    rightPane.appendChild(vNote);

    var vBody = mk("div", VIEWER_CLASS);
    rightPane.appendChild(vBody);

    panes.appendChild(leftPane);
    panes.appendChild(rightPane);
    container.appendChild(panes);

    // ── entry rendering ──
    function visibleEntries() {
      var ft = filterText;
      return allEntries.filter(function(e) {
        if (!showHidden && e.name.charAt(0) === ".") return false;
        return !ft || e.name.toLowerCase().indexOf(ft) >= 0;
      }).sort(function(a, b) {
        if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
        var av, bv;
        if (sortKey === "size") { av = a.size||0; bv = b.size||0; }
        else if (sortKey === "mtime") { av = a.mtime||0; bv = b.mtime||0; }
        else { av = a.name.toLowerCase(); bv = b.name.toLowerCase(); }
        return av < bv ? -sortDir : av > bv ? sortDir : 0;
      });
    }

    function renderEntries() {
      focusIdx = -1;
      list.textContent = "";
      var entries = visibleEntries();
      var hiddenCount = 0;
      if (!showHidden && !filterText) {
        allEntries.forEach(function(e) { if (e.name.charAt(0) === ".") hiddenCount += 1; });
      }
      emptyMsg.hidden = true;
      if (!entries.length) {
        if (filterText) {
          var none = mk("p", EMPTY_CLASS);
          none.appendChild(document.createTextNode("No matches for “" + filterText + "”. "));
          var clear = mk("button", CLEAR_CLASS, "Clear filter");
          clear.type = "button";
          clear.addEventListener("click", function() {
            filterInput.value = "";
            filterText = "";
            renderEntries();
            filterInput.focus();
          });
          none.appendChild(clear);
          list.appendChild(none);
        } else if (hiddenCount) {
          var hidden = mk("p", EMPTY_CLASS);
          hidden.appendChild(document.createTextNode(
            hiddenCount === 1 ? "This folder has 1 hidden item. " : "This folder has " + hiddenCount + " hidden items. "
          ));
          var show = mk("button", CLEAR_CLASS, "Show hidden");
          show.type = "button";
          show.addEventListener("click", function() { hiddenBtn.click(); });
          hidden.appendChild(show);
          list.appendChild(hidden);
        } else if (cur.atRoot) {
          emptyMsg.hidden = false;
        } else {
          var empty = mk("p", EMPTY_CLASS);
          empty.appendChild(document.createTextNode("This folder is empty. "));
          var up = mk("button", CLEAR_CLASS, "Go up");
          up.type = "button";
          up.addEventListener("click", function() { upBtn.click(); });
          empty.appendChild(up);
          list.appendChild(empty);
        }
        return;
      }
      entries.forEach(function(e, i) {
        var row = mk("div", ROW_CLASS);
        row.setAttribute("role","option");
        row.setAttribute("aria-selected","false");
        /* Rows carry tabindex=-1 so setFocus()'s .focus() actually moves
           focus: without it the div never becomes focusable, arrows moved the
           highlight and aria-selected but neither the visible focus ring nor
           a screen reader's focus followed, so the listbox read as
           "no selection feedback" to keyboard and AT users. Same roving-focus
           contract as the run list's role=option rows. */
        row.setAttribute("tabindex","-1");

        var iconCell = mk("span", "flex items-center justify-center");
        iconCell.appendChild(fileIcon(e.name, e.is_dir));
        row.appendChild(iconCell);

        var nameCell = mk("span", "min-w-0 wrap-anywhere");
        var btn = mk("button", OPEN_CLASS);
        btn.type = "button";
        btn.textContent = e.name;
        btn.setAttribute("aria-label",(e.is_dir?"Open folder ":"Open file ")+e.name);
        btn.setAttribute("tabindex","-1");
        btn.addEventListener("click", function(ev) { ev.stopPropagation(); activate(e, i); });
        nameCell.appendChild(btn);
        row.appendChild(nameCell);

        var sizeCell = mk("span", CELL_CLASS);
        sizeCell.textContent = e.is_dir ? "—" : api.fmt.bytes(e.size);
        row.appendChild(sizeCell);

        var whenCell = mk("span", CELL_CLASS);
        whenCell.textContent = api.fmt.time(e.mtime);
        row.appendChild(whenCell);

        row.addEventListener("click", function() { activate(e, i); });
        row.addEventListener("mouseenter", function() { setFocus(i, false); });
        list.appendChild(row);
      });
    }

    function setFocus(idx, scroll) {
      var rows = list.querySelectorAll("[role=option]");
      rows.forEach(function(r) {
        r.setAttribute("aria-selected","false");
      });
      focusIdx = idx;
      if (idx >= 0 && idx < rows.length) {
        rows[idx].setAttribute("aria-selected","true");
        if (scroll) rows[idx].scrollIntoView({block:"nearest"});
      }
    }

    function activate(e, i) {
      setFocus(i, false);
      if (e.is_dir) {
        load(cur.path ? cur.path+"/"+e.name : e.name);
      } else {
        openFile(cur.path ? cur.path+"/"+e.name : e.name, e.name);
      }
    }

    // keyboard nav on the list container
    list.addEventListener("keydown", function(ev) {
      var entries = visibleEntries();
      if (!entries.length) return;
      if (ev.key === "ArrowDown") { ev.preventDefault(); setFocus(Math.min(focusIdx+1, entries.length-1), true); }
      else if (ev.key === "ArrowUp") { ev.preventDefault(); setFocus(Math.max(focusIdx-1, 0), true); }
      else if (ev.key === "Enter" && focusIdx >= 0) { ev.preventDefault(); activate(entries[focusIdx], focusIdx); }
      else if (ev.key === "Backspace" && !cur.atRoot) { ev.preventDefault(); load(cur.parent); }
      else if (ev.key === "Escape") { ev.preventDefault(); closeViewer(); }
    });

    // ── filter + hidden toggle ──
    filterInput.addEventListener("input", function() {
      filterText = filterInput.value.trim().toLowerCase();
      renderEntries();
    });

    hiddenBtn.addEventListener("click", function() {
      showHidden = !showHidden;
      hiddenBtn.setAttribute("aria-pressed", showHidden ? "true" : "false");
      hiddenBtn.title = showHidden ? "Hide hidden files" : "Show hidden files";
      hiddenBtn.dataset.active = showHidden ? "1" : "";
      renderEntries();
    });

    // ── breadcrumbs ──
    function drawCrumbs(path, root) {
      crumbs.textContent = "";
      var rootBtn = mk("button", CRUMB_CLASS, root || "workspace");
      rootBtn.type = "button";
      rootBtn.setAttribute("aria-label","Workspace root");
      rootBtn.addEventListener("click", function() { load(""); });
      crumbs.appendChild(rootBtn);
      if (!path) return;
      path.split("/").forEach(function(seg, i, arr) {
        crumbs.appendChild(mk("span", "text-fg-muted opacity-40", "/"));
        var acc = arr.slice(0,i+1).join("/");
        var last = i === arr.length-1;
        if (last) {
          var here = mk("span", CRUMB_HERE_CLASS, seg);
          here.setAttribute("aria-current","page");
          crumbs.appendChild(here);
        } else {
          var b = mk("button", CRUMB_CLASS, seg);
          b.type = "button";
          b.addEventListener("click", (function(p){ return function(){ load(p); }; })(acc));
          crumbs.appendChild(b);
        }
      });
    }

    // ── file viewer ──
    function openFile(path, name) {
      var mine = ++generation;
      api.status("Loading "+name+"…");
      return api.getJSON("/api/files?path="+encodeURIComponent(path)+(api.workspace() ? "&workspace="+encodeURIComponent(api.workspace()) : ""))
        .then(function(d) {
          if (mine !== generation) return;
          openPath = path;
          vName.textContent = name;
          vBody.textContent = "";
          vNote.hidden = true;
          rightPane.hidden = false;
          panes.dataset.preview = "open";

          if (d.binary) {
            vMeta.textContent = "";
            vBody.appendChild(mk("p", EMPTY_CLASS, "Binary file — no preview."));
            api.status(name+" (binary).");
            return;
          }
          var content = d.content || "";
          var lineCount = content ? content.split("\n").length : 0;
          vMeta.textContent = api.fmt.bytes(content.length)
            + (lineCount > 1 ? " · "+lineCount+" lines" : "");

          if (d.truncated) {
            vNote.textContent = "Showing first "+api.fmt.bytes(content.length)+" — file is larger.";
            vNote.hidden = false;
          }

          var ext = extOf(name);
          if (MD[ext]) {
            api.render.markdown(vBody, content);
          } else if (LANG[ext]) {
            vBody.appendChild(api.render.code(LANG[ext], content));
          } else {
            var pre = mk("pre", PLAIN_PRE_CLASS);
            pre.textContent = content;
            vBody.appendChild(pre);
          }
          api.status(name+".");
        })
        .catch(function(err) {
          if (mine !== generation) return;
          openPath = path;
          vName.textContent = name;
          vMeta.textContent = "";
          vNote.hidden = true;
          vBody.textContent = "";
          var fail = mk("p", EMPTY_CLASS);
          fail.appendChild(document.createTextNode("Could not open this file. " + err.message + " "));
          var retry = mk("button", "secondary", "Try again");
          retry.type = "button";
          retry.addEventListener("click", function () { openFile(path, name); });
          fail.appendChild(retry);
          vBody.appendChild(fail);
          rightPane.hidden = false;
          panes.dataset.preview = "open";
          api.status("Could not open this file. " + err.message);
        });
    }

    function closeViewer() {
      rightPane.hidden = true;
      panes.dataset.preview = "";
      openPath = "";
    }

    closeBtn.addEventListener("click", closeViewer);

    copyBtn.addEventListener("click", function() {
      if (!openPath) return;
      var orig = copyBtn.textContent;
      function restore(label) { copyBtn.textContent = label; setTimeout(function(){ copyBtn.textContent = orig; }, 1500); }
      // Say so on a failed copy too: claiming "Copied" over a refused write
      // sends the user away believing the path is on their clipboard.
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(openPath).then(
          function () { restore("Copied"); },
          function () { restore("Copy failed"); }
        );
      } else {
        var t = document.createElement("textarea");
        t.value = openPath;
        t.style.cssText = "position:fixed;opacity:0";
        document.body.appendChild(t);
        t.select();
        var won = false;
        try { won = document.execCommand("copy"); } catch(_) {}
        document.body.removeChild(t);
        restore(won ? "Copied" : "Copy failed");
      }
    });

    // ── directory loader ──
    function parentOf(p) { var s = p.lastIndexOf("/"); return s < 0 ? "" : p.slice(0,s); }

    function load(path) {
      var want = path === undefined ? cur.path : path;
      var mine = ++generation;
      upBtn.disabled = true;
      refreshBtn.disabled = true;
      filterInput.value = "";
      filterText = "";
      return api.getJSON("/api/files?path="+encodeURIComponent(want)+(api.workspace() ? "&workspace="+encodeURIComponent(api.workspace()) : ""))
        .then(function(d) {
          if (mine !== generation) return;
          cur.path = d.path || "";
          cur.root = d.root || cur.root;
          cur.parent = d.parent || "";
          cur.atRoot = d.at_root === undefined ? cur.path === "" : !!d.at_root;
          allEntries = d.entries || [];
          drawCrumbs(cur.path, cur.root);
          refreshSort();
          renderEntries();
          var vis = allEntries.filter(function(e){ return !e.name.startsWith("."); }).length;
          // A capped listing is not the whole folder: saying "2000 items" for
          // a directory holding far more reads as complete when it is not.
          api.status(vis+(vis===1?" item":" items")+(d.truncated ? " (first "+(d.entry_cap||vis)+" — folder holds more)." : "."));
        })
        .catch(function(err) {
          if (mine !== generation) return;
          cur.path = want;
          cur.parent = parentOf(want);
          cur.atRoot = want === "";
          allEntries = [];
          drawCrumbs(want, cur.root);
          list.textContent = "";
          var fail = mk("p", EMPTY_CLASS);
          fail.appendChild(document.createTextNode("Could not open this folder. " + err.message + " "));
          var retry = mk("button", "secondary", "Try again");
          retry.type = "button";
          retry.addEventListener("click", function () { load(want); });
          fail.appendChild(retry);
          list.appendChild(fail);
          api.status("Could not open this folder. " + err.message);
        })
        .then(function() {
          if (mine !== generation) return;
          upBtn.disabled = cur.atRoot;
          refreshBtn.disabled = false;
        });
    }

    upBtn.disabled = true;
    refreshBtn.disabled = true;
    upBtn.addEventListener("click", function(){ if (!cur.atRoot) load(cur.parent); });
    refreshBtn.addEventListener("click", function(){ load(); });
    refreshSort();

    this.reload = load;
    window.addEventListener("clanker-workspace", function () { load(""); });
    return load();
  },

  refresh: function() {
    if (this.reload) return this.reload();
  }
});
