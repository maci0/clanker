// Compare view: past blind comparisons, one opened at a time, its answers side
// by side in the order they were stored, and a button per column that records
// the pick.
//
// The one property this file exists to protect, and the reason it holds no
// model names of its own: nothing here may say which model wrote which answer
// before a pick is recorded. That is not enforced by this module being careful
// with what it paints — it is enforced upstream, by `/api/compare` asking the
// tool for an un-revealed read, so the payload this module receives has no
// provider and no model in it at all. There is nothing to leak into a tooltip,
// a data- attribute, or a JSON blob the tab holds and does not draw. Once a
// pick is on record the tool reveals, and the key below the columns is the
// reward for having chosen blind.
//
// Deliberately not here: starting a comparison. That is 2-8 concurrent model
// calls against a server that answers one request per connection, the same
// reason the Arena view links to `clanker arena` rather than starting a match.
//
// Reference: docs/prds/0006-webui.md, "Compare view".

function byId(id) { return document.getElementById(id); }

var state = {
  id: null,
  list: [],
  doc: null,
  // Guards the pick buttons against a second click while the first is in
  // flight: recording a pick rewrites the stored document, and two racing
  // writes would be two answers to a question asked once.
  picking: false
};

/* ------------------------------------------------------------------ listing */

export function loadCompareView() {
  var status = byId("compare-status");
  if (status) status.textContent = "Loading comparisons…";
  // A #compare/<id> deep link (bookmark, palette, another view) names the one
  // to open; consumed once, the way the arena/board/knowledge pending ids are.
  if (window._pendingCompareId) {
    state.id = window._pendingCompareId;
    window._pendingCompareId = null;
  }
  return fetch("/api/compare").then(function (r) { return r.json(); }).then(function (data) {
    var rows = (data && data.comparisons) || [];
    state.list = rows;
    renderPicker(rows);
    if (!rows.length) {
      if (status) status.textContent = "No comparisons yet. Run one with: clanker compare \"<prompt>\" --with a --with b";
      renderComparison(null);
      return null;
    }
    // Newest first from the tool, so the top row is the one just finished.
    return fetchComparison(state.id || rows[0].id);
  }).catch(function (err) {
    if (status) status.textContent = "Could not load comparisons: " + err.message;
  });
}

function renderPicker(rows) {
  var host = byId("compare-list");
  if (!host) return;
  host.textContent = "";
  rows.forEach(function (c) {
    var row = document.createElement("button");
    row.type = "button";
    row.className = "secondary compare-row";
    row.setAttribute("aria-pressed", c.id === state.id ? "true" : "false");
    var q = document.createElement("span");
    q.className = "compare-row-q";
    q.textContent = c.prompt || c.id;
    q.title = c.prompt || c.id;
    // Whether a judge reached a verdict, never whose. The listing is read
    // before anything is opened, so a winner's provider name here would
    // un-blind every comparison in it at once.
    var outcome = document.createElement("span");
    outcome.className = "meta compare-row-outcome";
    outcome.textContent = c.judged ? "judged" : "no verdict";
    row.appendChild(q);
    row.appendChild(outcome);
    row.addEventListener("click", function () { fetchComparison(c.id); });
    host.appendChild(row);
  });
}

/* ------------------------------------------------------------- one comparison */

function fetchComparison(id) {
  if (!id) return Promise.resolve(null);
  var status = byId("compare-status");
  if (status) status.textContent = "Loading comparison " + id + "…";
  return fetch("/api/compare/" + encodeURIComponent(id)).then(function (r) { return r.json(); }).then(function (data) {
    if (!data || !data.ok) throw new Error((data && data.error) || "no such comparison");
    state.id = id;
    state.doc = data;
    // The address bar names the open comparison, so it can be bookmarked and
    // shared the way #runs/<id> and #arena/<id> can.
    try {
      var want = "#compare/" + encodeURIComponent(id);
      if (location.hash !== want) history.replaceState(null, "", want);
    } catch (_) {}
    renderComparison(data);
    renderPicker(state.list);
    return data;
  }).catch(function (err) {
    if (status) status.textContent = "Could not load comparison: " + err.message;
    return null;
  });
}

function renderComparison(doc) {
  var head = byId("compare-prompt");
  var cols = byId("compare-answers");
  var foot = byId("compare-verdict");
  var key = byId("compare-key");
  var status = byId("compare-status");
  if (!cols) return;
  cols.textContent = "";
  if (foot) foot.textContent = "";
  if (key) { key.textContent = ""; key.hidden = true; }
  if (head) head.textContent = doc ? (doc.prompt || "") : "";
  if (!doc) return;

  var answers = doc.answers || [];
  var picked = doc.pick ? doc.pick.label : "";
  var winner = doc.verdict ? doc.verdict.winner : "";
  cols.dataset.count = String(answers.length);
  answers.forEach(function (a) {
    cols.appendChild(answerColumn(doc, a, picked, winner));
  });

  if (foot) renderVerdict(foot, doc, picked);
  if (key && doc.revealed) renderKey(key, answers);

  if (status) {
    status.textContent = doc.revealed
      ? (answers.length + " answers, revealed" + (picked ? ", you picked " + picked : "") + ".")
      : (answers.length + " answers, still blind. Read them, then pick one.");
  }
}

/* One answer, under nothing but its positional letter. `a.provider` and
   `a.model` do not exist on this object until the comparison is revealed, so
   the reveal branch is not a decision about what to show — it is all there is
   to show. */
function answerColumn(doc, a, picked, winner) {
  var col = document.createElement("article");
  col.className = "compare-answer";
  col.setAttribute("aria-labelledby", "compare-label-" + a.label);
  if (picked && picked === a.label) col.dataset.picked = "true";
  if (doc.revealed && winner && winner === a.label) col.dataset.winner = "true";

  var h = document.createElement("h4");
  h.className = "compare-answer-head";
  h.id = "compare-label-" + a.label;
  h.textContent = "Answer " + a.label;
  col.appendChild(h);

  var meta = document.createElement("p");
  meta.className = "meta";
  // Timing is what the CLI's own blind render shows beside each letter, and it
  // is not the key: how long an answer took says nothing about who wrote it
  // that the reader could act on. Kept at parity rather than invented here.
  meta.textContent = a.ok ? (a.ms + "ms") : ("no answer: " + (a.error || "unknown"));
  col.appendChild(meta);

  var body = document.createElement("div");
  body.className = "compare-answer-body";
  // Model-written text reaching the DOM as a text node: there is no
  // interpolation step here to escape, and none should be added.
  body.textContent = a.ok ? (a.text || "") : "";
  col.appendChild(body);

  if (doc.revealed) {
    var who = document.createElement("p");
    who.className = "meta compare-answer-who";
    who.textContent = a.model ? (a.provider + " / " + a.model) : (a.provider || "");
    col.appendChild(who);
  }

  if (a.ok) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "compare-pick";
    btn.textContent = picked === a.label ? ("Picked " + a.label) : ("Pick " + a.label);
    btn.disabled = !!picked;
    btn.setAttribute("aria-label", picked === a.label ? ("Answer " + a.label + " is your pick") : ("Pick answer " + a.label));
    btn.addEventListener("click", function () { recordPick(doc.id, a.label); });
    col.appendChild(btn);
  }
  return col;
}

function renderVerdict(host, doc, picked) {
  host.textContent = "";
  if (doc.verdict) {
    var v = document.createElement("p");
    v.className = "meta";
    var line = "Judge picked " + doc.verdict.winner;
    if (doc.revealed && doc.verdict.provider) {
      line += " (" + doc.verdict.provider + (doc.verdict.model ? " / " + doc.verdict.model : "") + ")";
    }
    if (doc.verdict.reason) line += ": " + doc.verdict.reason;
    v.textContent = line;
    host.appendChild(v);
  }
  if (picked) {
    var p = document.createElement("p");
    p.className = "meta compare-your-pick";
    var mine = "Your pick: " + picked;
    if (doc.pick && doc.pick.provider) {
      mine += " · " + doc.pick.provider + (doc.pick.model ? " / " + doc.pick.model : "");
    }
    p.textContent = mine;
    host.appendChild(p);
  }
  if (doc.synthesis) {
    var card = document.createElement("div");
    card.className = "tool-card";
    var ch = document.createElement("div");
    ch.className = "tool-card-head";
    ch.textContent = "Merged answer";
    var cb = document.createElement("div");
    cb.className = "tool-card-body";
    cb.textContent = doc.synthesis;
    card.appendChild(ch);
    card.appendChild(cb);
    host.appendChild(card);
  }
}

function renderKey(host, answers) {
  host.textContent = "";
  host.hidden = false;
  var h = document.createElement("h3");
  h.textContent = "Key";
  host.appendChild(h);
  var dl = document.createElement("dl");
  dl.className = "compare-key-list";
  answers.forEach(function (a) {
    var dt = document.createElement("dt");
    dt.textContent = a.label;
    var dd = document.createElement("dd");
    dd.textContent = a.model ? (a.provider + " / " + a.model) : (a.provider || "");
    dl.appendChild(dt);
    dl.appendChild(dd);
  });
  host.appendChild(dl);
}

/* ------------------------------------------------------------------- picking */

/* The same recording path `clanker compare --show <id> --pick <letter>` takes:
   one POST, straight to the `compare` tool, which rewrites the stored document
   and answers with it revealed. Nothing is decided client-side, so the letter a
   browser records and the letter a terminal records mean the same thing. */
function recordPick(id, label) {
  if (state.picking) return Promise.resolve(null);
  state.picking = true;
  var status = byId("compare-status");
  if (status) status.textContent = "Recording pick " + label + "…";
  return fetch("/api/compare/" + encodeURIComponent(id), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pick: label })
  }).then(function (r) { return r.json(); }).then(function (data) {
    if (!data || !data.ok) throw new Error((data && data.error) || "pick refused");
    state.doc = data;
    renderComparison(data);
    return data;
  }).catch(function (err) {
    if (status) status.textContent = "Could not record the pick: " + err.message;
    return null;
  }).then(function (out) {
    state.picking = false;
    return out;
  });
}

/* -------------------------------------------------------------------- bind */

export function bindCompare() {
  var refresh = byId("compare-refresh");
  if (refresh) refresh.addEventListener("click", function () { loadCompareView(); });
}
