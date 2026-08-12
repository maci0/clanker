// Pure goal helpers — no DOM, no van, no page state.
// Extracted so goal sorting/filtering/projection can be imported as ES module.

export function goalSortKey(a, b) {
  return (b.updated || 0) - (a.updated || 0);
}

export function goalFields(g) {
  return [["Done when", g.completion_criterion], ["Proof", g.proof],
    ["Boundaries", g.boundaries], ["Stop rule", g.stop_rule]]
    .filter(function (pair) { return !!pair[1]; });
}

/* What a goal's status pill says. `running` is transient truth from the
   server's run registry (or this browser's own run), not a stored status:
   an active goal with a run in flight reads "running", and a goal whose run
   finished reads "waiting for review" until a human marks it done or sends
   it back. */
export function goalStatusLabel(g, running) {
  var s = g.status || "unknown";
  if (s === "review") return "waiting for review";
  if (s === "active" && running) return "running";
  if (s === "archived" || s === "abandoned") return "archived";
  return s;
}

export function isActiveGoal(g) { return (g.status || "active") === "active"; }

/* The board column a goal's card must sit in, or null when an idle active
   goal is deliberately parked in one of the planning columns. */
export function goalPinnedColumn(g, running) {
  var s = g.status || "active";
  if (s === "done") return "done";
  if (s === "review") return "review";
  if (s === "archived" || s === "abandoned") return "archive";
  if (s === "active" && running) return "doing";
  return null;
}

