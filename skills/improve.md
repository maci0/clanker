---
title: Self-improvement
description: When asked to run `clanker improve-self` or the self-improvement loop, or to fix a failing capability eval. Not ordinary code edits.
enabled: true
---

# Self-improvement

`clanker improve-self` is a host CLI loop. From an agent turn you cannot start
it from a tool sandbox; tell the operator to run it.

When fixing a failing eval or applying a patch in this turn:
1. Read the failing eval output and the relevant source first.
2. Smallest exact-match patch with `edit_file` per file. `patch_apply` is
   internal to the engine, never a model-callable tool.
3. Cover the fix with a test or eval that reproduces the issue, alongside the
   fix. A patch that only adds test blocks is rejected once the last few
   accepted changes were also test-only (`improve.max_consecutive_test_only`).
   A function plus its test but no caller is rejected as inert.
4. Never weaken the eval harness or the sandbox deny rules. Machine-facing
   tools (`session_search`, `spill`, and similar) must keep their documented
   JSON output shape even on an empty store: a plain-text "nothing here"
   message makes the capability evals score 0.00. An empty store is a valid
   empty list, not a failure (see
   docs/reports/bugs/2026-08-17-capability-evals-reject-empty-store-tools.md).
5. Before reporting done, run the `gate` tool (`{}` runs build, tools, test;
   `{"gates":["build","tools","test","fmt"]}` adds fmt). If it fails, fix the
   cause or reject the change. Operators running `clanker gate` in a shell
   also get the source lint pass. Never propose changes under `src/improve/`,
   `src/evals/`, or `src/toolhost/builder.zig`.
