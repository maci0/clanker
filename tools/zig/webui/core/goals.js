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
  return s;
}

export function isActiveGoal(g) { return (g.status || "active") === "active"; }

/* The board column a goal's mirror card must sit in, or null when the goal
   does not pin one (an active goal that nobody is running lives wherever it
   was parked; done/abandoned goals only pin a column via explicit re-sync). */
export function goalPinnedColumn(g, running) {
  var s = g.status || "active";
  if (s === "done") return "done";
  if (s === "review") return "review";
  if (s === "active" && running) return "doing";
  return null;
}


