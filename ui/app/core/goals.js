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

/* Whether a goal is worktree-scoped, and what to say about it on hover, or
   null when it is not. The stored field is a truthy *string* with two writers
   that do not agree on its content: the web UI's checkbox writes the bare
   `"true"`, while the `goal` tool writes the run's branch/path. Both mean the
   same thing here — presence is the flag — so only the tooltip distinguishes
   them, and a value this does not recognise is still shown rather than
   dropped. */
export function goalWorktreeTitle(g) {
  var v = g && g.worktree;
  if (typeof v !== "string" || !v) return null;
  if (v === "true") return "Worked in its own git worktree and branch, not the shared checkout";
  return "Worked in its own git worktree and branch: " + v;
}

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

