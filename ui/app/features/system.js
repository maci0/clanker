/* The System view's two admin panels: the raw config editor and the MCP
   server list. Both are System-only DOM and both used to be top-level IIFEs
   in app.js that bound *and fetched* at page load, so a chat-only visit
   downloaded 12.5 KB raw it never ran and paid for a GET /api/config/raw
   and a GET /api/mcp/servers it never read. They load with the System view now,
   like every other feature view. */
import { readJson, wireRefresh } from "../core/utils.js";
import { paintTomlInto } from "../core/vendor.js";
import { uiConfirm, showLoadError, upgradePfButton } from "../core/ui.js";

/* ---- config editor (System view) ----------------------------------------
   Raw TOML editing with validate-before-write: POST /api/config/raw refuses
   a config that does not load, so the server never leaves its last known
   good state; a valid save hot-restarts serve into the new config. The
   highlight is the overlay trick: the textarea owns the text and the caret,
   the <pre> behind it owns the colors. */
function bindConfigEditor() {
  var fileSel = document.getElementById("config-editor-file");
  var text = document.getElementById("config-editor-text");
  var code = document.getElementById("config-editor-code");
  var note = document.getElementById("config-editor-note");
  var saveBtn = document.getElementById("config-editor-save");
  var reloadBtn = document.getElementById("config-editor-reload");
  if (!fileSel || !text || !code) return;

  function setNote(msg) { if (note) note.textContent = msg; }

  var lastFile = fileSel.value;
  var savedText = "";
  function isDirty() { return text.value !== savedText; }
  function markClean() { savedText = text.value; }

  function paint() { paintTomlInto(text, code); }

  function syncScroll() {
    var pre = code.parentElement;
    pre.scrollTop = text.scrollTop;
    pre.scrollLeft = text.scrollLeft;
  }

  function load() {
    setNote("");
    fetch("/api/config/raw?file=" + encodeURIComponent(fileSel.value))
      .then(readJson)
      .then(function (d) {
        text.value = d.content || "";
        markClean();
        paint();
        syncScroll();
      })
      .catch(function (err) { setNote("Could not read " + fileSel.value + ": " + err.message); });
  }

  function confirmDiscard(next) {
    if (!isDirty()) { next(); return; }
    uiConfirm("Discard unsaved changes to " + lastFile + "?", { danger: true, confirmLabel: "Discard" }).then(function (yes) {
      if (yes) next();
    });
  }

  function save() {
    saveBtn.disabled = true;
    setNote("Validating…");
    fetch("/api/config/raw", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ file: fileSel.value, content: text.value }),
    })
      .then(readJson)
      .then(function (d) {
        markClean();
        setNote("Saved. " + (d.applied || "Hot reload applies it."));
      })
      .catch(function (err) {
        // readJson surfaces the server's {error} message on a 400.
        setNote("Refused: " + err.message + " — the running config is unchanged.");
      })
      .finally(function () { saveBtn.disabled = false; });
  }

  text.addEventListener("input", function () {
    paint();
    if (isDirty()) setNote("Unsaved changes.");
    else setNote("");
  });
  text.addEventListener("scroll", syncScroll);
  fileSel.addEventListener("change", function () {
    var nextFile = fileSel.value;
    if (nextFile === lastFile) return;
    if (!isDirty()) { lastFile = nextFile; load(); return; }
    fileSel.value = lastFile;
    confirmDiscard(function () {
      fileSel.value = nextFile;
      lastFile = nextFile;
      load();
    });
  });
  if (reloadBtn) reloadBtn.addEventListener("click", function () { confirmDiscard(load); });
  if (saveBtn) saveBtn.addEventListener("click", save);
  window.addEventListener("beforeunload", function (e) {
    if (!isDirty()) return;
    e.preventDefault();
    e.returnValue = "";
  });
  // Tab inserts two spaces instead of leaving the editor.
  text.addEventListener("keydown", function (e) {
    if (e.key !== "Tab") return;
    e.preventDefault();
    var s = text.selectionStart;
    text.setRangeText("  ", s, text.selectionEnd, "end");
    paint();
  });
  load();
}

/* ---- MCP servers (System view) -------------------------------------------
   CRUD over [mcp_servers.<name>] stanzas in config.local.toml, through the
   same validated table/set + table/remove pipeline every config write uses.
   Config is live now; the client bridge that connects ships behind
   modules.mcp_client (PRD 0032). */
function bindMcpServers() {
  var list = document.getElementById("mcp-list");
  var host = document.getElementById("mcp-edit");
  if (!list || !host) return;
  var statusEl = document.getElementById("mcp-status");

  function f(id) { return document.getElementById(id); }
  function note(msg) {
    var n = f("mcp-edit-note");
    if (n) { n.textContent = msg; n.hidden = !msg; }
    if (statusEl && msg) statusEl.textContent = msg;
  }
  function syncMcpTransportFields() {
    var transport = f("mcp-edit-transport") ? f("mcp-edit-transport").value : "stdio";
    var form = f("mcp-edit-form");
    if (!form) return;
    form.querySelectorAll("[data-mcp-for]").forEach(function (row) {
      row.hidden = row.getAttribute("data-mcp-for") !== transport;
    });
  }
  function tomlStr(v) {
    return '"' + String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
  }
  function splitList(v) {
    return String(v || "").split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  }

  function openEdit(s) {
    var isNew = !s;
    s = s || {};
    f("mcp-edit-title").textContent = isNew ? "Add an MCP server" : "mcp_servers." + s.name;
    f("mcp-edit-name").value = s.name || "";
    f("mcp-edit-name").disabled = !isNew;
    f("mcp-edit-transport").value = s.transport || "stdio";
    f("mcp-edit-command").value = s.command || "";
    f("mcp-edit-args").value = (s.args || []).join(", ");
    f("mcp-edit-cwd").value = s.cwd || "";
    f("mcp-edit-url").value = s.url || "";
    f("mcp-edit-timeout").value = s.tool_call_timeout_ms || "";
    // Values never round-trip (the listing withholds them); editing an
    // existing server keeps its env/headers unless new ones are typed.
    f("mcp-edit-env").value = "";
    f("mcp-edit-env").placeholder = (s.env_names || []).length
      ? "keeps: " + s.env_names.join(", ") + " (type to replace)"
      : "GITHUB_TOKEN=...";
    f("mcp-edit-headers").value = "";
    f("mcp-edit-headers").placeholder = (s.header_names || []).length
      ? "keeps: " + s.header_names.join(", ") + " (type to replace)"
      : "Authorization: Bearer ...";
    f("mcp-edit-remove").hidden = isNew;
    note("");
    syncMcpTransportFields();
    host.hidden = false;
    try { host.scrollIntoView({ behavior: "smooth", block: "nearest" }); } catch (_) {}
  }

  function buildBlock(name) {
    var lines = ['[mcp_servers.' + (/^[A-Za-z0-9_-]+$/.test(name) ? name : tomlStr(name)) + "]"];
    var transport = f("mcp-edit-transport").value;
    lines.push("transport = " + tomlStr(transport));
    var command = f("mcp-edit-command").value.trim();
    if (command) lines.push("command = " + tomlStr(command));
    var args = splitList(f("mcp-edit-args").value);
    if (args.length) lines.push("args = [" + args.map(tomlStr).join(", ") + "]");
    var env = splitList(f("mcp-edit-env").value);
    if (env.length) lines.push("env = [" + env.map(tomlStr).join(", ") + "]");
    var cwd = f("mcp-edit-cwd").value.trim();
    if (cwd) lines.push("cwd = " + tomlStr(cwd));
    var url = f("mcp-edit-url").value.trim();
    if (url) lines.push("url = " + tomlStr(url));
    var headers = splitList(f("mcp-edit-headers").value);
    if (headers.length) lines.push("headers = [" + headers.map(tomlStr).join(", ") + "]");
    var timeout = f("mcp-edit-timeout").value;
    if (timeout) lines.push("tool_call_timeout_ms = " + Number(timeout));
    return lines.join("\n") + "\n";
  }

  function save() {
    var name = f("mcp-edit-name").value.trim();
    if (!name) { note("Name is required."); return; }
    var transport = f("mcp-edit-transport").value;
    if (transport === "stdio" && !f("mcp-edit-command").value.trim()) {
      note("stdio needs a command to spawn.");
      f("mcp-edit-command").focus();
      return;
    }
    if (transport === "http" && !f("mcp-edit-url").value.trim()) {
      note("http needs a stream URL.");
      f("mcp-edit-url").focus();
      return;
    }
    var btn = f("mcp-edit-save");
    btn.disabled = true;
    fetch("/api/config/table/set", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ block: buildBlock(name) })
    })
      .then(readJson)
      .then(function (d) {
        if (!d.ok) throw new Error(d.error || "write failed");
        note("Saved. " + (d.applied || "The server reloads into it."));
        load();
      })
      .catch(function (err) { note("Refused: " + err.message + " — nothing was written."); })
      .finally(function () { btn.disabled = false; });
  }

  function removeServer() {
    var name = f("mcp-edit-name").value.trim();
    if (!name) return;
    import("./core/ui.js").then(function (mod) {
      return mod.uiConfirm("Remove MCP server " + name + " from config.local.toml?", { danger: true, confirmLabel: "Remove" });
    }).then(function (yes) {
      if (!yes) return;
      var header = "mcp_servers." + (/^[A-Za-z0-9_-]+$/.test(name) ? name : tomlStr(name));
      fetch("/api/config/table/remove", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ header: header })
      })
        .then(readJson)
        .then(function (d) {
          if (!d.ok) throw new Error(d.error || "remove failed");
          note(d.removed === false ? "Nothing by that name in config.local.toml (a server declared in the shared config.toml cannot be removed here)." : "Removed.");
          host.hidden = true;
          load();
        })
        .catch(function (err) { note("Refused: " + err.message); });
    });
  }

  function load() {
    fetch("/api/mcp/servers")
      .then(readJson)
      .then(function (d) {
        var servers = (d && d.servers) || [];
        list.textContent = "";
        if (!servers.length) {
          var p = document.createElement("p");
          p.className = "run-empty";
          p.appendChild(document.createTextNode("No MCP servers configured. "));
          var add = document.createElement("button");
          add.type = "button";
          add.className = "secondary";
          add.textContent = "Add server";
          add.addEventListener("click", function () { openEdit(null); });
          upgradePfButton(add);
          p.appendChild(add);
          p.appendChild(document.createTextNode(" to record one in config.local.toml. The client bridge that connects is not on yet."));
          list.appendChild(p);
          return;
        }
        servers.forEach(function (s) {
          var row = document.createElement("div");
          row.className = "settings-panel";
          var head = document.createElement("div");
          head.className = "subsection-head-row";
          var title = document.createElement("code");
          title.textContent = s.name;
          head.appendChild(title);
          var edit = document.createElement("button");
          edit.type = "button";
          edit.className = "secondary";
          edit.textContent = "Edit";
          edit.addEventListener("click", function () { openEdit(s); });
          head.appendChild(edit);
          row.appendChild(head);
          var meta = document.createElement("p");
          meta.className = "meta";
          meta.textContent = s.transport === "http"
            ? "http · " + s.url
            : "stdio · " + s.command + (s.args && s.args.length ? " " + s.args.join(" ") : "");
          row.appendChild(meta);
          list.appendChild(row);
        });
      })
      .catch(function (err) {
        var msg = "Could not load MCP servers: " + err.message;
        if (statusEl) statusEl.textContent = msg;
        showLoadError(list, msg, load);
      });
  }

  var addBtn = f("mcp-add");
  if (addBtn) addBtn.addEventListener("click", function () { openEdit(null); });
  var transportSel = f("mcp-edit-transport");
  if (transportSel) transportSel.addEventListener("change", syncMcpTransportFields);
  var refreshBtn = f("mcp-refresh");
  wireRefresh(refreshBtn, load);
  f("mcp-edit-save").addEventListener("click", save);
  f("mcp-edit-remove").addEventListener("click", removeServer);
  f("mcp-edit-close").addEventListener("click", function () { host.hidden = true; });
  load();
}

/* One entry point for the view loader; both panels bind and load their data
   the first time System is opened. Idempotent so a second open is a no-op. */
var bound = false;
export function bindSystemAdmin() {
  if (bound) return;
  bound = true;
  bindConfigEditor();
  bindMcpServers();
}
