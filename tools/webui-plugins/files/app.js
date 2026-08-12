/* files: browse the current workspace from the server's working directory.

   Read-only. Directories open; files show their size and last-modified time.
   Every string a row can hold — a filename, a fragment of a breadcrumb — comes
   from the server and is attached as text, never innerHTML, so nothing a
   directory happens to be named can run or paint markup we did not intend. */

clanker.registerView({
  id: "files",
  title: "Files",
  group: "Work",
  mount: function (container, api) {
    // Everything shown in the list is rebuilt from the server's latest
    // response. Nothing is cached here that could go stale.
    var cur = { path: "", root: "workspace", parent: "" };

    var head = api.el("div", "section-head");
    var h = api.el("h2", null, "Files");
    var up = api.el("button", "secondary", "Up");
    up.type = "button";
    up.setAttribute("aria-label", "Go up one directory");
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    head.appendChild(h);
    head.appendChild(up);
    head.appendChild(refresh);
    container.appendChild(head);

    var crumbs = api.el("nav", "files-crumbs");
    crumbs.setAttribute("aria-label", "Breadcrumb");
    container.appendChild(crumbs);

    var list = api.el("div", "files-list");
    container.appendChild(list);

    var empty = api.el("p", "files-empty", "This folder is empty.");
    empty.hidden = true;
    container.appendChild(empty);

    function show(ctrl, on) { ctrl.disabled = !on; }

    function jump(path, focusRoot) {
      cur.path = path;
      load();
      if (focusRoot) crumbs.firstChild && crumbs.firstChild.focus && crumbs.firstChild.focus();
    }

    // Rebuild the breadcrumb trail for the server-reported location. The root
    // label is a button back to the top, each following segment a button one
    // level down; the last segment is the current folder and is not a link.
    function drawCrumbs(d) {
      crumbs.textContent = "";
      var segs = d.path ? d.path.split("/") : [];
      var acc = "";
      var rootBtn = api.el("button", "files-crumb files-crumb-root", d.root || "workspace");
      rootBtn.type = "button";
      rootBtn.setAttribute("aria-label", "Go to the workspace root");
      rootBtn.addEventListener("click", function () { jump("", true); });
      crumbs.appendChild(rootBtn);
      segs.forEach(function (seg, i) {
        crumbs.appendChild(api.el("span", "files-crumb-sep", "/"));
        acc = acc ? acc + "/" + seg : seg;
        var last = i === segs.length - 1;
        if (last) {
          var here = api.el("span", "files-crumb files-crumb-here");
          here.setAttribute("aria-current", "page");
          here.textContent = seg;
          crumbs.appendChild(here);
        } else {
          var b = api.el("button", "files-crumb", seg);
          b.type = "button";
          b.addEventListener("click", (function (p) { return function () { jump(p, false); }; })(acc));
          crumbs.appendChild(b);
        }
      });
    }

    function drawEntries(entries) {
      list.textContent = "";
      empty.hidden = entries.length > 0;
      if (!entries.length) return;
      entries.forEach(function (e) {
        var row = api.el("div", "files-row");
        var icon = api.el("span", "files-icon", e.is_dir ? "folder" : "file");
        icon.setAttribute("aria-hidden", "true");
        row.appendChild(icon);

        var nameCell = api.el("span", "files-name");
        if (e.is_dir) {
          var open = api.el("button", "files-open", e.name);
          open.type = "button";
          open.setAttribute("aria-label", "Open folder " + e.name);
          open.title = "Open folder";
          open.addEventListener("click", function () {
            jump(cur.path ? cur.path + "/" + e.name : e.name, false);
          });
          nameCell.appendChild(open);
        } else {
          nameCell.textContent = e.name;
        }
        row.appendChild(nameCell);

        row.appendChild(api.el("span", "files-type", e.is_dir ? "folder" : "file"));

        var size = api.el("span", "files-size");
        size.textContent = e.is_dir ? "—" : api.fmt.bytes(e.size);
        row.appendChild(size);

        var when = api.el("span", "files-when");
        when.textContent = api.fmt.time(e.mtime);
        row.appendChild(when);
        list.appendChild(row);
      });
    }

    function load() {
      show(refresh, false);
      if (cur.parent) show(up, true);
      return api.getJSON("/api/files?path=" + encodeURIComponent(cur.path))
        .then(function (d) {
          cur.path = d.path || "";
          cur.root = d.root || cur.root;
          cur.parent = d.parent || "";
          drawCrumbs(d);
          drawEntries(d.entries || []);
          var n = (d.entries || []).length;
          api.status(n + (n === 1 ? " item." : " items."));
        })
        .catch(function (err) { api.status("Files: " + err.message); })
        .then(function () {
          show(refresh, true);
          show(up, cur.parent !== "");
        });
    }

    up.addEventListener("click", function () {
      if (cur.parent !== "") jump(cur.parent, false);
    });
    refresh.addEventListener("click", load);

    this.reload = load;
    return load();
  },
  refresh: function () {
    if (this.reload) this.reload();
  }
});
