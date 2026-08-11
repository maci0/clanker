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

export function goalStatusLabel(g) { return g.status || "unknown"; }

export function isActiveGoal(g) { return (g.status || "active") === "active"; }

if (typeof window !== "undefined") window.ckGoals = {
  goalSortKey: goalSortKey,
  goalFields: goalFields,
  goalStatusLabel: goalStatusLabel,
  isActiveGoal: isActiveGoal,
};
