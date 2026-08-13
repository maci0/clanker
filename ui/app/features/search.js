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
// Opening a hit switches to that conversation and lands on the turn that
// matched: the message index travels with the click, app.js records which
// message indices each replayed turn covers, and the turn is scrolled to,
// flagged for a moment and marked with the query. On a long conversation
// opening at the top was much the same as not going there.
import { readJson, formatChatTime, searchFoldFind } from "../core/utils.js";

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
  var origFrom = 0;
  var foldFrom = 0;
  for (;;) {
    var hit = searchFoldFind(text, needle, foldFrom);
    if (!hit) break;
    if (hit.start > origFrom) parent.appendChild(document.createTextNode(text.slice(origFrom, hit.start)));
    var m = document.createElement("mark");
    m.textContent = text.slice(hit.start, hit.end);
    parent.appendChild(m);
    origFrom = hit.end;
    foldFrom = hit.next;
  }
  if (origFrom < text.length) parent.appendChild(document.createTextNode(text.slice(origFrom)));
}

function hitRow(h) {
  var row = document.createElement("button");
  row.type = "button";
  row.className = "secondary search-hit";
  row.setAttribute("aria-label", "Open " + (h.title || h.id) + " at turn " + (h.turn + 1));

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
    // The query goes with the index so the turn can be marked on arrival with
    // the same text the server matched, rather than with whatever is in the
    // box by the time the transcript finishes loading.
    if (openSession) openSession(h.id, { index: h.turn, query: state.query });
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
    list.setAttribute("aria-busy", "true");
    var loading = document.createElement("p");
    loading.className = "run-empty";
    loading.textContent = "Searching…";
    list.appendChild(loading);
    return;
  }
  list.removeAttribute("aria-busy");
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
function setSearchBusy(on) {
  var btn = byId("search-go");
  var input = byId("search-q");
  if (btn) btn.disabled = on;
  if (input) input.setAttribute("aria-busy", on ? "true" : "false");
}

export function runSearch(q) {
  state.query = (q || "").trim();
  if (state.query.length < state.minLen) {
    state.hits = [];
    state.truncated = false;
    state.searching = false;
    state.error = "";
    setSearchBusy(false);
    render();
    return Promise.resolve(null);
  }
  // Every keystroke can start one of these; only the newest may draw, or a
  // slow early query lands on top of a later one's results.
  var mine = ++seq;
  state.searching = true;
  state.error = "";
  setSearchBusy(true);
  render();
  return fetch("/api/sessions/search?q=" + encodeURIComponent(state.query))
    .then(readJson)
    .then(function (data) {
      if (mine !== seq) return null;
      state.hits = (data && data.hits) || [];
      state.truncated = !!(data && data.truncated);
      state.error = "";
      state.searching = false;
      setSearchBusy(false);
      render();
      return data;
    })
    .catch(function (err) {
      if (mine !== seq) return null;
      state.searching = false;
      state.hits = [];
      state.error = err.message;
      setSearchBusy(false);
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
