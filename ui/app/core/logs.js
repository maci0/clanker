// Vanilla, no bundler. Log tail viewer — list + tail fetch, no app state.
export function loadLog(name, els, readJson, fmtBytes) {
  if (!name) return Promise.resolve();
  return fetch("/api/logs/" + encodeURIComponent(name))
    .then(readJson)
    .then(function (d) {
      els.logView.textContent = d.text || "(empty)";
      els.logView.scrollTop = els.logView.scrollHeight;
      els.logsStatus.textContent = "Showing the tail of " + d.name + " (" + fmtBytes(d.bytes) + " total).";
    })
    .catch(function (err) { els.logsStatus.textContent = "Could not read log: " + err.message; });
}

export function loadLogList(els, readJson, fmtBytes) {
  return fetch("/api/logs")
    .then(readJson)
    .then(function (d) {
      var logs = (d.logs || []).slice().sort(function (a, b) { return a.name < b.name ? 1 : -1; });
      var keep = els.logSelect.value;
      els.logSelect.textContent = "";
      logs.forEach(function (l) {
        var opt = document.createElement("option");
        opt.value = l.name;
        opt.textContent = l.name + "  \u00b7  " + fmtBytes(l.bytes);
        els.logSelect.appendChild(opt);
      });
      if (!logs.length) {
        els.logView.textContent = "No logs yet. clanker writes them under state/logs/.";
        return;
      }
      els.logSelect.value = keep && els.logSelect.querySelector('option[value="' + keep.replace(/"/g, '\\"') + '"]') ? keep : logs[0].name;
      return loadLog(els.logSelect.value, els, readJson, fmtBytes);
    })
    .catch(function (err) { els.logsStatus.textContent = "Could not list logs: " + err.message; });
}
