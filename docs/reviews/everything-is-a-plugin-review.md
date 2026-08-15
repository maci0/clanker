# Everything-is-a-plugin review

A repeatable audit of the tree against the philosophy in README.md and
AGENTS.md ("Everything is a plugin" / "WASM by default"). Re-run it after
any stretch of feature work; append a dated findings section at the bottom
and move actionable items into docs/ROADMAP.md.

## The question

For every capability: *what is its plugin shape, and is it in it?* The
pluggable shapes are:

- WASM tool guest: `tools/zig/*.zig` (or `tools/ts/`) + `tools/manifests/*.tool.json`,
  pure logic split into a `host_tested_helpers` module.
- Provider vtable: one `src/llm/providers/<name>.zig` + one registry row +
  one `ProviderKind` tag. Never a `switch (provider.kind)` outside `providers/`.
- Web UI plugin view: a directory under `ui/plugins/` (`plugin.json` +
  `app.js`), registered at request time, no rebuild.
- Data surfaces: `skills/*.md`, the prompts store, `workflows/`.

The reference migration is `tools/zig/logs.zig`: native handler deleted,
guest owns listing/name-check/tail, pure helper host-tested. The reference
recorder split is `model_stats`/`autolearn`/`reasoning`: native writer at
the choke point, guest reader.

## Pass 1 — core code that should be a plugin

Walk `src/` and rank capabilities that could be drop-in units but are not:

1. For each `/api/*` handler in `src/cli.zig`: does it call `toolJson`/
   `toolText` (bridged) or reimplement logic a guest already has (leak)?
   List both columns; every native row needs a pin (a named reason: sandbox
   policy, credentials, perf, protected surface) or a migration entry.
2. `src/agent/`, `src/serve/`, `src/peers/`, `src/schedule/`, `src/tui/`,
   `src/research/`, `src/stats/`: which modules are one-LLM-call or
   one-JSON-store shaped (the advisor/thinking/alarm pattern)? Those are
   guest candidates.
3. Dead code: anything referenced only from `src/main.zig`'s comptime test
   block is not pinned by anything — delete or extract.

## Pass 2 — boundary leaks in the existing plugin surfaces

1. **Duplicated registries.** Any store owned by both a native handler and
   a guest (grep for the same `state/*.json` path in `src/cli.zig` and
   `tools/zig/`)? Their semantics WILL drift; the guest wins, the native
   copy dies.
2. **Web UI**: diff what `ui/app/features/*.js` use against what
   `pluginApi()` (`ui/app/core/plugins.js`) offers. Every gap is a reason a
   built-in view cannot migrate and a workaround some plugin has already
   hand-rolled. Check `plugin.json` still declares capabilities honestly.
3. **Providers**: grep `provider.kind ==` and `switch (provider.kind)`
   outside `src/llm/providers/` — the registry exists to abolish these.
   `src/serve/proxy.zig` is the historical accumulation point.
4. **Skills**: does the surface have discovery, disclosure, and an
   enable/disable, or is every byte still riding every prompt?
5. **Events**: can a guest or UI plugin emit onto the live bus yet, or is
   `src/serve/live.zig`'s `Topic` still a closed enum?

## How to run it

Two parallel read-only passes (subagents work well: one per pass above),
then merge into a ranked list — bug-class findings first, one-line
migrations next, design-blocked items last, and always end with the
"verified clean / stays core on purpose" list so the review is not misread
as "pluginize the sandbox." The permanent stays-core set: sandbox + policy,
`toolhost/builder.zig`, improve/evals/gate, credential handling, config as
policy source, the agent loop and session write path, the run/ask/steer
command surface.

## Findings

### 2026-08-16 (initial)

Full findings in docs/ROADMAP.md under "Everything-is-a-plugin audit
(2026-08-16)". Headline items: the webui plugin registry duplicated
native+guest with diverging fresh-checkout defaults (bug); six
route-to-guest migrations (`workflows` is one line; `schedule` has no
plugin shape at all); advisor and the thinking classifier as the purest
guest extractions; `pluginApi()` missing POST/live-bus/dialogs/workspace/
icons/storage; eleven `provider.kind ==` sites in the proxy; themes and
slash commands as data still shipped as code.
