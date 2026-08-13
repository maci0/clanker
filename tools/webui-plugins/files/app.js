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
    //
    // `at_root` is carried separately from `parent` because the two are not the
    // same question. GET /api/files reports `parent: ""` for the workspace root
    // *and* for every top-level directory, since the parent of "src" is the
    // root and the root's path is the empty string. Deciding root-ness from
    // `parent` therefore stranded you one level down with a dead Up button.
    var cur = { path: "", root: "workspace", parent: "", atRoot: true };

    // Which request the view is currently showing. Navigating twice quickly —
    // a folder, then the breadcrumb — leaves two requests in flight, and this
    // server answers one request per connection, so they can land in either
    // order. Only the newest generation is allowed to paint.
    var generation = 0;

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

    // Nothing is known about the tree until the first response, so neither
    // control does anything useful yet. Up in particular started out enabled
    // with no directory to go up from.
    show(up, false);
    show(refresh, false);

    /// The parent of a path, worked out from the path itself. Used when the
    /// server could not answer, so Up still gets you out of a directory whose
    /// listing failed rather than dead-ending on the error.
    function parentOf(p) {
      var slash = p.lastIndexOf("/");
      return slash === -1 ? "" : p.slice(0, slash);
    }

    function jump(path, focusRoot) {
      return load(path).then(function () {
        // After the load, not before: drawCrumbs rebuilds the trail, so the
        // button this was focusing had already been thrown away and focus fell
        // to the body. Focus the root crumb the current trail actually holds.
        if (!focusRoot) return;
        var root = crumbs.firstChild;
        if (root && root.focus) root.focus();
      });
    }

    // Rebuild the breadcrumb trail for a location. The root label is a button
    // back to the top, each following segment a button one level down; the last
    // segment is the current folder and is not a link. Driven by path + root
    // rather than by a whole response, so a failed load can still say where you
    // asked to be.
    function drawCrumbs(path, root) {
      crumbs.textContent = "";
      var segs = path ? path.split("/") : [];
      var acc = "";
      var rootBtn = api.el("button", "files-crumb files-crumb-root", root || "workspace");
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

    /// A directory that could not be read. The trail names the directory you
    /// asked for and the list says why it is not there, because leaving the
    /// previous directory's rows up made the view claim a location it had
    /// already navigated away from.
    function drawFailure(path, message) {
      drawCrumbs(path, cur.root);
      list.textContent = "";
      empty.hidden = true;
      list.appendChild(api.el("p", "files-empty", message));
    }

    /// Loads one directory. `path` defaults to wherever the view already is,
    /// which is what Refresh wants.
    function load(path) {
      var want = path === undefined ? cur.path : path;
      var mine = ++generation;
      show(refresh, false);
      show(up, false);
      return api.getJSON("/api/files?path=" + encodeURIComponent(want))
        .then(function (d) {
          if (mine !== generation) return; // a newer navigation already won
          cur.path = d.path || "";
          cur.root = d.root || cur.root;
          cur.parent = d.parent || "";
          // Trust the server's own answer; fall back to the path for an older
          // server that does not send the field.
          cur.atRoot = d.at_root === undefined ? cur.path === "" : !!d.at_root;
          drawCrumbs(cur.path, cur.root);
          drawEntries(d.entries || []);
          var n = (d.entries || []).length;
          api.status(n + (n === 1 ? " item." : " items."));
        })
        .catch(function (err) {
          if (mine !== generation) return;
          cur.path = want;
          cur.parent = parentOf(want);
          cur.atRoot = want === "";
          drawFailure(want, "Files: " + err.message);
          api.status("Files: " + err.message);
        })
        .then(function () {
          if (mine !== generation) return;
          show(refresh, true);
          show(up, !cur.atRoot);
        });
    }

    up.addEventListener("click", function () {
      if (!cur.atRoot) jump(cur.parent, false);
    });
    refresh.addEventListener("click", function () { load(); });

    this.reload = load;
    return load();
  },
  refresh: function () {
    if (this.reload) return this.reload();
    return null;
  }
});
