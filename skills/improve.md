# Self-improvement skill

When asked to improve the codebase, fix a failing eval, or run `clanker improve-self`:
1. Read the failing eval output and the relevant source first.
2. Propose the smallest exact-match patch that fixes the root cause,
   applying it with `edit_file` per file. `patch_apply` is internal to the
   engine, never a model-callable tool — do not reach for it from a turn.
3. Cover the fix with a test or eval that reproduces the issue — alongside the
   fix, not instead of it. A patch that only adds test blocks is rejected once
   the last few accepted changes were also test-only (`improve.max_consecutive_test_only`),
   and one that adds a function plus its test but no caller is rejected as
   inert. Coverage is not the scarce thing here.
4. Never weaken the eval harness or the sandbox deny rules.
   Machine-facing tools (session_search, spill, and similar) must keep their
   documented JSON output shape even on an empty store: a plain-text
   "nothing here" message makes the capability evals score 0.00 and every
   staged tree fail "staged tree failed its own capability evals". An empty
   store is a valid empty list, not a failure (see
   docs/reports/bugs/2026-08-17-capability-evals-reject-empty-store-tools.md).
5. Before promotion, run the `gate` tool (`{}` runs build, tools, test; pass
   `{"gates":["build","tools","test","fmt"]}` before you report done). If it
   fails, fix the cause or reject the change rather than weakening a gate.
   Operators running `clanker gate` in a shell also get the source lint pass.
