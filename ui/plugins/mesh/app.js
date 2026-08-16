/* mesh: operator control plane for clanker mesh.

   Same verbs as `clanker mesh`: status, join, leave, pending, admit, deny.
   Talks to local serve over /api/mesh/*. Fleet keeps the lamp map; this
   view is how you change membership. */

clanker.registerView({
  id: "mesh",
  title: "Mesh",
  group: "Watch",
  mount: function (container, api) {
    var state = { status: null, pending: [], busy: "", error: "" };

    var head = api.el("div", "section-head");
    head.appendChild(api.el("h2", null, "Mesh"));
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    refresh.id = "mesh-refresh";
    head.appendChild(refresh);
    container.appendChild(head);

    var intro = api.el("p", "meta");
    intro.appendChild(document.createTextNode("This instance's mesh members. Same verbs as "));
    intro.appendChild(api.el("code", null, "clanker mesh"));
    intro.appendChild(document.createTextNode(". Loopback HTTP to this serve; serve owns the sockets."));
    container.appendChild(intro);

    var statusLine = api.el("p", "meta");
    statusLine.id = "mesh-status";
    statusLine.setAttribute("role", "status");
    statusLine.setAttribute("aria-live", "polite");
    container.appendChild(statusLine);

    var errHost = api.el("div", "mesh-error");
    container.appendChild(errHost);

    var membersHead = api.el("h3", "detail-head subsection-head", "Members");
    container.appendChild(membersHead);
    var members = api.el("div", "mesh-members");
    members.id = "mesh-members";
    container.appendChild(members);

    var joinHead = api.el("h3", "detail-head subsection-head", "Join");
    container.appendChild(joinHead);
    var form = document.createElement("form");
    form.className = "mesh-join-form";
    form.id = "mesh-join-form";
    var addrLabel = api.el("label", null, "Host and port");
    addrLabel.setAttribute("for", "mesh-join-addr");
    var addr = document.createElement("input");
    addr.type = "text";
    addr.id = "mesh-join-addr";
    addr.name = "address";
    addr.required = true;
    addr.autocomplete = "off";
    addr.placeholder = "127.0.0.1:7420";
    addr.spellcheck = false;
    addrLabel.appendChild(addr);
    form.appendChild(addrLabel);
    var joinBtn = api.el("button", "primary", "Join");
    joinBtn.type = "submit";
    joinBtn.id = "mesh-join";
    form.appendChild(joinBtn);
    container.appendChild(form);

    var pendHead = api.el("h3", "detail-head subsection-head", "Pending joins");
    container.appendChild(pendHead);
    var pending = api.el("div", "mesh-pending");
    pending.id = "mesh-pending";
    container.appendChild(pending);

    var leaveSelf = api.el("button", "secondary", "Leave the mesh");
    leaveSelf.type = "button";
    leaveSelf.id = "mesh-leave-self";
    container.appendChild(leaveSelf);

    function showErr(msg, retry) {
      errHost.textContent = "";
      if (!msg) return;
      var p = api.el("p", "run-empty");
      p.appendChild(document.createTextNode(msg + " "));
      if (retry) {
        var again = api.el("button", "secondary", "Try again");
        again.type = "button";
        again.addEventListener("click", load);
        p.appendChild(again);
      }
      errHost.appendChild(p);
    }

    function memberRow(m) {
      var row = api.el("article", "mesh-member");
      if (!m.up) row.dataset.down = "true";
      var name = m.name || m.id || "?";
      row.appendChild(api.el("code", "mesh-member-id", name));
      if (m.id && m.id !== name) row.appendChild(api.el("span", "meta", m.id));
      var chip = api.el("span", "meta mesh-up");
      chip.dataset.state = m.up ? "ok" : "down";
      chip.textContent = m.up ? "up" : "down";
      row.appendChild(chip);
      var drop = api.el("button", "secondary", "Leave");
      drop.type = "button";
      drop.setAttribute("aria-label", "Leave " + name);
      drop.addEventListener("click", function () {
        act(function () { return api.postJSON("/api/mesh/leave", { peer_id: m.id || name }); }, "left " + name);
      });
      row.appendChild(drop);
      return row;
    }

    function pendingRow(p) {
      var row = api.el("article", "mesh-pending-row");
      var id = p.id || "?";
      row.appendChild(api.el("code", "mesh-member-id", id));
      if (p.name && p.name !== id) row.appendChild(api.el("span", "meta", p.name));
      if (p.age_s != null) row.appendChild(api.el("span", "meta", p.age_s + "s"));
      var admit = api.el("button", "primary", "Admit");
      admit.type = "button";
      admit.addEventListener("click", function () {
        act(function () { return api.postJSON("/api/mesh/pending", { id: id, allow: true }); }, "admitted " + id);
      });
      var deny = api.el("button", "secondary", "Deny");
      deny.type = "button";
      deny.addEventListener("click", function () {
        act(function () { return api.postJSON("/api/mesh/pending", { id: id, allow: false }); }, "denied " + id);
      });
      row.appendChild(admit);
      row.appendChild(deny);
      return row;
    }

    function draw() {
      var s = state.status;
      if (!s) {
        statusLine.textContent = state.busy || "";
      } else {
        var bits = [];
        bits.push(s.listening ? "listening" : "not listening");
        if (s.listen) bits.push(s.listen);
        if (s.admission) bits.push("admission=" + s.admission);
        if (s.id) bits.push("id=" + s.id);
        statusLine.textContent = bits.join("  ");
      }

      members.textContent = "";
      var list = (s && s.members) || [];
      if (!list.length) {
        members.appendChild(api.el("p", "run-empty", "No members. Join a listen address below, or wait for someone to join you."));
      } else {
        list.forEach(function (m) { members.appendChild(memberRow(m)); });
      }

      pending.textContent = "";
      if (!state.pending.length) {
        pending.appendChild(api.el("p", "run-empty", "No pending joins."));
      } else {
        state.pending.forEach(function (p) { pending.appendChild(pendingRow(p)); });
      }
    }

    function load() {
      state.busy = "Loading…";
      state.error = "";
      showErr("");
      draw();
      return Promise.all([
        api.getJSON("/api/mesh/status"),
        api.getJSON("/api/mesh/pending").catch(function () { return { pending: [] }; })
      ]).then(function (pair) {
        state.status = pair[0];
        state.pending = (pair[1] && pair[1].pending) || [];
        state.busy = "";
        draw();
      }).catch(function (e) {
        state.status = null;
        state.pending = [];
        state.busy = "";
        var msg = (e && e.message) || "mesh request failed";
        if (/modules\.mesh is off/i.test(msg)) {
          showErr("Mesh is off. Set modules.mesh = true and restart clanker serve.", true);
        } else {
          showErr(msg, true);
        }
        draw();
      });
    }

    function act(fn, okMsg) {
      return fn().then(function () {
        api.toast(okMsg, "ok");
        return load();
      }).catch(function (e) {
        api.toast((e && e.message) || "failed", "error");
        return load();
      });
    }

    refresh.addEventListener("click", load);
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var address = (addr.value || "").trim();
      if (!address) return;
      act(function () { return api.postJSON("/api/mesh/join", { address: address }); }, "joined " + address);
    });
    leaveSelf.addEventListener("click", function () {
      api.confirm("Leave the mesh? Other members will drop this instance.").then(function (yes) {
        if (yes) act(function () { return api.postJSON("/api/mesh/leave", {}); }, "left the mesh");
      });
    });

    api.onLive(function (ev) {
      if (!ev) return;
      if (ev.t === "mesh" || ev.t === "talk") load();
    });

    load();
  },
  refresh: function (container, api) {
    var btn = container.querySelector("#mesh-refresh");
    if (btn) btn.click();
  }
});
