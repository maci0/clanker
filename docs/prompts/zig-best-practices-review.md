# Agent prompt: Zig language best-practices review (zdtd / Zig 0.16)

Your goal is to find code that fights Zig language best practice: folder
structure and layering, filenames, naming and capitalization, comptime
discipline, `@builtin` selection, and zero-cost abstraction habits.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing and optionally fixing **Zig code** in **zdtd**
(`/home/maci/Desktop/7dtd/zdtd`): a clean-room Zig 0.16 dedicated server for
the stock 7DTD client wire.

This review is about **language shape**: how the tree is organized, what
things are named, and which language features are used and how. It is **not**
the general idiom review (`zig-idiomatic-review.md`, allocators/errors/tick
memory), **not** the 0.16 changelog conformance review
(`zig-0.16-changelog-review.md`, removed/deprecated API names), **not** the
abstraction lifecycle review (`abstractions-review.md`, when helpers or layers
should be built or deleted), **not** the ECS/SoA review (`ecs-soa-review.md`,
state ownership and SoA layout), **not** the hardcoded-data audit
(`hardcoded-data-review.md`, stock XML/AssignIds vs zdtd config vs OK
constants), and **not** the SIMD pass (`simd-review.md`).
Skip findings that belong to those prompts; cite and move on.

## Ground truth

| Source | Use |
|---|---|
| `AGENTS.md` (Zig style: Naming, Comptime, Layout, Zig Zen) | Canonical house rules: the naming table and layout table are normative |
| [Zig langref 0.16](https://ziglang.org/documentation/0.16.0/) | Builtin semantics and Zen |
| [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html) | Language changes that reshaped best practice (`@Type` -> `@Int`/`@Enum`/`@Struct`/`@Union`/`@Pointer`/`@Fn`/`@Tuple`/`@EnumLiteral`, `@intFromFloat` deprecated, small-int float coercion) |
| `docs/INDEX.md` | Where each concern lives; which review prompt owns which finding |

## Read first

`AGENTS.md`, `docs/INDEX.md`, the touched files, and (for builtin semantics
questions) the langref sections for the specific builtins.

## Non-negotiable constraints

- **Zig 0.16+** only. Best practice is 0.16-shaped, not blog-Zig-shaped.
- **No em dashes. No AI attribution** in commits, docs, comments, or PRs.
- **Keep `make check` / `zig build test` green.**
- **YAGNI + minimal diffs.** A rename is a rename; do not refactor
  surrounding code while fixing a name.
- **Do not change wire or sim semantics.**
- **Do not move files across package boundaries** without the user asking:
  structure findings are reported, structural moves are a separate
  decision. Same for file renames that touch imports.
- **Zero-cost is a tie-break, not a mandate.** The 20 TPS budget and stock
  fidelity beat purity theatre (Zig Zen: "together we serve the users").

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Findings + `docs/ZIG_PRACTICES_REVIEW.md`. No code edits. |
| **Fix P0/P1** | Review + apply high-severity fixes (renames, builtin swaps); re-run tests. |
| **Focus pass** | One checklist section (structure, naming, comptime, builtins, zero-cost) on named paths. |

Default if unspecified: **review only** on the paths the user named; if none,
the whole `src/` tree.

## Checklist (work through every section)

### A. Folder structure and layering

Canonical layout (AGENTS.md; verify drift, do not re-invent):

```text
src/main.zig        CLI, DebugAllocator, construct Game, run loop
src/protocol.zig    wire constants (challenge, tick rate)
src/server/*        join SM, tick orchestration, interest, send path, admin/GSI/config
src/ecs/*           SoA world, systems, inventory, quests, interest
src/world/*         chunks, TTS, prefabs, sleepers, containers, DTM, biomes
src/wire/*          stock package bodies (stock_*), binary LE, frames
src/litenet/*       LiteNet framing, peers, UDP
src/assets/*        blocks/items/recipes/loot/quests/entities XML tables
src/apm/*           counters, section timers, dumps
src/util/*          shared helpers (io_fs, clock, tcp_listen, parallel, sim)
worlds/             local save overlays (not source)
assets/fixtures/    offline XML for tests only
```

(`src/plugin/*`, `src/fuzz.zig`, and `src/version.zig` also exist; the
AGENTS.md layout table omits them. Treat them as in scope for placement
checks, not as drift.)

Checklist:

- [ ] Concern sits in its owning package: body layout in `wire/stock_*`,
      sim rules in `ecs`, world data in `world`, metrics in `apm`, shared
      helpers in `util`, process orchestration in `server`.
- [ ] No `world` -> `wire` imports (TE domain types live in `world`; wire
      re-exports). No import cycles; facades break cycles.
- [ ] Facades: `*/root.zig` per package plus `wire/packages.zig` for stock
      body modules. Leaf files stay importable; do not route everything
      through the facade.
- [ ] No god-files: a file that grew past one concern (`game.zig` doing
      package writes, `packages.zig` holding sim rules) is a split candidate
      (report; do not split without asking).
- [ ] One stock package shape has exactly one builder, in exactly one file.
- [ ] `main.zig` stays thin: no business logic, no package bodies.

### B. Filenames

- [ ] `snake_case.zig` everywhere under `src/` (and `worlds/`, `docs/` for
      any code-adjacent files). No `CamelCase.zig`, no `kebab-case.zig`, no
      spaces.
- [ ] Wire package bodies are `stock_*.zig` (stock_entity, stock_inv,
      stock_chunk, stock_quest, ...). A body for a new stock package follows
      the same prefix.
- [ ] Facades are exactly `root.zig`. Test harnesses live in
      `server/scenarios.zig`, not scattered `*_test.zig` files.
- [ ] Filename matches the primary decl's purpose: `Game` lives in
      `game.zig`, `World` in `world.zig` (or the file states otherwise in the
      `//!` header).
- [ ] Fixtures are under `assets/fixtures/`, never next to source.

### C. Naming and capitalization

House table (AGENTS.md, normative):

| Kind | Style | Example |
|---|---|---|
| Functions / methods | `camelCase` | `buildPlayerIdBody`, `setBlockWorld` |
| Variables / fields / params | `snake_case` | `entity_id`, `world_dir`, `view_radius` |
| Types | `PascalCase` | `Game`, `World`, `PackageName` |
| Files | `snake_case.zig` | `stock_quest.zig` |
| Constants | `snake_case` module `const` | `max_streamed_chunks`, `pending_cap` |
| Stock type / package names | Match TFP strings exactly | `NetPackagePlayerId`, `PackageName` cases |

Extra rules:

- [ ] Functions are verb+object; no ambiguous `handle`/`process` without the
      package name in context.
- [ ] Flags are named for what they do (`stream_chunks` not `world_enabled`
      when it only throttles streaming). Confusing names are defects.
- [ ] No magic numbers: wire field sizes, caps, bit masks, RE version pins
      are named module `const` with a one-line RE cite where non-obvious.
- [ ] No hungarian prefixes, no `p`/`p_` for pointers, no `m_` for members.
- [ ] Acronyms read as words where std does (`IpAddress`, `Http`, `Udp`
      only when matching a stock string).
- [ ] `pub` only for intended API. Helpers stay file-private by default.
      Every `pub` should have a reason (`///` ownership or a call site
      outside the file).
- [ ] Booleans avoid negated names (`is_not_spawned` is a defect; name the
      positive and flip at the call site when needed).

### D. Comptime discipline

**Use comptime for:**

| Use | Good | Bad |
|---|---|---|
| Closed sets | Package name -> handler tables, bit-field layouts, fixed wire sizes | Comptime that rebuilds half the game |
| Tables from data | `std.StaticStringMap(...).initComptime`, comptime hash of stock **names** | Comptime re-parse of `blocks.xml` every build |
| Layout invariants | `comptime assert` on struct size == RE layout | Silent `@sizeOf` assumptions without a test |
| Small parsers / formatters | Fixed header sizes, `comptime` string hashing | Comptime file I/O of full catalogs |
| Generics | `fn append(comptime T: type, ...)`, documented `anytype` | `anytype` soup with no stated duck type |
| Unrolling tiny loops | `@memcpy`, `inline for` over 4-16 fixed fields | `inline for` over 10k items |

**Rules of thumb:**

- [ ] If a value is known at compile time and used on the hot path, consider
      comptime. If it runs once at init, runtime is fine (XML, map, TTS).
- [ ] `inline` = tiny hot helpers only (2-10 lines). Never `inline` a large
      package builder or an AI system.
- [ ] Prefer `@Int`/`@Enum`/`@Struct`/`@Union`/`@Pointer`/`@Fn`/`@Tuple`/
      `@EnumLiteral` over `std.meta.*` reification helpers (0.16: `@Type` is
      gone; `std.meta.Int` etc. are deprecated).
- [ ] 0.16 lazy field analysis: using a type as a namespace no longer
      resolves its fields, so imports are cheap. Do not micro-split files to
      "avoid pulling in" a type; split for cycle control and cohesion.
- [ ] `comptime` that poisons error messages or blows up compile time for
      little runtime gain is a defect (report as P2).
- [ ] Policy belongs in data/config, not comptime: a comptime table that
      hand-copies what `biomes.xml` / AssignIds provide is both a practice
      and a hardcode finding (cite `docs/ASSETS.md`; the hardcode verdict
      itself belongs to `hardcoded-data-review.md`).

### E. `@builtin` selection

Prefer the builtin that says the intent and lowers to the obvious machine
code. Grounded in the 0.16 builtin set (langref). For each hit, name the
builtin and why it wins; do not "fix" code that is already canonical.
For removed/deprecated-name verdicts (`@intFromFloat`, `std.meta.*`,
`@cImport`), `zig-0.16-changelog-review.md` is the authority; cite it
rather than re-litigating the 0.16 facts here.

| Prefer | Over | Why |
|---|---|---|
| `@memcpy` / `@memmove` / `@memset` | Manual byte loops | Vectorizes; `memmove` handles overlap; one obvious way |
| `@bitCast` | `@ptrCast` when sizes match | Reinterprets the value, not the pointer: no alignment/aliasing hazard |
| `@intCast` after a bounds check | `@truncate` | Safety-checked; `@truncate` silently drops bits (justify every use) |
| `@min` / `@max` | Hand ternary / branches | Lower to cmov; intent is one word |
| `@abs` | Branchy abs / `std.math.abs` | Same as std, no import; cmov/bit trick |
| `@clz` / `@ctz` / `@popCount` | Hand-rolled bit loops | Hardware instructions |
| `@divTrunc` / `@divFloor` / `@divExact` / `@mod` / `@rem` | `/` and `%` without intent | Explicit rounding semantics; `@divExact` asserts |
| `@intFromEnum` / `@enumFromInt` | Casts on enums, `std.meta.intToEnum` | Canonical; exhaustive-aware; 0.16 builtin |
| `@intFromBool` | Ternary `1 : 0` | Direct `u1` |
| `@field` / `@hasField` / `@hasDecl` | `@typeInfo` when a narrow check suffices | Faster compile, direct intent |
| `@shuffle` / `@select` / `@reduce` / `@splat` | Scalar loops over vectors | SIMD lanes stay in registers |
| `@branchHint(.cold)` | Nothing | Marks cold error paths (see `errnoBug` in std) |
| `@compileError` / `@compileLog` | Runtime `unreachable` for closed sets | Fail at compile time; debug the comptime |
| `@setEvalBranchQuota` / `@inComptime` | Silent comptime hangs | Diagnose comptime loops deliberately |
| `@trunc` / `@floor` / `@ceil` / `@round` int result | `@intFromFloat` (deprecated 0.16) | One builtin, same conversion and same NaN/out-of-range trap |
| `@floatFromInt` | Implicit widening past precision | Required for u64 -> f64 (53-bit significand); small ints coerce freely now |

**Negative guidance:**

- [ ] `@ptrCast` is a smell: every use needs a comment (what invariant makes
      it safe) or a `@bitCast`/typed union instead.
- [ ] `@truncate` is a smell: every use needs a named const or a comment
      explaining the lossy intent.
- [ ] `@setRuntimeSafety(.off)` only in a measured hot loop with documented
      invariants; never on wire decode or untrusted input.
- [ ] `@cImport` is deprecated (0.16, moves to the build system); nothing in
      zdtd should introduce it.
- [ ] No `std.crypto.random` on the sim path for loot/AI (seeded PRNG is the
      rule; that is a sim correctness rule too).
- [ ] `@embedFile` only for small comptime assets. Hand-copied TFP content
      is forbidden (clean-room), but AGENTS rule 13 sanctions dump pins and
      fixtures that comptime-generate tables from install data (e.g.
      `src/assets/assignids_v314.embed.txt`); see `docs/ASSETS.md` and
      `hardcoded-data-review.md`.

### F. Zero-cost abstractions

Zig's philosophy (langref "Zig Zen", "Why Zig"): abstractions are free when
the compiler resolves them, and the language hides nothing (no hidden
control flow, no hidden allocations, no hidden copies). In zdtd practice:

- [ ] **Comptime polymorphism over runtime indirection for closed sets.**
      If the set of cases is known at compile time (package handlers,
      entity classes, TE types), use a comptime map or exhaustive `switch`,
      not a function-pointer table built at runtime.
- [ ] `StaticStringMap.initComptime` over a runtime `HashMap` built in
      `init` for fixed name tables.
- [ ] **Value semantics where the optimizer handles it**: copy small
      fixed-size structs instead of pointer-chasing; SoA columns over
      per-item heap. The optimizer removes the copy.
- [ ] **Zero-cost does not mean always-comptime.** A table built once at
      init is fine and often cheaper than re-evaluating comptime; compile
      time is a cost too. Balance and say why when it matters.
- [ ] Do not hand-roll what the optimizer does: `@min`/`@max`/`@memcpy`
      lower better than your branch/loop guess.
- [ ] Do not replace the sanctioned runtime interface: `std.Io` exists and
      is the house interface (AGENTS rule 24). A hand-rolled vtable "to save
      one call" is a local maximum; report it to `abstractions-review.md`
      territory.
- [ ] `inline` / `@call(.always_inline)` only when measurement (apm dumps)
      shows it matters, or the helper is trivially small. Do not pre-optimize
      cold paths.
- [ ] Zero-cost findings are **P2/P3 unless they sit on the 20 TPS or
      per-packet path**; on the hot path the 0.16 rule from
      `zig-idiomatic-review.md` section 3a applies (no heap, no growth).

### G. API surface and documentation

- [ ] File-level `//!` states purpose and non-goals; public APIs carry `///`
      with ownership (who frees, whose buffer, returned-slice lifetime).
- [ ] No narrating comments on obvious code; RE/layout cites on wire fields
      are welcome.
- [ ] Named caps and named constants instead of inline magic numbers on
      wire/tick paths.
- [ ] One obvious way: no second encoder for a stock package shape, no
      parallel id spaces, no second FS helper.

## Search recipes (run early)

```bash
# Structure
find src -name '*.zig' | grep -vE '/[a-z0-9_]+\.zig$'           # non-snake filenames (should be empty)
rg -n '@import' src/world -t zig | grep -i wire                  # world -> wire (should be empty; forbidden)
rg -c 'pub fn ' src/server/game.zig                              # god-file smoke (methods are indented; ^-anchored misses them)
ls src/*/root.zig 2>/dev/null                                    # facade completeness

# Naming
rg -n 'pub fn [a-z]+_[a-z]' src -t zig                           # snake_case fn names (should be empty; snake_case pub const is house style)
rg -n '\b(m_|p_|g_)[a-z]' src -t zig                             # hungarian prefixes
rg -n 'world_enabled|is_not|has_no|no_' src -t zig               # misleading-flag candidates; classify

# Builtins
rg -n '@ptrCast|@truncate' src -t zig                            # justify each
rg -n 'std\.math\.(min|max|abs)\b' src -t zig                    # prefer builtins
rg -n 'std\.meta\.(intToEnum|enumToInt|Int|Tuple)' src -t zig
rg -n '@intFromFloat' src -t zig                                 # deprecated
rg -nU 'for \([^)]*\) \|[^|]*\| \{\s*\n[^}]*\[[^]]*\] =' src -t zig  # copy loops (memcpy candidates; -U spans lines)

# Comptime
rg -n 'inline fn|inline for|comptime |anytype' src -t zig
rg -n '@compileLog|@compileError|@setEvalBranchQuota|@inComptime' src -t zig

# Zero-cost smells
rg -n 'HashMap|StringHashMap' src -t zig                         # comptime map candidates
rg -n '\*const fn|fn \*|\.handler|vtable' src -t zig             # runtime dispatch candidates
```

Classify each hit: **canonical, leave** / **rename-only fix** /
**practice fix (builtin swap)** / **structure finding (report only)**.

## Finding severity

| Sev | Meaning | Examples |
|---|---|---|
| **P0** | Structure or practice violation that is a real footgun | `world` imports `wire`; `@truncate` on wire decode; `@ptrCast` on untrusted length |
| **P1** | Clear non-canonical with real cost | Manual copy loop on tick; runtime map for a closed set; `@intFromFloat`/`std.meta.Int` in core path |
| **P2** | Naming drift, comptime abuse, cold-path builtin choice | Misleading flag name, `inline` on a large fn, `std.math.abs` on cold path |
| **P3** | Nit | Missing `//!`, comment wording, `pub` on a file-private helper |

## Deliverables

### Always

1. **`docs/ZIG_PRACTICES_REVIEW.md`** (create or update) with:
   - Scope (paths, mode, date)
   - Per-section tables: location (`path:line`), current form, canonical
     form, severity
   - A structure section: layering/cycle checks, god-file candidates
     (report only, no moves without user sign-off)
   - A builtin-audit line per category: canonical hits listed once, drift
     hits in the table
   - Ordered fix plan (renames first, structure last)
2. Short note in chat: top 5 findings + whether tests were run

### If fixing

- Minimal patches; one theme per commit if commits are asked for
- `make check` green
- Do **not** move/rename files unless the user asked
- Do **not** mix in hardcode/data moves, idiom fixes, or abstraction
  lifecycle changes

## Success criteria

- [ ] Structure checks ran and are reported (cycles, facades, placement)
- [ ] Filename audit ran (non-snake files listed or "none")
- [ ] Naming table conformance stated per finding
- [ ] Comptime sites classified good / should-be / should-not-be
- [ ] Builtin swaps listed with the canonical name and why
- [ ] Zero-cost findings scoped to the hot path for anything above P2
- [ ] No wire/sim behavior change; `make check` green if fixes applied
- [ ] No em dashes / AI attribution

## Optional user addenda

- "Renames only; no structural moves, no builtin swaps."
- "Builtins only: audit `@ptrCast`, `@truncate`, and deprecated `@intFromFloat`/`std.meta.*`."
- "Structure deep-dive on `src/server` and `src/wire`: facades, placement, god-files."
- "Comptime focus: classify every `comptime`/`inline`/`anytype` site."
- "Zero-cost focus: only hot-path (20 TPS / per-packet) findings above P2."
- "Produce ast-grep rules for `@truncate`, `@ptrCast`, and copy-loop patterns."
- "Report only; do not edit anything."
