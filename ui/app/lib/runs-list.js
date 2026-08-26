// The Runs view's browsable list. `GET /api/runs` sends a page of run
// summaries and nothing else — no start time, no failure flag until a graph is
// re-recorded — so this module derives what a reader needs from what a
// summary has, and stays pure so `node --test` can drive it.
//
// Dating a row matters more here than it looks: every field the picker showed
// (id, task, provider, duration) is timeless, which is how a listing that had
// gone stale still read as current. A row that says "3d ago" cannot.

/** Nanoseconds is the widest clock a run id carries; see runStartedAt. */
const NS_DIGITS = 19;
/** Milliseconds is 13 of those digits. */
const MS_DIGITS = 13;

/* Two id shapes, two clocks: `run-<unix seconds>` for a top-level run and
   `sub-<unix nanoseconds>` for a nested one (src/agent/subagent.zig). Both are
   padded out to nanosecond width and cut back to milliseconds, which keeps the
   arithmetic in strings — 1786563209053324602 is past Number.MAX_SAFE_INTEGER
   and would lose its low digits as a float. Mirrors graph_listing.runOrderKey
   on the Zig side; the two must agree or the list disagrees with its order. */
export function runStartedAt(run) {
  const id = run && run.run_id;
  if (typeof id !== "string") return 0;
  const dash = id.indexOf("-");
  if (dash < 0) return 0;
  const prefix = id.slice(0, dash);
  if (prefix !== "run" && prefix !== "sub") return 0;
  const digits = id.slice(dash + 1);
  if (!digits.length || digits.length > NS_DIGITS || !/^\d+$/.test(digits)) return 0;
  return Number(digits.padEnd(NS_DIGITS, "0").slice(0, MS_DIGITS));
}

function startOfDay(ms) {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Whole calendar days between two instants, not 24-hour blocks: a run at
    23:50 was "yesterday" by 00:10, however few hours have passed. */
function calendarDaysAgo(startedAt, now) {
  return Math.round((startOfDay(now) - startOfDay(startedAt)) / 86400000);
}

/* Dates and relative labels follow the runtime locale, the way core/utils.js
   formats them (Intl.RelativeTimeFormat, toLocaleDateString): a listing opened
   on a German or Japanese machine reads its own month names and its own
   "yesterday", not English ones wired into this file. */
const RELATIVE = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

function dayStamp(startedAt, withYear) {
  const opts = withYear
    ? { year: "numeric", month: "short", day: "numeric" }
    : { month: "short", day: "numeric" };
  return new Date(startedAt).toLocaleDateString(undefined, opts);
}

/** "now" / "12 minutes ago" / "3 hours ago" / "yesterday" / "Aug 11". Empty
    for a run whose id carries no timestamp — better no date than an invented
    one. */
export function fmtWhen(startedAt, now) {
  if (!startedAt) return "";
  const ms = now - startedAt;
  if (ms < 60000) return RELATIVE.format(0, "second");
  if (ms < 3600000) return RELATIVE.format(-Math.floor(ms / 60000), "minute");
  if (ms < 86400000) return RELATIVE.format(-Math.floor(ms / 3600000), "hour");
  if (calendarDaysAgo(startedAt, now) === 1) return RELATIVE.format(-1, "day");
  return dayStamp(startedAt, false);
}

/** The heading a row sits under. */
export function dayBucket(startedAt, now) {
  if (!startedAt) return "Undated";
  const days = calendarDaysAgo(startedAt, now);
  if (days === 0) return RELATIVE.format(0, "day");
  if (days === 1) return RELATIVE.format(-1, "day");
  return dayStamp(startedAt, new Date(startedAt).getFullYear() !== new Date(now).getFullYear());
}

/* A summary reports `nodes` as a count while a whole graph reports it as an
   array, and this is called with both. Reading `.some` off the count is what
   made the `failed` filter throw rather than filter. */
export function runFailed(run) {
  if (!run) return false;
  if (run.failed === true || run.ok === false) return true;
  return Array.isArray(run.nodes) && run.nodes.some(function (n) { return n && n.ok === false; });
}

const FAILED_WORDS = ["failed", ":failed", "⚠ failed"];

/** The filter box: a text match over id, task and provider, except for the
    `failed` keyword, which selects on state instead. */
export function matchesRunQuery(run, query) {
  const q = (query || "").trim().toLowerCase();
  if (!q) return true;
  if (FAILED_WORDS.indexOf(q) !== -1) return runFailed(run);
  const hay = [run.run_id, run.task, run.provider];
  for (let i = 0; i < hay.length; i++) {
    if (typeof hay[i] === "string" && hay[i].toLowerCase().indexOf(q) !== -1) return true;
  }
  return false;
}

/** One display row per run, in the order the listing sent them (the guest
    already orders newest first, chronologically across both id shapes). */
export function runRows(runs, opts) {
  const o = opts || {};
  const now = typeof o.now === "number" ? o.now : Date.now();
  const query = o.query || "";
  const out = [];
  (runs || []).forEach(function (r) {
    if (!r || typeof r.run_id !== "string") return;
    if (!matchesRunQuery(r, query)) return;
    const startedAt = runStartedAt(r);
    const task = (r.task || "").replace(/\s+/g, " ").trim();
    out.push({
      id: r.run_id,
      parentId: r.parent_run_id || "",
      nested: !!(r.parent_run_id && r.parent_run_id.length),
      task: task || "(no task)",
      provider: r.provider || "",
      nodes: r.nodes || 0,
      durationMs: r.duration_ms || 0,
      tokens: (r.prompt_tokens || 0) + (r.completion_tokens || 0),
      failed: runFailed(r),
      startedAt: startedAt,
      when: fmtWhen(startedAt, now),
      day: dayBucket(startedAt, now),
    });
  });
  return out;
}

/** Rows under one heading each, in the order the rows arrived. */
export function groupRunsByDay(rows, now) {
  const at = typeof now === "number" ? now : Date.now();
  const groups = [];
  const byDay = Object.create(null);
  (rows || []).forEach(function (row) {
    const day = row.day || dayBucket(row.startedAt, at);
    let g = byDay[day];
    if (!g) {
      g = { day: day, rows: [] };
      byDay[day] = g;
      groups.push(g);
    }
    g.rows.push(row);
  });
  return groups;
}
