// Vanilla, no bundler. Usage table — token/cost totals by provider/model.
export function usageColumns() {
  return [
    ["Provider / model", ""], ["Calls", "num"], ["Failed", "num"], ["Prompt", "num"],
    ["Completion", "num"], ["Cache hit", "num"], ["Tok/s", "num"], ["Cost", "num"],
  ];
}

export function usageName(r, modelLabel, T) {
  var shown = modelLabel(r.provider, r.model);
  if (shown === r.provider) return T.td(r.provider);
  return T.td(r.provider + " / ", T.span({ class: "model" }, shown));
}

export function usageRow(r, modelLabel, fmtInt, fmtCost, T) {
  return T.tr(usageName(r, modelLabel, T), [
    fmtInt(r.calls), fmtInt(r.error_calls || 0), fmtInt(r.prompt_tokens), fmtInt(r.completion_tokens),
    (r.cache_hit_rate || 0).toFixed(1) + "%", (r.tokens_per_sec || 0).toFixed(0), fmtCost(r.cost),
  ].map(function (v) { return T.td({ class: "num" }, v); }));
}

export function renderUsageTable(rows, modelLabel, fmtInt, fmtCost, UI, T) {
  if (!rows.length) return UI.empty("No completions recorded yet. Run a task and the totals appear here.");
  var totals = rows.reduce(function (a, r) {
    a.calls += r.calls || 0;
    a.failed += r.error_calls || 0;
    a.prompt += r.prompt_tokens || 0;
    a.completion += r.completion_tokens || 0;
    a.cost += r.cost || 0;
    return a;
  }, { calls: 0, failed: 0, prompt: 0, completion: 0, cost: 0 });
  var cols = usageColumns();
  return T.div({ class: "usage-wrap" },
    T.table({ class: "usage" },
      T.thead(T.tr(cols.map(function (col) {
        var th = T.th({ class: col[1] || null }, col[0]);
        th.setAttribute("scope", "col");
        return th;
      }))),
      T.tbody(rows.map(function (r) { return usageRow(r, modelLabel, fmtInt, fmtCost, T); })),
      T.tfoot(T.tr(
        T.td(rows.length + (rows.length === 1 ? " model" : " models")),
        [fmtInt(totals.calls), fmtInt(totals.failed), fmtInt(totals.prompt), fmtInt(totals.completion), "", "", fmtCost(totals.cost)]
          .map(function (v) { return T.td({ class: "num" }, v); })))));
}
