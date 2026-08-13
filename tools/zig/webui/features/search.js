// Search view: find a saved conversation by what was said in it.
//
// The rail's filter box matches conversation titles, and titles are mostly
// auto-generated from the first line of the first task, so a conversation is
// findable by how it started and by nothing else. This searches the messages.
//
// Case-insensitive substring, matching GET /api/sessions/search. Deliberately
// not the fuzzy match the rail uses: fuzzy over whole transcripts matches
// nearly every conversation, and a search that always answers "all of them"
// is a search that answers nothing.
//
// Opening a hit switches to that conversation, which is the only action here.
// Jumping to the matching turn is not wired: the transcript renders from the
// top and there is no per-turn anchor to scroll to yet, so the turn number is
// shown but not followed. Better to say where it is than to pretend to go.
import { readJson, formatChatTime } from "../core/utils.js";

function byId(id) { return document.getElementById(id); }

var state = { query: "", hits: [], truncated: false, minLen: 3, searching: false, error: "" };
var openSession = null;

/** app.js owns switching conversations; it hands the callback in at bind. */
export function bindSearchDeps(deps) {
  openSession = deps && deps.openSession;
}

/* The matched run of characters, marked in place. The snippet is server-built
   text and reaches the DOM as text nodes either side of a <mark>; there is no
   interpolation step here, so nothing needs escaping and nothing should be
   added that would. */
function markInto(parent, text, needle) {
  var hay = text.toLowerCase();
  var pin = needle.toLowerCase();
  var from = 0;
  for (;;) {
    var at = pin ? hay.indexOf(pin, from) : -1;
    if (at === -1) break;
    if (at > from) parent.appendChild(document.createTextNode(text.slice(from, at)));
    var m = document.createElement("mark");
    m.textContent = text.slice(at, at + needle.length);
    parent.appendChild(m);
    from = at + needle.length;
  }
  if (from < text.length) parent.appendChild(document.createTextNode(text.slice(from)));
}

function hitRow(h) {
  var row = document.createElement("button");
  row.type = "button";
  row.className = "secondary search-hit";
  row.setAttribute("aria-label", "Open " + (h.title || h.id));

  var head = document.createElement("div");
  head.className = "search-hit-head";
  var title = document.createElement("span");
  title.className = "search-hit-title";
  title.textContent = h.title || h.id;
  head.appendChild(title);

  var when = document.createElement("span");
  when.className = "meta";
  when.textContent = formatChatTime(h.updated);
  head.appendChild(when);
  if (h.archived) {
    var arch = document.createElement("span");
    arch.className = "meta";
    arch.textContent = "archived";
    head.appendChild(arch);
  }
  row.appendChild(head);

  var body = document.createElement("p");
  body.className = "search-hit-snippet";
  markInto(body, h.snippet || "", state.query);
  row.appendChild(body);

  var foot = document.createElement("div");
  foot.className = "meta search-hit-foot";
  // The role and turn say where in the conversation it was, which is most of
  // what tells two hits in the same project apart.
  foot.textContent = h.role + " · turn " + (h.turn + 1) +
    (h.more ? " · " + h.more + " more match" + (h.more === 1 ? "" : "es") + " here" : "");
  row.appendChild(foot);

  row.addEventListener("click", function () {
    if (openSession) openSession(h.id);
  });
  return row;
}

function render() {
  var list = byId("search-results");
  var status = byId("search-status");
  if (!list) return;
  list.textContent = "";

  if (state.searching) {
    if (status) status.textContent = "Searching…";
    return;
  }
  if (state.query.length < state.minLen) {
    var hint = document.createElement("p");
    hint.className = "run-empty";
    hint.textContent = "Type at least " + state.minLen +
      " characters to search every saved conversation's messages.";
    list.appendChild(hint);
    if (status) status.textContent = "";
    return;
  }
  // A failed search is not an empty archive. Drawing "no conversation says
  // that" over a server error is the same mistake the feature views made
  // before they went through readJson.
  if (state.error) {
    var failed = document.createElement("p");
    failed.className = "run-empty";
    failed.textContent = "Search failed: " + state.error;
    list.appendChild(failed);
    if (status) status.textContent = "Search failed: " + state.error;
    return;
  }
  if (!state.hits.length) {
    var none = document.createElement("p");
    none.className = "run-empty";
    none.textContent = "No conversation says “" + state.query + "”.";
    list.appendChild(none);
    if (status) status.textContent = "No matches.";
    return;
  }
  state.hits.forEach(function (h) { list.appendChild(hitRow(h)); });
  if (status) {
    status.textContent = state.hits.length +
      (state.hits.length === 1 ? " conversation" : " conversations") +
      (state.truncated ? " (showing the newest; narrow the search for more)" : "") + ".";
  }
}

var seq = 0;
export function runSearch(q) {
  state.query = (q || "").trim();
  if (state.query.length < state.minLen) {
    state.hits = [];
    state.truncated = false;
    state.searching = false;
    state.error = "";
    render();
    return Promise.resolve(null);
  }
  // Every keystroke can start one of these; only the newest may draw, or a
  // slow early query lands on top of a later one's results.
  var mine = ++seq;
  state.searching = true;
  state.error = "";
  render();
  return fetch("/api/sessions/search?q=" + encodeURIComponent(state.query))
    .then(readJson)
    .then(function (data) {
      if (mine !== seq) return null;
      state.hits = (data && data.hits) || [];
      state.truncated = !!(data && data.truncated);
      state.error = "";
      state.searching = false;
      render();
      return data;
    })
    .catch(function (err) {
      if (mine !== seq) return null;
      state.searching = false;
      state.hits = [];
      state.error = err.message;
      render();
      return null;
    });
}

export function loadSearchView() {
  var input = byId("search-q");
  // Coming back to the view keeps whatever was typed, and re-runs it so the
  // results are not older than the conversations behind them.
  if (input && input.value.trim()) return runSearch(input.value);
  render();
  return Promise.resolve(null);
}

var timer = null;
export function bindSearch() {
  var input = byId("search-q");
  var btn = byId("search-go");
  if (btn) btn.addEventListener("click", function () { runSearch(input ? input.value : ""); });
  if (input) {
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); runSearch(input.value); }
    });
    // Typing searches on its own after a pause. Every query reads every saved
    // conversation off disk, so this waits for the typing to stop rather than
    // doing that per keystroke.
    input.addEventListener("input", function () {
      if (timer) window.clearTimeout(timer);
      timer = window.setTimeout(function () { runSearch(input.value); }, 250);
    });
  }
}
