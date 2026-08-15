/* files: workspace file browser with split-pane preview.

   Left pane: directory listing with filter, sort, and keyboard navigation.
   Right pane: file preview — markdown (with mermaid fences), source code
   (syntax-highlighted via hljs), or plain text. On narrow screens the panes
   stack vertically.

   Security: every server-supplied string (names, paths, content) attaches via
   textContent. SVG icon paths are all hardcoded here. File content goes
   through api.render.markdown / api.render.code which treat input as data. */

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
  dir:"#f0a500",
  zig:"#f7a41d", js:"#f0db4f", mjs:"#f0db4f", ts:"#3178c6", tsx:"#61dafb",
  jsx:"#61dafb", py:"#3572a5", rs:"#dea584", go:"#00acd7",
  c:"#999", h:"#999", cpp:"#f34b7d", java:"#b07219", rb:"#cc342d",
  md:"#7c6aff", markdown:"#7c6aff", mdx:"#7c6aff",
  json:"#888", toml:"#9c4221", yaml:"#888", yml:"#888",
  css:"#264de4", scss:"#c6538c", html:"#e34c26", xml:"#e34c26",
  svg:"#f9a03c", sh:"#89e051", bash:"#89e051", zsh:"#89e051",
  wasm:"#654ff0", sql:"#e38c00", lock:"#888",
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
  s.setAttribute("class","files-icon-svg");
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

    var crumbs = mk("nav", "files-crumbs");
    crumbs.setAttribute("aria-label", "Breadcrumb");
    container.appendChild(crumbs);

    var toolbar = mk("div", "files-toolbar");

    var filterInput = mk("input", "files-filter");
    filterInput.type = "search";
    filterInput.placeholder = "Filter…";
    filterInput.setAttribute("aria-label", "Filter entries");
    toolbar.appendChild(filterInput);

    var hiddenBtn = mk("button", "secondary files-toggle-btn", "·/·");
    hiddenBtn.type = "button";
    hiddenBtn.title = "Show hidden files";
    hiddenBtn.setAttribute("aria-pressed","false");
    hiddenBtn.setAttribute("aria-label","Toggle hidden files");
    toolbar.appendChild(hiddenBtn);

    var upBtn = mk("button", "secondary", "↑ Up");
    upBtn.type = "button";
    upBtn.setAttribute("aria-label","Go up one directory");
    toolbar.appendChild(upBtn);

    var refreshBtn = mk("button", "secondary", "↺");
    refreshBtn.type = "button";
    refreshBtn.setAttribute("aria-label","Refresh");
    toolbar.appendChild(refreshBtn);

    container.appendChild(toolbar);

    // ── column headers ──
    var sortBtns = {};
    function makeSortBtn(label, key) {
      var btn = mk("button", "files-sort-btn", label);
      btn.type = "button";
      btn.addEventListener("click", function() {
        sortKey = (sortKey === key) ? key : key;
        if (sortKey === key && btn.dataset.active) sortDir *= -1; else sortDir = 1;
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
        btn.className = "files-sort-btn" + (active ? " active" : "");
        btn.dataset.active = active ? "1" : "";
        btn.textContent = ({ name:"Name", size:"Size", mtime:"Modified" })[k]
          + (active ? (sortDir > 0 ? " ▴" : " ▾") : "");
      });
    }

    // ── split panes ──
    var panes = mk("div", "files-panes");

    // left: listing
    var leftPane = mk("div", "files-left");
    var hdrRow = mk("div", "files-row files-header");
    hdrRow.appendChild(mk("span","files-icon-col"));
    hdrRow.appendChild(makeSortBtn("Name","name"));
    hdrRow.appendChild(makeSortBtn("Size","size"));
    hdrRow.appendChild(makeSortBtn("Modified","mtime"));
    leftPane.appendChild(hdrRow);

    var list = mk("div", "files-list");
    list.setAttribute("role","listbox");
    list.setAttribute("aria-label","Directory entries");
    list.setAttribute("tabindex","0");
    leftPane.appendChild(list);

    var emptyMsg = mk("p", "files-empty", "This folder is empty.");
    emptyMsg.hidden = true;
    leftPane.appendChild(emptyMsg);

    // right: preview
    var rightPane = mk("div", "files-right");
    rightPane.hidden = true;

    var vHead = mk("div", "files-viewer-head");
    var vName = mk("span", "files-viewer-name");
    var vMeta = mk("span", "files-viewer-meta");
    var copyBtn = mk("button", "secondary files-copy-btn", "Copy path");
    copyBtn.type = "button";
    var closeBtn = mk("button", "secondary files-close-btn", "✕");
    closeBtn.type = "button";
    closeBtn.setAttribute("aria-label","Close preview");
    vHead.appendChild(vName);
    vHead.appendChild(vMeta);
    vHead.appendChild(copyBtn);
    vHead.appendChild(closeBtn);
    rightPane.appendChild(vHead);

    var vNote = mk("p","files-viewer-note");
    vNote.hidden = true;
    rightPane.appendChild(vNote);

    var vBody = mk("div","files-viewer");
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
      emptyMsg.hidden = entries.length > 0 || filterText.length > 0;
      if (!entries.length) {
        if (filterText) {
          var none = mk("p","files-empty");
          none.textContent = "No matches for “" + filterText + "”.";
          list.appendChild(none);
        }
        return;
      }
      entries.forEach(function(e, i) {
        var row = mk("div","files-row");
        row.setAttribute("role","option");
        row.setAttribute("aria-selected","false");

        var iconCell = mk("span","files-icon-col");
        iconCell.appendChild(fileIcon(e.name, e.is_dir));
        row.appendChild(iconCell);

        var nameCell = mk("span","files-name");
        var btn = mk("button","files-open");
        btn.type = "button";
        btn.textContent = e.name;
        btn.setAttribute("aria-label",(e.is_dir?"Open folder ":"Open file ")+e.name);
        btn.setAttribute("tabindex","-1");
        btn.addEventListener("click", function(ev) { ev.stopPropagation(); activate(e, i); });
        nameCell.appendChild(btn);
        row.appendChild(nameCell);

        var sizeCell = mk("span","files-size");
        sizeCell.textContent = e.is_dir ? "—" : api.fmt.bytes(e.size);
        row.appendChild(sizeCell);

        var whenCell = mk("span","files-when");
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
        r.classList.remove("files-row-active");
        r.setAttribute("aria-selected","false");
      });
      focusIdx = idx;
      if (idx >= 0 && idx < rows.length) {
        rows[idx].classList.add("files-row-active");
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
      hiddenBtn.className = "secondary files-toggle-btn" + (showHidden ? " active" : "");
      renderEntries();
    });

    // ── breadcrumbs ──
    function drawCrumbs(path, root) {
      crumbs.textContent = "";
      var rootBtn = mk("button","files-crumb files-crumb-root", root || "workspace");
      rootBtn.type = "button";
      rootBtn.setAttribute("aria-label","Workspace root");
      rootBtn.addEventListener("click", function() { load(""); });
      crumbs.appendChild(rootBtn);
      if (!path) return;
      path.split("/").forEach(function(seg, i, arr) {
        crumbs.appendChild(mk("span","files-crumb-sep","/"));
        var acc = arr.slice(0,i+1).join("/");
        var last = i === arr.length-1;
        if (last) {
          var here = mk("span","files-crumb files-crumb-here", seg);
          here.setAttribute("aria-current","page");
          crumbs.appendChild(here);
        } else {
          var b = mk("button","files-crumb", seg);
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
      return api.getJSON("/api/files?path="+encodeURIComponent(path))
        .then(function(d) {
          if (mine !== generation) return;
          openPath = path;
          vName.textContent = name;
          vBody.textContent = "";
          vNote.hidden = true;
          rightPane.hidden = false;

          if (d.binary) {
            vMeta.textContent = "";
            vBody.appendChild(mk("p","files-empty","Binary file — no preview."));
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
            var pre = mk("pre","files-viewer-plain");
            pre.textContent = content;
            vBody.appendChild(pre);
          }
          api.status(name+".");
        })
        .catch(function(err) {
          if (mine !== generation) return;
          api.status("Files: "+err.message);
        });
    }

    function closeViewer() {
      rightPane.hidden = true;
      openPath = "";
    }

    closeBtn.addEventListener("click", closeViewer);

    copyBtn.addEventListener("click", function() {
      if (!openPath) return;
      var orig = copyBtn.textContent;
      function done() { copyBtn.textContent = "Copied!"; setTimeout(function(){ copyBtn.textContent = orig; }, 1500); }
      if (navigator.clipboard) {
        navigator.clipboard.writeText(openPath).then(done).catch(done);
      } else {
        var t = document.createElement("textarea");
        t.value = openPath;
        t.style.cssText = "position:fixed;opacity:0";
        document.body.appendChild(t);
        t.select();
        try { document.execCommand("copy"); } catch(_) {}
        document.body.removeChild(t);
        done();
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
      return api.getJSON("/api/files?path="+encodeURIComponent(want))
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
          api.status(vis+(vis===1?" item.":" items."));
        })
        .catch(function(err) {
          if (mine !== generation) return;
          cur.path = want;
          cur.parent = parentOf(want);
          cur.atRoot = want === "";
          allEntries = [];
          drawCrumbs(want, cur.root);
          list.textContent = "";
          list.appendChild(mk("p","files-empty","Error: "+err.message));
          api.status("Files: "+err.message);
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
    return load();
  },

  refresh: function() {
    if (this.reload) return this.reload();
  }
});
