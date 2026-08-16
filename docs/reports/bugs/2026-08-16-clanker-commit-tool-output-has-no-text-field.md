# Bug — clanker commit always fails: smart_commit returns no text field

## TL;DR

- **What failed:** clanker commit routes smart_commit through toolText, which returns error.ToolBadOutput unless the reply carries a 'text' string (src/cli.zig:4872). smart_commit emits {ok, dry_run, note?, excluded?, commits[]} and no text, so every invocation ends in 'the internal tool returned unreadable output' after paying for the grouping LLM call.
- **Impact:** `clanker commit` is unusable in every mode, on every tree, with any wasm build. It is the documented way to group a working tree into conventional commits, so its failure pushes every agent and operator back to hand-rolled `git commit` — exactly what the tooling mandate exists to prevent. Each attempt pays for the grouping LLM call before failing.
- **Resolution:** Open.

## Status

Resolved on 2026-08-16. cmdCommit now calls toolJson with a structured body and renders via the pure commit_logic.renderPlan (4 new host tests). Verified: clanker commit --dry-run prints a proposal instead of erroring; answering y at the prompt moved HEAD 0e216cd5 -> 612d8079 with the expected single commit, so defect 2 (the post-confirmation dry run) is gone; the applied wording reads 'committed' where the proposal reads 'would write'.

## Symptom and impact

Every `clanker commit` invocation prints:

```
error: the internal tool returned unreadable output; run `clanker doctor` to check the build
```

The advice in that message is a red herring. The build is fine: `zig build`
and `zig build tools` both exit 0, and the failure reproduces against wasm
compiled minutes earlier. Nothing is wrong with the guest either — it runs to
completion and returns a well-formed object. The host rejects the shape of
that object.

On a tree with many changed files the failure is immediate. With a single file
staged it arrives after a ~3.8s, ~1223-token LLM round trip, because the guest
gets as far as asking a model to group the diff and only then returns.

## Reproduction

Stage anything and run the verb:

```bash
git add CLAUDE.md
clanker commit --dry-run
```

Observed, with `--verbose`:

```
[INFO] [exec] -> git
[INFO] [exec] ok git ... 5ms
[INFO] [exec] -> git
[INFO] [exec] ok git ... 1ms
[INFO] [llm] -> ck_llm
[INFO] [llm] ok ck_llm ... 3846ms (~1223 est. tokens)
error: the internal tool returned unreadable output; run `clanker doctor` to check the build
```

With a large working tree the two `git` execs still run, the LLM call is not
reached, and the same error follows.

## Root cause

Two defects, the second hidden behind the first.

**1. The host demands a field the guest never emits.**

`cmdCommit` (`src/cli.zig:5894`) calls the guest through `toolText`
(`src/cli.zig:4841`). `toolText` parses the reply and requires a `text`
string:

```zig
const text = parsed.object.get("text") orelse return error.ToolBadOutput;
if (text != .string) return error.ToolBadOutput;
```

`src/main.zig:321` renders `error.ToolBadOutput` as the "unreadable output"
message. The smart_commit guest writes `{ok, dry_run, note?, excluded?,
commits[{message, files}]}` (`tools/zig/smart_commit.zig:93`), and its
empty-tree path writes `{ok, commits, message, excluded?}`
(`tools/zig/smart_commit.zig:123`). Neither carries `text`. The verb therefore
cannot succeed under any input, and the reply the host discards is the
finished commit proposal.

`toolText` is the right helper for a tool whose contract is rendered text —
`cmdStats` uses it against `model_stats`, which does emit `text`. smart_commit
is a structured tool, so it was the wrong helper to reach for.

**2. The tool never receives its arguments.**

`toolText` wraps its `args` parameter as `{"args": "<that string>"}`, which is
the shape an args-style tool expects; `cmdStats` passes `{"args":""}`
accordingly. `cmdCommit` instead passes the tool own structured JSON as that
string:

```zig
const preview = try toolText(io, init.gpa, arena, &cfg, init.environ_map, "smart_commit", "{\"dry_run\":true,\"scope\":\"staged\"}");
```

so the guest receives `{"args":"{\"dry_run\":true,\"scope\":\"staged\"}"}` and
finds neither key. It falls back to its own defaults, and `dry_run` defaults to
**true** (`tools/zig/smart_commit.zig:16`).

That matters for the second call. `src/cli.zig:5916` is the one that runs after
the operator answers "Proceed? [y/N]", and it is meant to write. It is a dry
run as well. Fix defect 1 alone and `clanker commit` becomes a verb that shows
a proposal, asks for confirmation, commits nothing, and reports success. It
fails safe today only by accident.

## Resolution

Not fixed yet. The repair is owned by another session (clanker-3a), which is
implementing the shape below; this record owns the diagnosis.

`cmdCommit` stops calling `toolText` and calls `toolJson` with the structured
body, so `dry_run` and `scope` reach the guest and the post-confirmation call
becomes a real `dry_run:false` write. The rendering moves host-side into
`tools/zig/commit_logic.zig` as a pure `renderPlan`, host-tested like the rest
of that file — the same split `model_stats_logic` and `sessions_logic` already
use.

The alternative, making the guest emit a rendered `text`, was rejected: it
hands every consumer a pre-formatted blob to parse around, and it leaves
`toolText`s `{"args": "<string>"}` wrapper in the path, which is the mechanism
that silently turned a structured body into an ignored key. Fixing the call
shape is the repair; adding `text` papers over it.

A renderer must handle both reply shapes. `writeEmpty`
(`tools/zig/smart_commit.zig:123`) emits `{ok, commits: [], message: "nothing
to commit", excluded?}` — a top-level `message`, not the per-commit one.

## Verification

None yet; the defect is confirmed by reading the source and by the
reproduction above, not by a passing fix.

When the fix lands, the checks that decide it:

- `clanker commit --dry-run` with one file staged prints a grouped proposal
  and exits 0.
- `clanker commit` answered `y` actually creates the commits — `git log`
  shows them. This is the check that catches defect 2; a run that prints a
  proposal, accepts the confirmation and leaves `git log` unchanged is the
  bug still present.
- `clanker commit --dry-run` on a clean tree reports nothing to commit rather
  than failing, exercising the `writeEmpty` shape.

Note that `zig build test` and `clanker gate` were not run for this record:
the operator asked that no test run be started while several sessions were
racing to push.

## Follow-up

Every other caller of `toolText` passes an args-style string, so the pairing
is only wrong at `src/cli.zig:5901` and `:5916`. Worth a cheap guard anyway:
`toolText` cannot tell a structured body from an args string today, and a
manifest whose `input_schema` has named properties is exactly the case where
the wrapper is wrong. A gate check, or a comment on `toolText` naming the
contract it assumes, would stop the next caller from repeating it.

## References

- `src/cli.zig:4841` `toolText`, `:4872` the `text` requirement, `:5894`
  `cmdCommit`, `:5901` and `:5916` the two call sites.
- `src/main.zig:321` maps `error.ToolBadOutput` to the operator message.
- `tools/zig/smart_commit.zig:16` the `dry_run` default, `:93` the reply
  shape, `:123` `writeEmpty`.
- `src/cli.zig:5891` `cmdStats` passing `{"args":""}` to `model_stats`, the
  correct use of the same helper.
- [PRD 0021](../../prds/0021-smart-commit.md) — what the verb is meant to do.
- Investigation: none; the trace is in this record.
