# Investigation — Plugin-philosophy alignment gap analysis

## TL;DR

- **Question:** Does clanker align with the DeepSeek Harness everything-is-a-plugin philosophy
- **Finding:** Resolved on 2026-08-20. Gaps fixed and verified (zig build + test green): system prompt recorded in sessions, TUI slash-command plugins and CLI plugins shipped per PRD 0012, minimal runtime-mode preset added, Cordis paper digested. Open items stay documented in the record: provider plugin registration, sandbox backend, storage backend (RFC 0019) incl. state_dir, loop registry, schedule triggers.
- **Resolution:** Resolved on 2026-08-20. Gaps fixed and verified (zig build + test green): system prompt recorded in sessions, TUI slash-command plugins and CLI plugins shipped per PRD 0012, minimal runtime-mode preset added, Cordis paper digested. Open items stay documented in the record: provider plugin registration, sandbox backend, storage backend (RFC 0019) incl. state_dir, loop registry, schedule triggers.

## Status

Resolved on 2026-08-20. Gaps fixed and verified (zig build + test green): system prompt recorded in sessions, TUI slash-command plugins and CLI plugins shipped per PRD 0012, minimal runtime-mode preset added, Cordis paper digested. Open items stay documented in the record: provider plugin registration, sandbox backend, storage backend (RFC 0019) incl. state_dir, loop registry, schedule triggers.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Trigger and scope

The operator asked whether clanker follows the same philosophy as DeepSeek Harness
(DSH): *everything is a plugin* (models, tools, skills, sessions, sandboxes, storage,
loops, scheduling, and the UI are swappable/recomposable capabilities), *every run is
traceable* (an append-only log of everything the model sees), and *multiple runtime
modes*. The ask: check clanker's PRDs, ADRs, RFCs and docs; review the code; find the
gaps; record them; then fix them.

Scope: the whole harness. Evidence: docs/README.md, docs/manifest.md, ADRs 0001-0032,
PRDs 0001-0043, RFCs 0001-0021, docs/ROADMAP.md (the "Everything-is-a-plugin audit"
2026-08-16), docs/research/deepseek-harness-plugins.md, docs/digests/cordis-paper.md
(new), and the source tree under src/, tools/, ui/. No files were modified during the
review phase.

## Evidence

### Axis 1 — Models / providers

- README "LLM providers": *"A provider is a native vtable, not a WASM module"*; adding
  one is *"three edits, in fixed places: a new src/llm/providers/<name>.zig, a row in
  registry, and a ProviderKind tag in src/config.zig"* (ADR 0004).
- Confirmed in code: src/llm/registry.zig:37-44 lists 6 providers in a comptime array;
  forKind (48-66) indexes by config.ProviderKind (config.zig:42-61). A gate
  (src/gate/checks.zig:273,292) fails a build that switches on provider.kind.
- ADR 0004's own Consequences: *"a real limit on 'fully pluggable providers,' accepted
  here"* — the pure codec could move to a WASM plugin later; auth and transport cannot.

### Axis 2 — Tools

- Flagship plugin surface: every tool is a wasm32-freestanding module + a *.tool.json
  manifest declaring its whole sandbox policy (docs/manifest.md; PRD 0010 SDK;
  ADR 0007 declarative/unsigned; PRD 0022 out-of-tree tools_dir list). 121 manifests
  ship; toggling via /plugins -> state/plugins.json; transforms are plugins too.
- Gaps vs DSH: no kernel-managed mounting/dependencies (no tool->tool activation
  semantics — a tool calling a disabled tool fails at call time); no distribution
  (ADR 0007 explicit non-goal); MCP-sourced tools are a native bridge (ADR 0025).

### Axis 3 — Skills

- Skills are markdown data files in skills/ (agent.skills_dir) with frontmatter and
  progressive disclosure (ROADMAP audit: done). Swappable via config; the assembly
  into the prompt stays native in system_prompt.zig (byte-stable ordering for prompt
  cache). No packaging/versioning — consistent with ADR 0007.

### Axis 4 — Sessions

- Hardcoded JSON transcripts: src/agent/session.zig, store_dir const at line 27
  ("state/sessions"); saveSession/loadSession/fork/branch/search; all callers pass
  std.Io.Dir.cwd(). Sessions ignore cfg.agent.state_dir.
- Sessions record roles user/assistant/tool only — **system prompts are not stored**
  (verified: state/sessions/*.json contain no system role). ADR 0015 planned an
  llm-io journal ("System prompts are not stored in full every turn (hash only)"),
  Status "Not yet implemented". The llm-io journal and muninn_url do not exist.

### Axis 5 — Sandboxes

- One hardcoded backend: src/sandbox/runtime.zig (zwasm); every ck_* host function
  takes *zwasm.Caller; no sandbox-kind enum, no config key. Kernels (ADR 0010) are an
  opt-in class with a WASM sandbox where the interpreter exists and an unsandboxed
  fallback. ROADMAP audit lists the sandbox and its policy under "must stay core".

### Axis 6 — Storage

- ~44 hardcoded relative state/ paths against cwd (README "What is private and what is
  shared"). cfg.agent.state_dir is honored by some stores (chatrooms, token stats,
  commit lock, doctor) but **not by others**: session.zig:27, schedule/store.zig:21-24,
  agent/workspace.zig:21, cli.zig:3635+14798 (goals, knowledge), improve staging
  (cli.zig:6120-6128), improve history (improve/engine.zig:458). RFC 0019 (shared
  state store) is still Discussion.

### Axis 7 — Loops (goal / autoresearch / improve)

- Hardcoded native subsystems: goal loop (src/agent/goal_loop.zig), improve
  (src/improve/), autoresearch (src/autoresearch/, ADR 0003 — the *harness command* is
  user-supplied, the loop mechanics are native), loop-hygiene guard (ADR 0028 native).
  Presets filter the tool catalog but cannot change how a loop runs. No loop-type
  registry; a new loop = new source file + command dispatch edit + help edit.

### Axis 8 — Scheduling

- Hardcoded cron store: src/schedule/store.zig:21-24 (state paths as pub consts),
  runner.zig fires once, never backfills; ADR 0008: cron-driven, no daemon; ADR 0009
  fixed UTC offsets. The web Schedule view is a web UI plugin. No trigger-type
  extension point.

### Axis 9 — UI

- Web UI: the shell is embedded into the binary (ui/webui.zig @embedFile;
  src/serve/webui_assets.zig Kind lists; adding a first-party view is edits in three
  lists + rebuild); addons ARE plugins (ui/plugins/<name>/, PRD 0012 Shipped) with a
  bounded pluginApi and CSP-only trust.
- TUI: the REPL slash-command registry is a hardcoded comptime array
  (src/tui/repl.zig command_registry, CommandSpec) — **TUI plugins: Draft** (PRD 0012).
- CLI: the Command enum (src/cli.zig:121-195) is a closed compile-time set —
  **CLI plugins: Draft** (PRD 0012 Tier 1 manifest->tool, Tier 2 clanker-<name> on PATH).

### Axis 10 — Traceability

- Fragmented across ~7 stores: sessions (visible chat JSON), runs (execution graphs,
  src/agent/graph.zig -> state/runs/), reasoning (state/reasoning.jsonl, append-only,
  loop.zig:1326), token stats (state/token_stats.jsonl), spills (state/spills/),
  logs (state/logs/). No single append-only event stream.
- Missing vs DSH "everything the model sees": **system prompts not recorded**
  (confirmed), internal ck_llm/improve/arena/compare calls not in the transcript,
  context injections (learnings, todos, TTSR, hooks additionalContext) not recorded
  as a coherent record, no trajectory view grouped by source, no session replay
  (eval --seed replays deterministically, runs are not replayed).
- Resume/fork/search exist on transcript files: REPL --session/--continue, fork via
  session.forkSession + POST /api/sessions/<id>/fork, session search (guest + CLI),
  graph timeline (clanker graph).

### Runtime modes

- No mode concept. Partial analogs: presets (PRD 0033 Shipped — research/full bundles
  filtering the loaded registry; maps to DSH Minimal) and run_plan ("Code Mode v1",
  orchestration only). DSH's Creator mode was explicitly rejected in the ROADMAP audit
  (no live plugin tree; tools are AOT-compiled WASM).

### Cross-cutting

- The ROADMAP "Everything-is-a-plugin audit (2026-08-16)" is clanker's own ongoing
  worklist: read-side surfaces (API routes, record logic, catalog data) have been
  pushed into guests; it names what stays native on purpose (sandbox+policy,
  toolhost/builder, improve/evals/gate, credentials, config, agent loop + session
  write path, kernel/DAP hosts, mesh sockets, run/ask/steer surface, recorder write
  paths). Unfinished items: /api/files native duplicate, chatrooms.fanOut native HTTP,
  doctor.zig native overlap.
- The Cordis paper (digested in docs/digests/cordis-paper.md) supplies the formal
  vocabulary (revertible effects = temporal composability; reactive coeffects = spatial
  composability; declarative loader with incremental reconciliation; HMR) and names
  self-evolving harnesses as its target — clanker's improve-self loop is the concrete
  instance, and its plugin layer (tools/skills/prompts/chains/presets/web plugins) is
  the surface where HMR-style swap is already loadable.

## Hypotheses and tests

1. *Hypothesis: sessions lose what the model actually saw (system prompt + context).*
   Tested: parsed state/sessions/*.json — roles present are tool/assistant/user only;
   the system prompt is built per request in src/agent/loop.zig:706 and never persisted
   (grep for saveSession shows the saved messages list is the chat transcript).
2. *Hypothesis: TUI/CLI have no plugin seam.* Tested: command_registry is a comptime
   array (repl.zig:1262-1288); Command is a closed enum (cli.zig:121-195); no
   directory scan or PATH lookup feeds either (grep across src/tui, src/cli.zig).
3. *Hypothesis: state_dir is inconsistently honored.* Tested: config.zig:419 defines
   agent.state_dir; chatrooms/token-stats honor it, session.zig:27 and
   schedule/store.zig:21-24 hardcode state paths (const literals).
4. *Hypothesis: providers are not config-swappable.* Tested: registry.zig comptime
   array + ProviderKind enum + build gate; three fixed source edits per new provider.

## Finding

clanker is **partially aligned** with DSH's philosophy, and the misalignment is mostly
*deliberate and documented* rather than accidental:

- **Plugin-shaped today:** tools (WASM + declarative manifest, out-of-tree via
  tools_dir), transforms, web UI addons, presets, skills, hooks, and read-side API
  surfaces (the ROADMAP audit's route-to-guest migrations). These match DSH's
  "capabilities as plugins" for the tool/UI axes.
- **Deliberate deviations (accepted, ADR-documented):** providers as a native vtable
  (ADR 0004 — keys and per-token transport stay native; codec-to-WASM deferred);
  sandbox single zwasm backend (ROADMAP audit "must stay core"); scheduler cron-driven
  with no daemon (ADR 0008); no plugin distribution/signing (ADR 0007); DSH Creator
  mode rejected (ROADMAP audit); REPL command_registry kept native (ROADMAP audit,
  later contradicted by PRD 0012 Draft).
- **Real fixable gaps found:**
  1. **Traceability:** the system prompt (and the context built from it) is not
     recorded anywhere; ADR 0015's llm-io journal is unimplemented. DSH's headline
     guarantee ("everything the model sees is recorded") is unmet.
  2. **UI as plugin:** PRD 0012's TUI slash-command plugins and CLI subcommand plugins
     are still Draft — the TUI and CLI shells are compile-time closed, the only two
     surfaces with no plugin seam.
  3. **Storage consistency:** agent.state_dir is honored inconsistently; several
     stores hardcode "state".
  4. **Runtime modes:** no named modes; only presets (research/full) and run_plan.
     DSH's Minimal mode has a direct equivalent available (a preset).
- **Needs its own decision (not fixed here):** storage backend (RFC 0019), sandbox
  plugin, loop-type registry, schedule trigger extension, provider plugin registration.

## Resolution or handoff

Fixed in this record:

1. Sessions now record the system prompt snapshot (system_prompt on the stored
   session, saved from the agent's built prompt; rendered by session export; absent on
   old sessions and loaded with ignore_unknown_fields). Closes the traceability gap for
   the system prompt; ADR 0015's full llm-io journal stays future work.
2. TUI slash-command plugins shipped per PRD 0012 Goal 2 (agent.tui_plugins_dir,
   enabled-list state/tui_plugins.json, appended CommandSpecs, built-in collision
   refusal, /tui-plugins list/toggle command). PRD 0012 status -> Shipped for TUI.
3. CLI plugins shipped per PRD 0012 Goal 3 (Tier 1 agent.cli_plugins_dir manifest ->
   tool dispatch with {"args":[...]}, Tier 2 clanker-<name> on PATH and
   ~/.clanker/plugins/; built-in Command never shadowed). PRD 0012 status -> Shipped
   for CLI.
4. A minimal runtime-mode preset (presets/minimal.toml) ships DSH Minimal-mode shape
   (shell + file-edit tools only).
5. state_dir consistency: stays open — the host-side session store still writes to cwd/state/sessions (store_dir const), and the sessions/search/export guests hardcode the same path, so a full fix needs both halves plus exposing state_dir via ck_harness_config. Tracked with the storage backend item (RFC 0019).

Docs updated: PRD 0012, CHANGELOG.md, docs/README.md, docs/configuration.md,
docs/ROADMAP.md, this investigation. Cordis paper digested at
docs/digests/cordis-paper.md.

Open (not fixed, recorded for the operator): provider-plugin registration (ADR 0004
limit), sandbox backend selection, storage backend (RFC 0019), loop-type registry,
schedule trigger extension, /api/files and chatrooms.fanOut guest migrations from the
ROADMAP audit.

## References

- docs/README.md (Architecture, Plugins, Tool catalog, Scheduled runs)
- docs/manifest.md, docs/adrs/0004, 0007, 0008, 0010, 0015, docs/prds/0010, 0012, 0022, 0033
- docs/ROADMAP.md "Everything-is-a-plugin audit (2026-08-16)"
- docs/research/deepseek-harness-plugins.md
- docs/digests/cordis-paper.md (new)
- src/agent/session.zig, src/tui/repl.zig, src/cli.zig, src/llm/registry.zig,
  src/sandbox/runtime.zig, src/schedule/store.zig, src/config.zig