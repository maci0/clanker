# Agent prompt: when to build abstractions (and how to review them)

Your goal is to judge whether each abstraction earns its keep, and to name the ones that should be inlined away or introduced.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing **abstraction decisions** in **zdtd**
(`/home/maci/Desktop/7dtd/zdtd`): a clean-room Zig 0.16 dedicated server.

Your job is to decide, for each proposed or existing abstraction:

1. **Should it exist at all?** (YAGNI vs real duplication / boundary)
2. **Is it the right kind?** (stdlib vs project helper vs layer facade vs framework)
3. **Does it sit in the right layer?** (wire / ecs / world / server / assets / util)
4. **Does it pay for itself?** (call sites, testability, tick cost, cognitive load)

This is complementary to:

| Prompt | Focus |
|---|---|
| `zig-idiomatic-review.md` | Language idioms, comptime, hot-path no-alloc, `std.Io`, Zig Zen |
| `zig-0.16-changelog-review.md` | Removed/deprecated API names per the 0.16 release notes |
| `zig-best-practices-review.md` | Layout, naming, builtin choice, zero-cost abstractions |
| `ecs-soa-review.md` | State ownership (ECS vs world vs session), SoA layout, systems as sole mutators |
| `simd-review.md` | Dense-loop vectorization after SoA is correct |
| `hardcoded-data-review.md` | Stock data vs config hardcodes |

Do **not** invent enterprise frameworks. Prefer **fewer, thinner, named**
abstractions that match stock boundaries and stdlib.

## Read first

| Doc | Why |
|---|---|
| `AGENTS.md` | Layers table, facades, YAGNI, rule 24 stdlib, Zig Zen |
| `docs/ECS_SYSTEMS.md` | Sim shape (SoA, systems as functions) |
| `docs/ASSETS.md` | Load boundary (game-dir XML) |
| Code under review | Actual call sites and duplication |

## Non-negotiable

- **No em dashes. No AI attribution.**
- **Zig Zen:** one obvious way; reduce what one must remember; memory is a
  resource; serve the users (stock client + 20 TPS).
- **YAGNI first.** Three similar lines are often better than a premature API.
- **Stdlib before inventing.** If `std.Io` / `std.mem` / `std.fmt` / project
  `io_fs` / `parallel` already covers it, do not wrap again.
- **No OOP theater.** Zig has no abstract base classes. Prefer:
  - plain functions + structs
  - `anytype` / comptime only when the shape is clear
  - stdlib interfaces (`std.Io` vtable) when you need swappable I/O
  - thin facades (`ecs/root.zig`) for import hygiene, not inheritance trees
- **Hot path:** abstractions must not allocate, hide unbounded growth, or force
  virtual dispatch on every block without need.
- **Stock wire:** one stock package shape → one builder. Do not abstract "almost
  stock" into a second encoder.
- **`make check` green** if you change code.

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Verdict tables + `../reviews/ABSTRACTION_REVIEW.md`. No code. |
| **Review + fix P0/P1** | Also delete/merge dual paths and mis-layered helpers; `make check` green. |
| **Deep pass** | Full inventory of a named dir; score every public helper/facade. |

Default: **Review only** unless the user asks for patches.

---

## What counts as an "abstraction" here

Anything that **adds indirection or names a concept** above open code:

| Kind | Examples in zdtd | Default stance |
|---|---|---|
| **Stdlib use** | `std.Io.Dir`, `ArrayList`, `StaticStringMap` | Prefer; do not reimplement |
| **Thin util** | `util/io_fs.zig`, `util/parallel.zig`, `wire/binary.zig` | OK when 3+ call sites or one policy |
| **Layer facade** | `ecs/root.zig`, `wire/packages.zig`, `assets/root.zig` | OK for imports / public surface |
| **Domain type** | `PowerNode`, `RecipeDef`, `Chunk`, `PackageIds` | OK when it makes illegal states harder |
| **Callback / hook** | `id_by_name`, `ground_fn`, `place_fn` | OK at trust/load boundaries |
| **Strategy / plugin API** | Wasm plugin host (`plugin/`, ADR 0020), generic "System" trait objects | **Skeptical**; the Wasm host is the one sanctioned instance, no second mechanism |
| **Parallel mechanism** | Second FS stack, second package encoder, second id space | **Reject** |

---

## Decision tree: build, extend, or delete?

Run this on every candidate (new PR or existing helper).

```text
1. Is there already a stdlib or project API that does this?
   YES → use/extend it. STOP. (Do not wrap for taste.)

2. Is this stock game data or wire layout?
   YES → load/parse/build in assets/* or wire/*; do not abstract "content".
   STOP after putting it in the right layer.

3. How many real call sites need the same behavior today?
   1 → inline or private fn in the owning file. STOP.
   2 → private fn or shared only if the two sites are already coupled.
   3+ OR about to add a 3rd → consider a thin shared helper.

4. Does it cross a trust or layer boundary?
   (C2S validate, XML load, package encode, chunk persist)
   YES → named function/type at that boundary is good even with 1–2 sites.
   NO → need stronger duplication evidence.

5. Would the abstraction force heap alloc, vtable, or dynamic dispatch
   on the hot path?
   YES → redesign (comptime, inline data, fixed buffers) or reject.

6. Does it create a second way to do the same job?
   YES → merge or delete the weaker path. STOP.

7. Can a reader name the abstraction's single responsibility in one sentence
   that matches the file/module name?
   NO → split or delete (confusing names are defects per AGENTS).

8. Still unsure?
   Prefer the smaller change. Document "extract when third call site lands."
```

### Quick scorecard (optional)

Score each candidate 0–2:

| Criterion | 0 | 1 | 2 |
|---|---|---|---|
| Call sites needing same rule | 1 | 2 | 3+ |
| Boundary / invariant protected | none | soft | fail-closed / illegal state |
| Stdlib gap | std covers it | thin sugar | true gap |
| Hot-path cost | worse | neutral | better or equal + clearer |
| One obvious way | creates dual path | neutral | removes dual path |

**Sum ≥ 6:** build or keep. **3–5:** maybe private helper only. **≤ 2:** do not
build; delete or inline if existing abstraction fails this score.

---

## When you SHOULD abstract

### A. Repeated policy with a name

Same bounds check, same endian write, same "fail closed on missing id" in
multiple places → one function with a name that states the policy.

```text
// Good: named policy
fn rejectIfOutOfEditRange(...) bool

// Bad: copy-paste dx*dx+dy*dy+dz*dz > 96*96 in five handlers
```

### B. Layer or import boundary

- `wire/binary.Reader` for .NET LE layout (one endian story)
- `wire/packages.zig` facade so `game.zig` does not open-code field order
- `assets/*` loaders so tick code never sees XML
- `util/io_fs` so app code never sees `std.os.linux`

### C. Making illegal states unrepresentable

- Enums for join phase, TE type, authority mode
- `PackageIds` map instead of bare `u8` package ids
- Fixed caps (`max_streamed_chunks`) instead of silent realloc

### D. Testability of a pure core

Pull pure logic (path A*, noise, binary parse) into a file with unit tests at
the bottom. Keep I/O and Game orchestration outside.

### E. Stdlib-shaped extension

If you need "read whole file" ten times, extend `io_fs`, do not invent
`AwesomeFileManager`. Match std naming and ownership (`allocator`, caller frees).

### F. Comptime closed sets

Package name tables, bit layouts, small maps known at compile time →
`comptime` / `StaticStringMap`, not a runtime plugin registry.

---

## When you should NOT abstract

### 1. Speculative generality ("we might need")

No generic `Repository(T)`, `System` trait object bus, or DI container unless a
tracked milestone and multiple real backends exist **today**.

### 2. One call site

Private function in the same file beats `util/foo.zig` used once.

### 3. Wrapping std for fashion

```zig
// Bad
pub fn MyFile_readAll(...) { return io_fs.readFileAll(...); }
```

Unless you add real policy (path allowlist, size cap, metrics).

### 4. Second path for the same job

- Second chunk encoder
- Second id resolve (`assignids` pin vs `idByName` without a single entry point)
- Second FS stack beside `io_fs` (the old `linux_fs` is deleted; do not reintroduce one)
- Client mod inventing S2C the server should send

Delete or merge; do not "abstract over both."

### 5. Hiding hot-path cost

```zig
// Bad: looks clean, allocates every tick
fn interestedPeers(a: Allocator, ...) ![]Peer
```

Prefer caller scratch + count, or fixed cap arrays.

### 6. Crossing layers the wrong way

| Wrong | Right |
|---|---|
| `wire` mutates world blocks | `game`/`ecs` mutates; wire only encodes |
| `ecs` opens sockets | `litenet` / server |
| `assets` runs AI | `ecs/systems` |
| `game.zig` open-codes package fields | `packages.buildXxxBody` |
| Package builder reads XML | tables loaded at init, passed in |

### 7. Content as abstraction

Do not build a "BlockType enum of all blocks." Names + AssignIds + XML props.
Abstract **mechanics** (NodeKind, QuestKind collapsed for sim), not the catalog.

### 8. Second plugin / mod API

zdtd is **not** a mod host. The plugin surface is the Wasm host in `src/plugin/`
(`docs/PLUGIN_API.md`, ADR 0020); review it under the same rules. No second
plugin mechanism, no IModApi cosplay.

---

## Preferred abstraction shapes (Zig / zdtd)

| Need | Shape | Avoid |
|---|---|---|
| Shared pure logic | `pub fn` + plain struct in owning module | Base class hierarchy |
| Optional dependency | Function pointer + ctx, or `?` hook on World | Global mutable hooks |
| Swappable I/O | `std.Io` | Custom VTable for files |
| Batch parallelism | `util/parallel.forRanges` | Ad-hoc spawn per system |
| Config | Struct fields loaded once at init | Virtual `getOption` |
| Package body | `buildXxxBody(buf, …) ![]u8` | Builder class with internal heap |
| Systems | Free functions over `*World` SoA | Entity-component "framework" |
| Errors | Explicit error sets / precise catch | Abstract `Result` monad soup |

### Naming the abstraction

- File/module name = what it owns (`stock_chunk.zig`, `io_fs.zig`)
- Type name = domain noun (`PowerGrid`, not `Manager`)
- Function name = verb + object (`buildWeatherBody`, `idByName`)
- Flags = actual effect (`wire_chunks`, not `world_enabled` if it only streams)

If you cannot name it without "Manager", "Helper", "Util2", "Base", rethink.

---

## Layer map (put abstractions here)

| Layer | Good abstractions | Bad abstractions |
|---|---|---|
| `util/` | io_fs, parallel, clock | Game rules, package ids |
| `wire/` | binary Reader/Writer, stock_* builders, PackageIds | World mutation, XML |
| `assets/` | XML tables, tryLoad, paths + overrides | Tick systems |
| `ecs/` | components, systems fns, interest helpers | Sockets, raw FS |
| `world/` | store, tts, worldgen, chunk path | Package send |
| `server/` | join SM, orchestration, config | Open-coded wire fields |
| `litenet/` | framing, peers, UDP batch | Sim, XML |
| `plugin/` | Wasm runtime, api vtable, static test host | Imports of server/ecs/wire; native dynlib ABI |
| `apm/` | counters, sections | Game logic |

Facades (`root.zig`, `packages.zig`): **re-export and group**, do not grow fat
logic. Logic stays in the leaf file that owns the tests.

---

## Review procedure

### 1. Inventory

List abstractions in scope (new in the PR **and** existing ones the PR touches):

| Name | Path | Kind | Call sites (approx) | Layer |
|---|---|---|---|---|
| … | … | util/facade/type/hook | N | … |

### 2. Score each (decision tree + scorecard)

For each row: **keep / thin / move layer / merge / delete / do not add**.

### 3. Dual-path hunt

```text
rg -n 'linux_fs' src              # must be empty: second FS path was deleted, keep it gone
rg -n 'pub fn build' src/wire     # one builder per stock shape; flag near-duplicate bodies
rg -n 'idByName|assignids\.' src  # two id authorities?
```

### 4. Hot-path check

Any abstraction called from tick/interest/stream:

- [ ] No heap
- [ ] No hidden I/O
- [ ] Cost visible (or `apm` if material)

### 5. Stdlib gap check

Could this be `std.Io` / `std.mem` / existing util? If yes and the wrapper adds
nothing → delete wrapper.

### 6. Deliverable (always)

Write or update **`../reviews/ABSTRACTION_REVIEW.md`**:

- Scope and date
- Table of findings (name, verdict, severity, action)
- Dual paths to eliminate
- Abstractions that should be added (only if score says so) with proposed home layer
- Explicit **do not build** list (rejected ideas)

Plus a short chat note: top findings and whether `make check` ran.

Severity:

| Sev | Meaning |
|---|---|
| **P0** | Wrong layer causing bugs; dual wire encoder; hot-path alloc hidden in helper |
| **P1** | Premature framework; reintroduced dual FS path; facade god-object; abstraction blocks std migration |
| **P2** | Weak name; 1-call-site util file; extract candidate with 3+ sites not shared yet |
| **P3** | Doc/import hygiene |

### 7. If implementing

- One verdict theme per change set (e.g. "delete duplicate helper" or "extract
  third-call-site policy")
- Move tests with the logic
- No new abstraction without a failing test or a third call site (except clear
  boundary types)
- Update AGENTS layer table only if a new long-lived layer appears (rare)

---

## Worked examples (zdtd-shaped)

### Good: extract after third site

```text
// Before: edit range check in SetBlock, Explosion, TE open
// After: game.rejectIfBeyondEditRange(peer, x,y,z) used by all three
// Why: one policy, one constant, one log line
```

### Good: stdlib, not project framework

```text
// Before: linux open/read in every loader
// After: io_fs.readFileAll → std.Io.Dir.readFileAlloc
// Why: one obvious FS path; no OS-specific app code
```

### Good: boundary type

```text
// PackageIds: name → id from negotiation
// Why: illegal "hardcoded package id" becomes hard to express
```

### Bad: speculative system bus

```text
// pub const System = struct { vtable: *const VTable, ... }
// registered list run every tick
// Why: one call order in game.tick is clearer; no second backend
```

### Bad: wrapper with no policy

```text
// pub fn loadBlocks(...) { return maxdamage.tryLoad(...); }
// Why: indirection without a rule; call tryLoad directly
```

### Bad: abstracting content

```text
// enum Block { Dirt, Stone, Wood, ... hundreds }
// Why: stock names + AssignIds; enum rots every patch
```

### Bad: two abstractions for one job

```text
// a new fs helper with readFileAll public beside io_fs.readFileAll
// Why: violates one obvious way; the linux_fs dual path was deleted
// once, do not let a second FS story regrow
```

---

## Relationship to Zig Zen

| Zen | Abstraction rule |
|---|---|
| Communicate intent precisely | Name = responsibility; wrong name → defect |
| Edge cases matter | Boundary helpers must define empty/max/fail-closed |
| Favor reading over writing | Fewer layers; jump-to-definition should land on logic fast |
| One obvious way | No dual paths; prefer std |
| Compile errors > runtime crashes | Types/enums over stringly APIs where cheap |
| Incremental improvements | Extract on third site; finish a migration fully rather than keeping both paths |
| Avoid local maximums | Do not keep raw syscalls because a wrapper is "done" |
| Reduce what one must remember | Caps and policies in one place |
| Memory is a resource | No alloc-hiding helpers on hot path |
| Serve the users | Abstractions serve playability and TPS, not architecture cosplay |

---

## Success criteria

- [ ] Every touched/new abstraction has a verdict and score rationale
- [ ] Dual paths listed with a merge/delete plan
- [ ] No recommended framework without current multi-backend need
- [ ] Hot-path helpers explicitly checked for alloc/I/O
- [ ] Layer placement matches AGENTS table
- [ ] If code changed: `make check` green, minimal diff
- [ ] No em dashes / AI attribution

---

## Optional user addenda

- "Review only the diff / these files: …"
- "Reject any new util file with fewer than 3 call sites."
- "Focus on deleting dual paths (FS, encode, id resolve)."
- "Propose extractions where ≥3 copy-pastes exist; do not implement."
- "Implement P0/P1 verdicts only."
- "Compare PR to decision tree; block merge if score ≤ 2 for new public API."
