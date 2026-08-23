# Bug — a preset's denied tools are still offered to the model; repl --preset is a silent no-op

## TL;DR

- **What failed:** Agent.init rebuilds the tool list from the registry via lazyToolDefs whenever agent.tool_catalog is on (the default), discarding the filterNames result cmdRun computed one line earlier; a.preset is only assigned after init returns. rebuildToolDefs and loadTools have no preset check either, so load_tools can re-reveal a denied tool. Only the dispatch gate refuses, so PRD 0033's neither-offered-nor-callable fails on offered. repl --preset never reaches ReplOptions.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

PRD 0033's acceptance criterion is that a preset-denied write-capable tool is
**neither offered nor callable**. Only the second half holds.

`cmdRun` computes `preset_mod.filterNames` into `tool_defs` and logs
"preset '<name>' active: N tools allowed". `Agent.init` then throws that list
away whenever `cfg.agent.tool_catalog` is on — which is the default — because
it rebuilds the list from the registry with `reg.lazyToolDefs(...)`, a function
with no preset parameter. `a.preset` is only assigned *after* `init` returns, so
`init` could not have filtered even if it wanted to, and the system prompt's
catalog text (`reg.catalogText`) enumerates every registry tool including the
denied ones.

Two more holes on the same seam:

- `rebuildToolDefs` re-derives the list mid-run from `lazyToolDefs` with no
  preset consultation — even though PRD 0033's Design names that function as
  exactly where the mask belongs.
- `loadTools` reveals any named tool with no preset check, so under
  `--preset research` the model can call
  `load_tools({"names":["edit_file"]})`, receive `edit_file`'s full schema in
  the tool result, and have it offered on every later turn.

So the run degrades into the model repeatedly reaching for denied tools and
getting `preset denied …` back, which is the dispatch gate doing the work the
offering layer was supposed to have done.

Separately, `clanker repl --preset <name>` is in the flag table, listed as
valid for `repl`, and advertised in `repl --help` — and is a silent no-op:
`cmdReplVaxis`' options literal passes eleven fields and not that one, and
`ReplOptions` has no `preset` field at all. The existing test only pins
"accepted implies documented", never "accepted implies used".

## Reproduction

```bash
clanker run --preset research 'list every tool you have been given a schema for'
```

`edit_file`, `exec` and `subagent` are in the answer. Same for
`clanker repl --preset research`, which additionally shows no status pill and
applies no `system_prompt_append`.

## Root cause

The preset mask is applied at one call site (`cmdRun`) rather than at the seam
where the tool list reaches the provider. `Agent` owns three places that build
or extend that list (`init`, `rebuildToolDefs`, `loadTools`) and none of them
consult `self.preset`.

## Resolution

Open. The single seam is `Agent.iterTools`, the one expression that hands tools
to the request — masking there covers `init`'s catalog build, a mid-run
`rebuildToolDefs`, and a `load_tools` reveal at once, and covers the REPL and
`ck_subagent` without touching their call sites. `load_tools` itself needs an
exemption or a preset with a non-empty `tools_allow` (e.g. `minimal.toml`) loses
the catalog's only door. The catalog *text* in the system prompt wants the same
mask, which needs a preset-aware `catalogText`/`lazyToolDefs` in
`src/toolhost/registry.zig`.

`repl --preset` needs a `preset` field on `ReplOptions` and one line in
`cmdReplVaxis`' options literal.

## Verification

There are no tests for `--preset` flag threading or for the dispatch gate:
`grep 'test "' src/cli.zig src/agent/loop.zig | grep -i preset` is empty. Only
`src/preset/preset.zig`'s pure unit tests exist, and they pass because the pure
part is correct. A fix wants a test that asserts the *offered* list, not just
the refusal.

## Follow-up

PRD 0057 (nested explore/plan/coder presets) has "tools_deny is enforced" as
Goal 3 and is unbuilt. It should not be built on top of an offering layer that
does not enforce.

## References

- PRD: [0033-agent-presets.md](../../prds/0033-agent-presets.md),
  [0057-nested-explore-plan-coder-presets.md](../../prds/0057-nested-explore-plan-coder-presets.md)
- Code: `src/agent/loop.zig` (`Agent.init`, `rebuildToolDefs`, `loadTools`,
  `iterTools`, `toolPolicy`), `src/cli.zig` (`cmdRun`'s filter, `cmdReplVaxis`
  dispatch), `src/tui/repl.zig` (`ReplOptions`), `src/toolhost/registry.zig`
  (`lazyToolDefs`, `catalogText`), `src/preset/preset.zig`

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
