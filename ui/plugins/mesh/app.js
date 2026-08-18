/* mesh: operator control plane for clanker mesh.

   Same verbs as `clanker mesh`: status, join, leave, pending, admit, deny.
   Talks to local serve over /api/mesh/*. Fleet keeps the lamp map; this
   view is how you change membership. */

clanker.registerView({
  id: "mesh",
  title: "Mesh",
  group: "Watch",
  mount: function (container, api) {
    var state = { status: null, pending: [], busy: "", error: "", loadedAt: 0 };
    var poll = null;
    var tick = null;

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

    var facts = api.el("dl", "mesh-facts");
    facts.id = "mesh-facts";
    container.appendChild(facts);

    var statusLine = api.el("p", "meta");
    statusLine.id = "mesh-status";
    statusLine.setAttribute("role", "status");
    statusLine.setAttribute("aria-live", "polite");
    container.appendChild(statusLine);

    var errHost = api.el("div", "mesh-error");
    container.appendChild(errHost);

    var membersHead = api.el("h3", "detail-head subsection-head", "Members");
    membersHead.id = "mesh-members-head";
    container.appendChild(membersHead);
    var members = api.el("div", "mesh-members");
    members.id = "mesh-members";
    container.appendChild(members);

    var joinHead = api.el("h3", "detail-head subsection-head", "Join");
    container.appendChild(joinHead);
    var joinHint = api.el("p", "meta");
    joinHint.id = "mesh-join-hint";
    container.appendChild(joinHint);
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
    pendHead.id = "mesh-pending-head";
    container.appendChild(pendHead);
    var pending = api.el("div", "mesh-pending");
    pending.id = "mesh-pending";
    container.appendChild(pending);

    var leaveSelf = api.el("button", "secondary", "Leave the mesh");
    leaveSelf.type = "button";
    leaveSelf.id = "mesh-leave-self";
    leaveSelf.hidden = true;
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

    function fact(term, value, extra) {
      var dt = api.el("dt", null, term);
      var dd = api.el("dd");
      if (value) dd.appendChild(document.createTextNode(value));
      if (extra) dd.appendChild(extra);
      facts.appendChild(dt);
      facts.appendChild(dd);
      return dd;
    }

    function copyListen(text) {
      var btn = api.el("button", "secondary mesh-copy", "Copy");
      btn.type = "button";
      btn.setAttribute("aria-label", "Copy listen address");
      btn.addEventListener("click", function () {
        var clip = typeof navigator !== "undefined" && navigator.clipboard;
        if (!clip || !window.isSecureContext) {
          api.prompt("Listen address", text);
          return;
        }
        clip.writeText(text).then(function () {
          btn.textContent = "Copied";
          api.toast("copied " + text, "ok");
          setTimeout(function () { btn.textContent = "Copy"; }, 1200);
        }).catch(function () {
          api.toast("The browser refused the clipboard.", "error");
        });
      });
      return btn;
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
      drop.disabled = !!state.busy;
      drop.setAttribute("aria-label", "Leave " + name);
      drop.addEventListener("click", function () {
        act(function () { return api.postJSON("/api/mesh/leave", { peer_id: m.id || name }); }, "left " + name);
      });
      row.appendChild(drop);
      return row;
    }

    function pendingAge(p) {
      var base = typeof p.age_s === "number" ? p.age_s : 0;
      var extra = state.loadedAt ? Math.floor((Date.now() - state.loadedAt) / 1000) : 0;
      return base + extra;
    }

    function pendingRow(p) {
      var row = api.el("article", "mesh-pending-row");
      var id = p.id || "?";
      row.appendChild(api.el("code", "mesh-member-id", id));
      if (p.name && p.name !== id) row.appendChild(api.el("span", "meta", p.name));
      row.appendChild(api.el("span", "meta", pendingAge(p) + "s"));
      var admit = api.el("button", "primary", "Admit");
      admit.type = "button";
      admit.disabled = !!state.busy;
      admit.addEventListener("click", function () {
        act(function () { return api.postJSON("/api/mesh/pending", { id: id, allow: true }); }, "admitted " + id);
      });
      var deny = api.el("button", "secondary", "Deny");
      deny.type = "button";
      deny.disabled = !!state.busy;
      deny.addEventListener("click", function () {
        act(function () { return api.postJSON("/api/mesh/pending", { id: id, allow: false }); }, "denied " + id);
      });
      row.appendChild(admit);
      row.appendChild(deny);
      return row;
    }

    function draw() {
      var s = state.status;
      var list = (s && s.members) || [];
      facts.textContent = "";
      if (s) {
        fact("id", s.id || "unset");
        if (s.listen) fact("listen", s.listen, copyListen(s.listen));
        fact("admission", s.admission || "unset");
        fact("state", s.listening ? "listening" : "not listening");
      }

      if (!s) {
        statusLine.textContent = state.busy || "";
      } else {
        var bits = [];
        bits.push(list.length + (list.length === 1 ? " member" : " members"));
        if (state.pending.length) bits.push(state.pending.length + " pending");
        if (state.busy) bits.push(state.busy);
        statusLine.textContent = bits.join(" · ");
      }

      membersHead.textContent = list.length ? "Members (" + list.length + ")" : "Members";
      members.textContent = "";
      if (!list.length) {
        members.appendChild(api.el("p", "run-empty", "No members. Join a listen address below, or wait for someone to join you."));
      } else {
        list.forEach(function (m) { members.appendChild(memberRow(m)); });
      }

      joinHint.textContent = (s && s.listen)
        ? "This instance listens on " + s.listen + ". Give that address to another clanker, or join one below."
        : "Join another instance by its mesh listen address (host:port), not its web UI port.";

      pendHead.textContent = state.pending.length
        ? "Pending joins (" + state.pending.length + ")"
        : "Pending joins";
      pending.textContent = "";
      if (!state.pending.length) {
        pending.appendChild(api.el("p", "run-empty", "No pending joins."));
      } else {
        state.pending.forEach(function (p) { pending.appendChild(pendingRow(p)); });
      }

      leaveSelf.hidden = !list.length;
      leaveSelf.disabled = !!state.busy;
      joinBtn.disabled = !!state.busy;
      refresh.disabled = !!state.busy;
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
        state.loadedAt = Date.now();
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
      if (state.busy && state.busy !== "Loading…") return Promise.resolve();
      state.busy = "Working…";
      draw();
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
      if (!ev || container.hidden) return;
      if (ev.t === "mesh" || ev.t === "talk") load();
    });

    /* Both timers idle while the view is hidden: without the guard, opening
       Mesh once left this polling /api/mesh/* every 4s for the life of the
       tab, from a view nobody could see. api.onLive above still refreshes
       instantly on mesh events, and refresh() covers re-entry. */
    poll = setInterval(function () {
      if (container.hidden || state.busy) return;
      load();
    }, 4000);
    tick = setInterval(function () {
      if (container.hidden || !state.pending.length) return;
      draw();
    }, 1000);

    load();
  },
  refresh: function (container, api) {
    var btn = container.querySelector("#mesh-refresh");
    if (btn) btn.click();
  }
});
