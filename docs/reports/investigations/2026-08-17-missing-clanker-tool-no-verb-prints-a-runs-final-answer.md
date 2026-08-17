# Investigation — No CLI verb prints a completed run's final answer

## TL;DR

- **Question:** clanker run prints the answer once to stdout; after it scrolls away there is no way back to it. clanker graph run-<id> shows the timeline (sizes, durations, 'done 0 B, length') but not the text; clanker sessions / session export cover repl-*/sess-* transcripts, not run-* records. Recovering an answer means hand-parsing state/runs/run-<id>.json. A basic operator verb is missing: print the final answer (and per-node output) of a recorded run.
- **Finding:** Resolved on 2026-08-17. Resolved on 2026-08-17. clanker graph answer [run-id] prints a run's recorded final answer (graph guest answer mode); the final node now retains up to 64 KiB (graph_mod.final_answer_cap) instead of the 4000-byte preview, and an older or truncated record says how much of the answer it holds. Verified live (the empty length-stopped run explains itself) and by the graph-answer assertion in tests/e2e/tool_roundtrip_test.zig.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. clanker graph answer [run-id] prints a run's recorded final answer (graph guest answer mode); the final node now retains up to 64 KiB (graph_mod.final_answer_cap) instead of the 4000-byte preview, and an older or truncated record says how much of the answer it holds. Verified live (the empty length-stopped run explains itself) and by the graph-answer assertion in tests/e2e/tool_roundtrip_test.zig.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. clanker graph answer [run-id] prints a run's recorded final answer (graph guest answer mode); the final node now retains up to 64 KiB (graph_mod.final_answer_cap) instead of the 4000-byte preview, and an older or truncated record says how much of the answer it holds. Verified live (the empty length-stopped run explains itself) and by the graph-answer assertion in tests/e2e/tool_roundtrip_test.zig.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

Checked 2026-08-17 while retrieving a review answer from run-1786940774:

- `clanker graph run-1786940774` renders the per-iteration timeline; the final node prints as `done 0 B, length` — size and stop reason, never the text.
- `clanker sessions` does not list run-* records, and `clanker session search` over the review's words returned 'no conversations matched': runs live in state/runs/, sessions in state/sessions/, and the session verbs read only the latter.
- The answer was recovered by parsing state/runs/run-1786940774.json by hand (python, nodes[-1].output) — exactly the ad-hoc fallback the tooling exists to remove.

Related: docs/reports/bugs/2026-08-17-run-reports-success-on-empty-length-stop.md (found in the same trace: that final output was empty and the run still recorded success).