# Agent prompt: when to build abstractions (and how to review them)

Your goal is to judge whether each abstraction earns its keep, and to name the ones that should be inlined away or introduced.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing **abstraction decisions** in **clanker**
(`/home/maci/Desktop/clanker`): a self-improving AI agent harness written in
Zig 0.16 that runs its tools as sandboxed WebAssembly modules via zwasm.

Your job is to decide, for each proposed or existing abstraction:

1. **Should it exist at all?** (YAGNI vs real duplication / boundary)
2. **Is it the right kind?** (stdlib vs project helper vs layer facade vs
   plugin/host-fn extension)
3. **Does it sit in the right layer?** (`llm` / `sandbox` / `agent` / `cli` /
   `tools` / `improve`)
4. **Does it pay for itself?** (call sites, testability, streaming-path cost,
   cognitive load)

This is complementary to:

| Prompt | Focus |
|---|---|
| `zig-idiomatic-review.md` | Language idioms, comptime, streaming-path no-alloc, `std.Io` |
| `zig-0.16-changelog-review.md` | Removed/deprecated API names per the 0.16 release notes |
| `zig-best-practices-review.md` | Layout, naming, builtin choice, zero-cost abstractions |
| `wasm-review.md` | Whether logic belongs in native `src/` or a sandboxed WASM tool |

Do **not** invent enterprise frameworks. Prefer **fewer, thinner, named**
abstractions that match the existing sandbox/registry/plugin boundaries and
stdlib.

## Read first

| Doc | Why |
|---|---|
| `AGENTS.md` | Layer table, protected surface, YAGNI, tool ABI |
| `docs/README.md` | Full architecture: agent loop, sandbox, plugins/transforms, tool catalog |
| Code under review | Actual call sites and duplication |

## Non-negotiable

- **No em dashes. No AI attribution.**
- **Zig Zen:** one obvious way; reduce what one must remember; memory is a
  resource; serve the users (a working agent that answers tasks).
- **YAGNI first.** Three similar lines are often better than a premature API.
- **Stdlib before inventing.** If `std.Io` / `std.mem` / `std.fmt` already
  covers it, do not wrap again.
- **No OOP theater.** Zig has no abstract base classes. Prefer:
  - plain functions + structs
  - `anytype` / comptime only when the shape is clear
  - stdlib interfaces (`std.Io` vtable) when swappable I/O is needed
  - the existing plugin/transform chain (`src/tools/registry.zig`,
    descriptor `transform` key) for extensibility, not a second mechanism
- **Streaming/loop-path abstractions must not allocate, hide unbounded
  growth, or force indirection on every token/iteration without need.**
- **One sandboxed-tool boundary.** Every tool is `ck_*` host functions + a
  `tools/manifests/*.tool.json` descriptor. Do not build a second, informal
  way for the harness to call out to "plugin-shaped" code.
- **`zig build && zig build test` green** if you change code.

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Verdict tables + `docs/reviews/ABSTRACTIONS_REVIEW.md`. No code. |
| **Review + fix P0/P1** | Also delete/merge dual paths and mis-layered helpers; `zig build test` green. |
| **Deep pass** | Full inventory of a named dir; score every public helper/facade. |

Default: **Review only** unless the user asks for patches.

---

## What counts as an "abstraction" here

Anything that **adds indirection or names a concept** above open code:

| Kind | Examples in clanker | Default stance |
|---|---|---|
| **Stdlib use** | `std.Io.Dir`, `ArrayList`, `StringArrayHashMapUnmanaged` | Prefer; do not reimplement |
| **Thin util** | `src/util/log.zig`, `src/util/dotenv.zig` | OK when 3+ call sites or one policy |
| **Subsystem facade** | `src/agent/loop.zig` (`Agent`), `src/tools/registry.zig` (`Registry`), `src/config.zig` (`Config`) | OK for imports / public surface |
| **Domain type** | `RunStats`, `ToolCall`, `MdStream`, `ProviderKind` | OK when it makes illegal states harder |
| **Callback / hook** | `Agent.on_token`, `Agent.on_tool_call`, `Agent.on_tool_result` | OK at a real streaming/status boundary (REPL and `run` both consume the same three hooks; that's the proof they earned their keep) |
| **Sandboxed extension point** | The WASM tool ABI (`ck_*` + `tools/manifests/*.tool.json`); the `transform` chain (`before`/`after`, `phase`+`order`) | **The one sanctioned instance**; no second mechanism |
| **Parallel mechanism** | A second tool-dispatch path, a second markdown renderer, a second session store | **Reject** |

---

## Decision tree: build, extend, or delete?

Run this on every candidate (new PR or existing helper).

```text
1. Is there already a stdlib or project API that does this?
   YES -> use/extend it. STOP. (Do not wrap for taste.)

2. Is this something a WASM tool could do instead (bounded, ck_*-shaped)?
   YES -> that's wasm-review.md territory, not this one. Note it and move on
   rather than designing a native abstraction around it.

3. How many real call sites need the same behavior today?
   1 -> inline or private fn in the owning file. STOP.
   2 -> private fn or shared only if the two sites are already coupled.
   3+ OR about to add a 3rd -> consider a thin shared helper.

4. Does it cross a trust or layer boundary?
   (provider response parsing, tool-output validation, session load/save,
   WASM guest-memory read in src/sandbox/host.zig)
   YES -> a named function/type at that boundary is good even with 1-2 sites.
   NO -> need stronger duplication evidence.

5. Would the abstraction force heap alloc, a new thread, or dynamic dispatch
   on the streaming/agent-loop path (once per token or per iteration)?
   YES -> redesign (comptime, fixed buffers, reuse the caller's writer, the
   way MdStream does) or reject.

6. Does it create a second way to do the same job?
   (a second tool-call path beside registry.zig; a second way to stream
   status besides on_token/on_tool_call/on_tool_result; a second session
   format beside src/agent/session.zig)
   YES -> merge or delete the weaker path. STOP.

7. Can a reader name the abstraction's single responsibility in one sentence
   that matches the file/type name?
   NO -> split or delete (confusing names are defects per AGENTS.md).

8. Still unsure?
   Prefer the smaller change. Document "extract when third call site lands."
```

### Quick scorecard (optional)

Score each candidate 0-2:

| Criterion | 0 | 1 | 2 |
|---|---|---|---|
| Call sites needing same rule | 1 | 2 | 3+ |
| Boundary / invariant protected | none | soft | fail-closed / illegal state |
| Stdlib gap | std covers it | thin sugar | true gap |
| Streaming/loop-path cost | worse | neutral | better or equal + clearer |
| One obvious way | creates dual path | neutral | removes dual path |

**Sum >= 6:** build or keep. **3-5:** maybe private helper only. **<= 2:** do not
build; delete or inline if an existing abstraction fails this score.

---

## When you SHOULD abstract

### A. Repeated policy with a name

Same "fail closed on missing/invalid provider field" check, same token-budget
guard, same "trim markdown emphasis off a scalar answer" unwrap, in multiple
places -> one function with a name that states the policy.

```text
// Good: named policy
fn compactMessages(messages: *std.ArrayList(types.Message), max_chars: usize) void

// Bad: copy-paste "drop oldest non-system message while over budget" in three call sites
```

### B. Layer or import boundary

- `Agent.on_token` / `on_tool_call` / `on_tool_result`: one hook shape, three
  real consumers (REPL, `clanker run`, `clanker serve`'s `/api/run` stream)
- `src/tools/registry.zig`: one place that knows how to discover, load, and
  dispatch a tool, so `cli.zig`/`loop.zig` never open-code that
- `src/agent/session.zig`: one session format, used by REPL `--session`,
  `run --session`, and `/api/run`'s `session` field
- `ck_llm` (`src/sandbox/host.zig`): the one way a WASM tool reaches the
  model, so no tool re-implements its own provider client

### C. Making illegal states unrepresentable

- `ProviderKind` enum instead of a bare string
- `log.Level` ordering instead of separate bool flags per level
- `RunStats` as a struct instead of five loose counters passed around

### D. Testability of a pure core

Pull pure logic (the markdown-to-ANSI state machine, message compaction) into
a small, tested unit: `MdStream` and `compactMessages` (both in `src/cli.zig`,
tested at the bottom of the file) are the shape to match. Keep I/O and
process orchestration outside the tested core.

### E. Stdlib-shaped extension

If you need "load and validate this JSON descriptor" ten times, extend the
existing loader in `registry.zig`, do not invent a second one. Match std
naming and ownership (`allocator`, caller frees; arena vs `gpa` per AGENTS.md).

### F. Comptime closed sets

Fixed maps known at compile time (level-to-prefix, provider-kind-to-string)
should be `comptime`/`switch`, not a runtime plugin registry built at `init`.

---

## When you should NOT abstract

### 1. Speculative generality ("we might need")

No generic `Registry(T)`, no plugin bus beyond the existing WASM tool +
transform-chain mechanism, unless a tracked need and multiple real backends
exist **today**.

### 2. One call site

Private function in the same file beats a new `src/util/foo.zig` used once.

### 3. Wrapping std for fashion

```zig
// Bad
pub fn ckReadFile(...) { return std.Io.Dir.cwd().readFileAlloc(...); }
```

Unless you add real policy (a fs-prefix check, a size cap, logging).

### 4. Second path for the same job

- A second tool-dispatch mechanism beside `registry.zig`
- A second streaming-status channel beside `on_token`/`on_tool_call`/
  `on_tool_result`
- A second session format or store beside `src/agent/session.zig`
- A second markdown/ANSI renderer beside `MdStream` (the unused `format`
  WASM tool is exactly this trap: don't let a "cleaner" second
  implementation grow beside it either; either wire the existing one in or
  remove it, don't add a third)

Delete or merge; do not "abstract over both."

### 5. Hiding streaming/loop-path cost

```zig
// Bad: looks clean, allocates on every SSE delta
fn styledDelta(a: Allocator, delta: []const u8) ![]const u8
```

Prefer a reused writer + small fixed lookahead state, the way `MdStream` does.

### 6. Crossing layers the wrong way

| Wrong | Right |
|---|---|
| `src/sandbox/` calls back into `src/agent/loop.zig` | `agent` calls `sandbox`, not the reverse |
| A WASM tool reaches outside its `fs_prefixes`/`network_allow` via a native "helper" | The descriptor is the complete authority; extend `ck_*`, don't route around it |
| `src/cli.zig` open-codes tool dispatch instead of calling `registry.zig` | Use the registry; that's what it's for |
| `src/gate/checks.zig` (verification) reaches into `src/improve/` (the thing it grades) | Gate stays independent of the engine it verifies |

### 7. Content as abstraction

Do not build an enum of every possible tool name or provider model. Names +
descriptors + config do that job; an enum rots every time a tool or model is
added.

### 8. Second sandbox / plugin API

clanker is **not** a multi-host plugin system. The extension surface is the
WASM tool ABI (`ck_*` + descriptor) and the transform chain built on top of
it (`docs/README.md` "Plugins", "Transform chains"). Review any proposed
"plugin API" against those same rules; no second mechanism, no bespoke
callback-registration system living outside the registry.

---

## Preferred abstraction shapes (Zig / clanker)

| Need | Shape | Avoid |
|---|---|---|
| Shared pure logic | `pub fn` + plain struct in owning module (`MdStream`, `compactMessages`) | Base class hierarchy |
| Optional dependency | Function pointer + module-level state, matching the existing `on_token`/`on_tool_call` shape | Global mutable hooks with undocumented lifetime |
| Swappable I/O | `std.Io` | Custom vtable for files |
| Batch parallelism | `std.Thread.spawn` scoped to one bounded batch (`executeCalls`) | Ad-hoc spawn per streamed token |
| Config | Struct fields loaded once (`config.Config`) | Virtual `getOption` |
| Tool boundary | `ck_*` host fn + descriptor | A second native "helper" that bypasses the sandbox |
| Errors | Explicit error sets / precise `catch` | Abstract `Result` monad soup |

### Naming the abstraction

- File/module name = what it owns (`session.zig`, `registry.zig`)
- Type name = domain noun (`RunStats`, not `Manager`)
- Function name = verb + object (`compactMessages`, `writeStreamEvent`)
- Flags = actual effect (`run_stdout_color`, not `interactive` if it only
  gates one specific thing)

If you cannot name it without "Manager", "Helper", "Util2", "Base", rethink.

---

## Layer map (put abstractions here)

| Layer | Good abstractions | Bad abstractions |
|---|---|---|
| `src/util/` | Logging, dotenv | Agent/provider policy |
| `src/llm/` | Provider adapters, SSE client | Tool dispatch, sandbox policy |
| `src/sandbox/` | `ck_*` host functions, zwasm wrapper, policy | Agent-loop orchestration |
| `src/agent/` | Agent loop, session store, system prompt, execution graphs | Raw socket/process I/O beyond what the loop needs |
| `src/tools/` | Registry (discovery/dispatch), WASM build pipeline (protected) | Agent orchestration logic |
| `src/cli.zig` | Command dispatch, REPL/HTTP glue, streaming-status rendering (`MdStream`, spinner) | A second tool-dispatch or session mechanism |
| `src/improve/` | Self-improvement engine (protected) | - |
| `src/gate/` | Deterministic verification | Anything that could grade its own change |
| `tools/zig/`, `tools/manifests/` | Sandboxed tool logic + descriptors | Trust-root logic (see `wasm-review.md`) |

Facades (`Agent`, `Registry`, `Config`): **group and expose**, do not grow
fat logic beyond their stated concern. Logic stays in the leaf function/file
that owns the tests.

---

## Review procedure

### 1. Inventory

List abstractions in scope (new in the PR **and** existing ones the PR touches):

| Name | Path | Kind | Call sites (approx) | Layer |
|---|---|---|---|---|
| ... | ... | util/facade/type/hook | N | ... |

### 2. Score each (decision tree + scorecard)

For each row: **keep / thin / move layer / merge / delete / do not add**.

### 3. Dual-path hunt

```text
rg -n 'fn.*[Tt]ool.*[Cc]all|executeCalls' src/agent src/cli.zig   # one tool-dispatch path?
rg -n 'on_token|on_tool_call|on_tool_result' src --type zig       # one status-hook shape, reused everywhere?
rg -n 'loadSession|saveSession' src --type zig                    # one session store?
rg -n 'MdStream|format\.zig' src tools/zig --type zig             # the unused `format` WASM tool vs MdStream: still two implementations of the same idea?
```

### 4. Streaming/loop-path check

Any abstraction called from `on_token`, the agent-loop body, or per-tool-call:

- [ ] No heap alloc per call
- [ ] No hidden I/O
- [ ] Cost is proportional to the call, not to prior history

### 5. Stdlib gap check

Could this be `std.Io` / `std.mem` / an existing util? If yes and the
wrapper adds nothing, delete the wrapper.

### 6. Deliverable (always)

Write or update **`docs/reviews/ABSTRACTIONS_REVIEW.md`**:

- Scope and date
- Table of findings (name, verdict, severity, action)
- Dual paths to eliminate
- Abstractions that should be added (only if score says so) with proposed
  home layer
- Explicit **do not build** list (rejected ideas)

Plus a short chat note: top findings and whether `zig build test` ran.

Severity:

| Sev | Meaning |
|---|---|
| **P0** | Wrong layer causing bugs; dual tool-dispatch/session/status path; streaming-path alloc hidden in a helper |
| **P1** | Premature framework; a second sandbox-adjacent mechanism; facade that grew real logic it shouldn't own |
| **P2** | Weak name; 1-call-site util file; extract candidate with 3+ sites not shared yet |
| **P3** | Doc/import hygiene |

### 7. If implementing

- One verdict theme per change set (e.g. "delete duplicate helper" or
  "extract third-call-site policy")
- Move tests with the logic
- No new abstraction without a failing test or a third call site (except
  clear boundary types)
- Update `AGENTS.md`'s layer description only if a new long-lived layer
  appears (rare)

---

## Worked examples (clanker-shaped)

### Good: one hook shape, three real consumers

```text
Agent.on_token / on_tool_call / on_tool_result are called by the REPL, by
`clanker run`, and by `/api/run`'s streaming handler. Three real, different
consumers of the same three-function shape is exactly the bar for "this
earned its keep."
```

### Good: stdlib, not project framework

```text
Before: hand-rolled JSON string building for /api/run responses.
After: std.json.Stringify onto a fixed/Allocating writer.
Why: one obvious JSON-building path; no project-specific serializer.
```

### Good: boundary type

```text
RunStats: cumulative token/cost counters as one struct, not five loose u64s
passed through Agent.run and back out to the REPL/CLI stats footer.
Why: illegal "some counters updated, others not" state becomes hard to reach.
```

### Bad: speculative plugin bus

```text
// A second "native plugin" registration system beside the WASM tool ABI,
// e.g. a Zig-level callback table for "in-process extensions."
// Why: the WASM tool ABI + transform chain already is the sanctioned
// extension point; a second one splits trust and policy in two places.
```

### Bad: wrapper with no policy

```zig
// pub fn loadTool(...) { return registry.load(...); }
// Why: indirection without a rule; call registry.load directly.
```

### Bad: abstracting content

```text
// enum KnownTool { Git, FetchWeb, SearchCode, ... }
// Why: tool names + descriptors already do this; the enum rots every time
// a tool is added or renamed, and duplicates what registry.zig already knows.
```

### Bad: two abstractions for one job

```text
// tools/zig/format.zig (markdown -> ANSI) exists but is never called; the
// REPL/CLI grew MdStream, a second, streaming-safe implementation of
// nearly the same rules, instead of either wiring the tool in or deleting
// it. Flag this explicitly: either delete format.zig (if MdStream fully
// supersedes it) or document why both exist (e.g. format.zig is kept for a
// different, non-streaming consumer). Don't let a third implementation
// appear before this is resolved.
```

---

## Relationship to Zig Zen

| Zen | Abstraction rule |
|---|---|
| Communicate intent precisely | Name = responsibility; wrong name -> defect |
| Edge cases matter | Boundary helpers must define empty/max/fail-closed (empty tool-call batch, zero-length delta, missing session) |
| Favor reading over writing | Fewer layers; jump-to-definition should land on logic fast |
| One obvious way | No dual paths; prefer std |
| Compile errors > runtime crashes | Types/enums over stringly APIs where cheap |
| Incremental improvements | Extract on third site; finish a migration fully rather than keeping both paths (the `format.zig`-vs-`MdStream` case above) |
| Avoid local maximums | Do not keep a raw syscall because a wrapper is "done" |
| Reduce what one must remember | Caps and policies in one place (`max_session_chars`, `max_per_turn_tokens`) |
| Memory is a resource | No alloc-hiding helpers on the streaming/loop path |
| Serve the users | Abstractions serve a working, answerable agent, not architecture cosplay |

---

## Success criteria

- [ ] Every touched/new abstraction has a verdict and score rationale
- [ ] Dual paths listed with a merge/delete plan
- [ ] No recommended framework without a current multi-backend need
- [ ] Streaming/loop-path helpers explicitly checked for alloc/I/O
- [ ] Layer placement matches AGENTS.md
- [ ] If code changed: `zig build && zig build test` green, minimal diff
- [ ] No em dashes / AI attribution

---

## Optional user addenda

- "Review only the diff / these files: ..."
- "Reject any new util file with fewer than 3 call sites."
- "Focus on deleting dual paths (tool dispatch, status hooks, session store)."
- "Propose extractions where >= 3 copy-pastes exist; do not implement."
- "Implement P0/P1 verdicts only."
- "Resolve the format.zig-vs-MdStream duplication as part of this pass."
