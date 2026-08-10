# Agent prompt: Zig idiomatic code review (zdtd / Zig 0.16)

Your goal is to find code that fights Zig 0.16 idiom: allocator handling, error sets, comptime, slices and hot-path shape.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing and optionally fixing **Zig code** in **zdtd**
(`/home/maci/Desktop/7dtd/zdtd`): a clean-room Zig 0.16 dedicated server for the
stock 7DTD client wire.

Your job is a **style / idioms / correctness review** against house rules and
modern Zig practice, then a **prioritized fix list** (and optional patches).

This is **not** the hardcode/data audit (`hardcoded-data-review.md`), **not**
the abstraction lifecycle review (`abstractions-review.md`), **not** the
ECS/SoA state-ownership review (`ecs-soa-review.md`), **not** the SIMD
pass (`simd-review.md`), **not** the 0.16 changelog conformance review
(`zig-0.16-changelog-review.md`), and **not** the language best-practices
review (`zig-best-practices-review.md`). Focus on language use, structure,
memory, errors, comptime, I/O, and tick-path discipline. For "should this
helper exist?", use `abstractions-review.md`. For state ownership (ECS vs
resource vs world vs session) and SoA layout, use `ecs-soa-review.md`. For
dense-loop vectorization, use `simd-review.md`. For removed/deprecated API
names per the 0.16 release notes, use `zig-0.16-changelog-review.md`. For
layout/naming/builtin choice/zero-cost abstractions, use
`zig-best-practices-review.md`.

## Read first

| Doc | Why |
|---|---|
| `AGENTS.md` (Zig style, critical rules, anti-patterns, checklist) | Canonical house style |
| `docs/ASSETS.md` | Asset load patterns (if touching assets) |
| `docs/ECS_SYSTEMS.md` | SoA / tick architecture |
| Touched source files | Actual code under review |

## Non-negotiable constraints

- **Zig 0.16+** only. No pre-0.16 shims, no "works on 0.11" patterns.
- **No em dashes. No AI attribution** in commits, docs, comments, or PRs.
- **Stdlib abstractions over OS-specific guts** (AGENTS rule 24): prefer
  `std.Io`, `std.Io.Dir` / `File`, `std.Io.Threaded`, `std.mem`, `std.fmt`,
  `std.Thread` (via project pool), `util/io_fs.zig`. Do **not** open-code
  `std.os.linux.*` or raw `std.posix` file loops for ordinary work, and do not
  reintroduce a second FS path (the old `linux_fs` module is gone; `io_fs` /
  `std.Io` is the only one). Zig has no OOP "abstract classes"; the idiomatic
  equivalent is **stdlib interfaces / vtables** (`std.Io`) and shared helpers on
  top of them. LiteNet UDP is `litenet/udp_socket.zig` via `std.Io.net`, the
  sanctioned path; do not invent a second raw net stack.
- **Follow Zig Zen** (see below): intent, edge cases, one obvious way, fail
  early, memory is a resource, serve the users.
- **Keep `make check` / `zig build test` green.**
- **YAGNI + minimal diffs.** Prefer small idiomatic fixes over drive-by rewrites.
- **Do not break stock wire fidelity** while "cleaning" package builders.
- **Tick path stays cheap:** no heap alloc, no XML re-parse, no file I/O on the
  50 ms sim tick (except existing batched poll/send).

## Zig Zen (review lens)

Use these as a severity tie-break when two fixes both "work." Official spirit
([Zig Zen](https://ziglang.org/documentation/master/#Zen)):

| Zen line | In zdtd practice |
|---|---|
| Communicate intent precisely | Names match behavior; `///` ownership; exhaustive switches; typed errors |
| Edge cases matter | Empty peer list, zero-length body, cap hit, missing game-dir, bad C2S |
| Favor reading code over writing code | Small fns; no clever macros; RE cites beat clever packing |
| Only one obvious way to do things | One package builder per stock shape; one FS helper (`io_fs`); one parallel pool |
| Runtime crashes better than bugs | `assert` internal invariants; do not paper over corrupt sim state |
| Compile errors better than runtime crashes | Exhaustive enum switches; comptime layout checks; typed ids where cheap |
| Incremental improvements | Small PRs; fix idiom drift in files you touch instead of big-bang rewrites |
| Avoid local maximums | Do not micro-opt with raw syscalls if it blocks std.Io migration |
| Reduce the amount one must remember | Named caps; no magic numbers; no dual id spaces |
| Focus on code rather than style | Fix real footguns first; bikeshed last |
| Resource alloc may fail; dealloc must succeed | `try` alloc at init; `defer`/`errdefer`; never leak on error path |
| Memory is a resource | **No hot-path heap**; pools and scratch; caps |
| Together we serve the users | Stock client playability and 20 TPS beat purity theatre |

**Zen vs "clever Linux":** open-coding `getdents64` or `open` is a **local maximum**.
Prefer `std.Io.Dir` even if the generated code is similar; one portable, testable
way beats N OS-specific paths.

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Findings + `../reviews/ZIG_REVIEW.md` (or PR comment style tables). No code. |
| **Fix P0/P1** | Review + apply high-severity idiomatic fixes; re-run tests. |
| **Full pass on path** | Deep review of given dirs/files + fix all safe issues. |
| **Comptime focus** | Only comptime/inline/generics/`anytype` quality. |
| **I/O migration** | Replace raw linux FS in listed files with `io_fs` / `std.Io`. |

Default if unspecified: **review only** on the paths the user named; if none,
sample hot paths (`src/server/game.zig`, `src/ecs/*`, `src/wire/*`, `src/world/*`,
`src/assets/*`, `src/util/*`).

---

## What "idiomatic Zig" means here

House style is **zdtd-shaped**, not generic blog Zig. Optimize for:

1. Explicit allocators and ownership
2. Caller-owned buffers on wire/tick paths
3. **Zero heap allocation on the hot path** (see Hot path memory)
4. Closed sets and bit layouts at **comptime** where it removes runtime cost or
   duplication without hurting readability
5. Clear error sets and fail-closed untrusted input
6. SoA + fixed caps over clever dynamic graphs
7. **Stdlib abstractions first** (`std.Io`, `std.mem`, …) over OS-specific glue
8. Zig Zen: one obvious way, edge cases, memory is a resource

Reference naming (from AGENTS.md):

| Kind | Style |
|---|---|
| Functions / methods | `camelCase` |
| Variables / fields / params | `snake_case` |
| Types | `PascalCase` |
| Files | `snake_case.zig` |
| Module constants | `snake_case` |
| Stock package / type **strings** | Match TFP names |

---

## Review checklist (work through every section)

### 1. Comptime (use it well; do not abuse it)

Comptime-vs-runtime policy and builtin selection at large belong to
`zig-best-practices-review.md`; review comptime here where it intersects
memory, generics/`anytype` quality, and the hot path.

**Prefer comptime for:**

| Use | Good | Bad |
|---|---|---|
| Closed enum maps | Package name → handler table, bit field layouts | Gigantic comptime that rebuilds half the game |
| Small parsers / formatters | Fixed wire header sizes, `comptime` string hash of stock **names** | Comptime file I/O of full `blocks.xml` every compile without need |
| Generic helpers | `fn append(comptime T: type, …)`, `anytype` with clear constraints | `anytype` soup with no docs and 6 overload meanings |
| Unrolling tiny loops | `@memcpy`/`inline for` over 4–16 fixed fields | `inline for` over 10k items or whole chunk |
| Type-level invariants | `comptime assert` on struct sizes matching RE | Silent `@sizeOf` assumptions without test |

**Rules of thumb:**

- If a value is known at compile time and used in a hot path, consider `comptime`.
- If it only runs at init once, **runtime is fine** (XML load, map load).
- Prefer `comptime` **tables generated from data** (embed/parse fixtures) over
  hand-copied content (that is also a data-audit concern).
- `inline` = tiny hot helpers only (2–10 lines). Never `inline` large package
  builders or AI systems.
- Avoid `comptime` that makes **error messages unreadable** or compile times
  explode for little gain.
- Use `@Int` / `@Enum` / `@Struct` / `@Union` / `@Pointer` / `@Fn` / `@Tuple` /
  `@EnumLiteral` for type reification; `@Type` was removed in 0.16 and
  `std.meta.Int` is deprecated in its favor. For removed/deprecated-name
  verdicts, `zig-0.16-changelog-review.md` is the authority.

**Findings to hunt:**

```text
rg -n 'inline fn|inline for|comptime ' src --type zig
rg -n '@Type\(|@typeInfo|anytype' src --type zig
rg -n 'std\.meta\.|std\.mem\.' src --type zig   # ok patterns vs reinvented
```

Mark each: **good comptime** / **should be comptime** / **should not be comptime** /
**inline abuse**.

### 2. Generics, `anytype`, and interfaces

| Pattern | Prefer | Avoid |
|---|---|---|
| Small generic helper | `fn max(comptime T: type, a: T, b: T) T` | Copy-paste for u16/u32/i32 |
| Context callbacks | `*const fn (?*anyopaque, …)` or typed ctx pointer | Global function pointers with hidden state |
| `anytype` | One obvious duck type (e.g. table with `byName`) documented | Nested `anytype` in public APIs without examples |
| VTable / Io | `std.Io` as designed | Hand-rolled vtables for FS |
| Allocator | Explicit `std.mem.Allocator` param | Hidden GPA statics |

Check that `anytype` call sites would break loudly if the wrong type is passed
(method names used, not only field peeks that coerce badly).

### 3. Memory and ownership

| Rule | Check |
|---|---|
| Explicit allocator | Every growable structure knows who frees |
| `defer` / `errdefer` | Immediately after successful acquire |
| **Hot path: no heap alloc** | See subsection below (hard rule) |
| Caller buffers | `buildXxxBody(buf, …) ![]u8` not `allocator.dupe` per send |
| Arena | Init/load scoped arenas OK; never on 20 TPS hot path |
| Tests | `std.testing.allocator` or DebugAllocator; leaks fail |
| `page_allocator` | Not for tick, package bodies, interest, or stream encode |

### 3a. Hot path memory (hard rule)

**Hot path** = anything that can run every tick (50 ms) or per packet / per peer
/ per entity / per chunk on that tick. Includes:

- Main loop body after listen (`Game` tick, net poll dispatch)
- Package **decode** of C2S and **encode** of S2C
- Interest / replicate / serialize-once fan-out
- Chunk stream select + `stock_chunk` body build
- ECS systems (`systems.*`, AI, director step, power tick)
- LiteNet send/recv framing helpers called from the loop

**Forbidden on the hot path (P0/P1):**

| Pattern | Why |
|---|---|
| `allocator.alloc` / `create` / `dupe` / `allocPrint` | Heap per tick or per peer |
| `ArrayList.append` that may grow | Hidden realloc |
| `ArrayList` / `HashMap` **init** per call | Alloc + free churn |
| Arena `allocator()` used to build one package then tear down | Still alloc pressure |
| `page_allocator` anywhere here | Unbounded, slow, wrong layer |
| `std.fmt.allocPrint` | Heap string |
| Growing maps keyed by entity/chunk without a fixed cap | OOM / frame spikes |
| `Thread.spawn` to "help" one tick | Join cost + alloc |

**Required instead:**

| Pattern | Use |
|---|---|
| Caller / `Game` scratch | `body_buf`, `recv_buf`, `send_buf`, stack `[N]u8` |
| Fixed SoA columns | Pre-sized at world/init; denseness over pointers |
| Pools / free lists | Entity slots, chunk slots, already-allocated queues |
| Named caps | `max_streamed_chunks`, interest lists, cmd buffers; **fail or drop** at cap |
| `ArrayList` only if | Capacity reserved at init and **never grows** on tick (`append` only when `len < cap`, or use fixed array) |
| Format | `std.fmt.bufPrint` into stack or scratch |
| Temporary sets | Bitsets / fixed arrays / reuse `Game` scratch cleared each tick |

**Init / load / admin (OK to allocate):**

- `Game.create`, map/XML/TTS/prefab load, AssignIds merge
- Admin telnet one-shot commands
- First-touch worldgen that fills a chunk into an **already reserved** chunk slot
  (the slot storage is pooled; avoid per-block heap)
- Tests

**Gray area (document if present):**

- Rare path under a tick counter (`tick_n % N`) still counts as hot if N is small
  or peer count is high: treat as hot unless proven init-only.
- Debug logging: prefer stack buffers; never `allocPrint` in release hot paths.

**Review questions for every finding:**

1. Can this run on the 20 TPS path or per packet?
2. Does it call anything that may allocate (including std helpers)?
3. If yes: move to init, reuse scratch, or pre-cap and drop.

Hunt:

```text
# Direct alloc on likely hot modules
rg -n 'allocator\.(alloc|create|dupe|realloc)|page_allocator|allocPrint|\.dupe\(' \
  src/server/game.zig src/ecs src/wire src/litenet src/world/store.zig src/world/worldgen.zig --type zig

# Growable structures
rg -n 'ArrayList|HashMap|SegmentedList' src/server/game.zig src/ecs src/wire --type zig

# Format heap
rg -n 'allocPrint|allocPrintZ' src --type zig

# Ownership hygiene
rg -n 'defer |errdefer ' src --type zig
```

**Severity guide:**

| Sev | Example |
|---|---|
| **P0** | `alloc` inside per-peer interest encode or per-chunk stream body build |
| **P1** | `ArrayList` grow on tick; `dupe` of package name/body per send; map insert per entity without cap |
| **P2** | Alloc on rare admin path that shares code with tick (split paths) |
| **P3** | Init-path alloc style nits |

When fixing: prefer **scratch buffer fields on `Game`/`World`**, fixed max arrays,
and encode-into-slice APIs. Do not "fix" with a bigger arena wiped each tick
unless the arena is a single reused block with cleared high-water mark and a hard
cap (still document; prefer true fixed scratch).

### 4. Errors and control flow

| Prefer | Avoid |
|---|---|
| Named error sets or precise `anyerror` only at boundaries | Swallowed `catch {}` without comment |
| `try` / `errdefer` | Manual cleanup ladders |
| `catch |err|` log + safe fallback with reason | `catch unreachable` on untrusted input |
| `std.debug.assert` for internal invariants | Assert on client-controlled lengths |
| Optional `?T` for not-found | Sentinel `-1` without type help |

Untrusted C2S: reject/drop/disconnect; never crash the process on one bad peer
when avoidable.

### 5. Optionals, enums, and illegal states

- Prefer `enum` / `union(enum)` over parallel bool flags that can disagree.
- Prefer `?T` over magic `0` meaning both "air" and "unset" unless wire-defined.
- Exhaustive `switch` on enums (Zig forces this; do not `@panic("todo")` arms on
  production paths without a tracked gap).
- `packed struct` / explicit widths when matching wire or bitsets; document
  endian and RE cite.

### 6. Slices, arrays, and numbers

| Prefer | Avoid |
|---|---|
| `@memcpy` / `@memset` | Manual byte loops for bulk copy |
| `@min` / `@max` | Branchy min/max |
| `@intCast` with prior bounds check | Blind cast of untrusted lengths |
| Named `const` for sizes/caps | Magic `169`, `96`, `3_000_000_000` inline |
| `[]const u8` for borrowed strings | Owning copies without need |

### 7. Zig 0.16 stdlib abstractions (not OS-specific layers)

**Principle:** call the **highest stable std abstraction** that does the job.
Do not drop to `std.os.linux`, `std.c`, or raw `posix` because it is "what the
kernel wants." Thin project wrappers are OK only if they wrap std (`io_fs` →
`std.Io`), not if they re-export syscalls.

| Domain | Idiomatic (prefer) | Non-idiomatic (avoid in new/touched code) |
|---|---|---|
| Files / dirs | `std.Io.Threaded` + `std.Io.Dir` / `File`; `util/io_fs.zig` | `std.os.linux.open/read/write/getdents*`, ad-hoc `posix` loops, any second FS path |
| Paths | `std.fs.path` / `bufPrint` into stack | Hardcoded `/tmp` for large caches; machine-local Steam paths outside tests |
| Sync | `std.Io.Mutex` / `Condition` (with Io) | `std.Thread.Mutex`/`Condition`/`ResetEvent` (removed in 0.16; migrate to `Io.Mutex`/`Condition`/`Event`, verdicts per `zig-0.16-changelog-review.md`); spinlocks without need |
| Threads | `util/parallel.zig` persistent pool | `Thread.spawn` per parallel-for; detached fire-and-forget on tick |
| Formatting | `std.fmt.bufPrint` | `allocPrint` on hot path; manual digit loops without reason |
| Mem | `std.mem`, `@memcpy`/`@memset` | Hand-rolled copy that ignores aliasing/overlap |
| Random (sim) | Explicit seeded PRNG state | `std.crypto.random` on loot/AI tick |
| Net (new code) | `litenet/udp_socket.zig` (`std.Io.net`) for UDP; `util/tcp_listen.zig` for TCP (AGENTS rule 24) | Second raw-syscall UDP stack beside LiteNet |
| ArrayList | `.empty` + methods take `allocator` | Pre-0.16 init styles; grow on tick |

**Layering (top → bottom; stay high):**

```text
  game / assets / world code
           │
           ▼
  util/io_fs.zig   (optional thin helper)
           │
           ▼
  std.Io + Dir/File/Threaded     ← stop here for ordinary FS
           │
           ▼
  std.posix / std.os.linux       ← only inside std or documented legacy (LiteNet)
```

Crossing below `std.Io` in application code is a **P1** (P0 if new file or
hot path). No legacy `linux_fs` remains in `src/util` (the migration is done);
keep it that way and never reintroduce a second FS path.

Hunt residual low-level I/O:

```text
rg -n 'std\.os\.linux\.|std\.posix\.(open|read|write|close)|std\.c\.(open|read)' src --type zig
rg -n 'linux_fs\.' src --type zig   # should be empty: migration done, regression guard
rg -n 'io_fs\.|std\.Io\.' src --type zig
```

Classify each hit: **legacy OK (cite why)** vs **migrate when touching** vs
**must fix now**.

### 8. Structure and layers

Folder structure and layering policy in depth belongs to
`zig-best-practices-review.md`; here, flag only violations of the zdtd layer
table below.

| Layer | Holds | Must not hold |
|---|---|---|
| `wire/*` | Package body layout, binary LE | Game rules, world mutation |
| `ecs/*` | SoA sim, pure systems | Syscalls, package id integers |
| `world/*` | Chunks, TTS, gen, store | LiteNet send |
| `server/game.zig` | Join SM, orchestration, send | Open-coded package field writes (use builders) |
| `assets/*` | XML/tables load | Tick logic |
| `litenet/*` | Framing, UDP | Sim |

(`apm/*`, `util/*`, `plugin/*`, and top-level `main.zig` / `protocol.zig` /
`fuzz.zig` / `version.zig` also exist; review them by the general rules above.)

Findings: cyclic imports, god-files that should split, `pub` on helpers that
should be file-private, duplicated encoders for one stock package shape.

### 9. Naming and API clarity

Naming policy (full table, casing rules) is owned by
`zig-best-practices-review.md`; here, flag names that misstate behavior or hide
ownership.

- Flags named for **what they do** (`stream_chunks` not `world_enabled` if it
  only throttles streaming).
- Functions: verb + object; no ambiguous `handle` / `process` without package name.
- Ownership in `///` on public APIs: who frees, whose buffer, lifetime of returned slices.
- File-level `//!` purpose + non-goals.
- No narrating comments on obvious code; RE/layout comments on wire fields are good.

### 10. Tick path (20 TPS)

Review any change that runs per tick or per packet:

- [ ] **No heap allocation** (section 3a): no `alloc`/`dupe`/`allocPrint`, no growing lists/maps
- [ ] No file/XML/network connect (beyond existing batched poll/sendto)
- [ ] No unbounded `ArrayList` growth; prefer fixed caps + drop
- [ ] No `Thread.spawn` outside `util/parallel` pool
- [ ] Caps named and enforced (stream, interest, entities, cmd buffers)
- [ ] Material cost has `apm` section/counter when new hot work is added
- [ ] Deterministic order where two systems touch the same data
- [ ] Scratch buffers are reused (`body_buf` etc.), not allocated per call

### 11. Tests

- Unit tests at **bottom** of owning file
- Multi-system paths in `server/scenarios.zig`
- Wire builders: size/marker/golden tests
- Comptime-heavy code: at least one test that would fail if layout drifts
- No `skip` to land a feature; `SkipZigTest` only when stock install missing

### 12. Build and tooling

- Logic in `build.zig` / `build.zig.zon`, not only Makefile
- No `-f` flags that hide safety in Debug without reason
- `DebugAllocator` in main for dev

---

## Finding severity

| Sev | Meaning | Examples |
|---|---|---|
| **P0** | Wrong / unsafe / tick bomb | Leak on hot path, raw syscall in new code, catch on C2S that applies bad state, non-exhaustive switch crash |
| **P1** | Clear non-idiomatic with real cost or footgun | Alloc per package send, inline 200-line fn, anytype public API, second FS path reintroduced |
| **P2** | Style / maintainability | Naming drift, missing `//!`, comptime that should be runtime (or reverse), god-file split candidate |
| **P3** | Nit | Comment polish, import order, micro-readability |

---

## Deliverables

### Always

1. **`../reviews/ZIG_REVIEW.md`** (create or update) with:
   - Scope (paths, mode, date)
   - Summary counts by severity
   - Tables: location (`path:line`), issue, idiomatic fix, severity
   - Comptime-specific subsection (good / bad / missing)
   - I/O / syscall debt list (legacy vs fix-now)
   - Ordered fix plan (small PRs)
2. Short note in chat: top 5 issues + whether tests were run

### If fixing

- Minimal patches; one theme per commit if user asked for commits
- `make check` green
- Update `TODO.md` only if review debt is tracked there
- Do **not** mix hardcode/data moves unless required for the idiomatic fix

### Optional

- Link from `docs/INDEX.md` under prompts / engineering
- Suggest `ast-grep` rules for recurring anti-patterns

---

## Search recipes (run early)

```bash
# Comptime / inline / generics
rg -n 'inline fn|inline for|comptime ' src --type zig
rg -n 'anytype|@TypeOf|@typeInfo|@Type\(' src --type zig

# Memory / tick risk
rg -n 'page_allocator|allocator\.alloc\(|\.dupe\(' src/server src/ecs src/wire --type zig
rg -n 'Thread\.spawn' src --type zig

# I/O debt
rg -n 'std\.os\.linux\.|std\.posix\.(open|read|write|close)' src --type zig
rg -n 'linux_fs\.' src --type zig   # should be empty: proves the no-second-FS guard held
rg -n 'io_fs\.' src --type zig

# Errors
rg -n 'catch \{\s*\}|catch unreachable' src --type zig

# Zig 0.16 ArrayList style drift
rg -n 'ArrayList\(' src --type zig

# Public surface sprawl (methods are indented inside `pub const Game = struct`)
rg -c 'pub fn ' src/server/game.zig
```

Prefer **ast-grep** for structural patterns (e.g. all `catch {}` blocks, all
`inline fn` over N lines) when available.

---

## Good vs bad examples (zdtd-shaped)

### Comptime table (good)

```zig
const package_handlers = std.StaticStringMap(Handler).initComptime(.{
    .{ "NetPackageSetBlock", handleSetBlock },
    // …
});
```

### Inline abuse (bad)

```zig
inline fn buildHugePackage(...) ![]u8 { // 150 lines
```

### Caller buffer (good)

```zig
pub fn buildWorldTimeBody(buf: []u8, bits: u64) ![]u8 {
    // write into buf, return buf[0..n]
}
```

### Hidden alloc on send (bad)

```zig
const body = try allocator.alloc(u8, 64); // per peer per tick
```

### Hot path scratch (good)

```zig
// Game.body_buf reused every send
const body = try packages.buildWorldTimeBody(self.body_buf[0..16], bits);
try self.broadcast("NetPackageWorldTime", body);
```

### Hot path list grow (bad)

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
// … append interested peers every tick …
```

### Hot path fixed cap (good)

```zig
var peers: [max_clients]u16 = undefined;
var n: usize = 0;
// append only while n < peers.len; else drop furthest
```

### I/O via std abstraction (good)

```zig
try io_fs.writeFile(allocator, path, bytes);
// or, constructed ONCE at startup and the `io` passed down
// (Threaded.init installs signal handlers; never build one per call):
var threaded = std.Io.Threaded.init(allocator, .{});
defer threaded.deinit();
const io = threaded.io();
try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
```

### I/O via OS-specific syscalls (bad in app code)

```zig
const fd = std.os.linux.open(...); // or a project wrapper re-exporting the same
_ = std.os.linux.getdents64(fd, ...);
```

### Errors (good)

```zig
const n = parseSetBlockChanges(body, tmp) catch {
    // malformed C2S: drop
    return;
};
```

### Errors (bad)

```zig
_ = parse(...) catch {}; // applied nothing, caller thinks success
```

---

## Anti-patterns (quick list)

- Dropping to `std.os.linux` / raw `posix` / `std.c` for ordinary FS or process I/O
- Reintroducing a second FS path beside `io_fs` / `std.Io` (the `linux_fs` migration is done)
- Reimplementing what `std.mem` / `std.fmt` / `std.Io` already do
- Two ways to do the same I/O or encode (violates "one obvious way")
- **Any heap allocation on tick / per-packet / per-peer encode path**
- `page_allocator` or unbounded `ArrayList`/`HashMap` growth on tick
- Arena-per-package or `allocPrint` in the main loop
- `inline` on large functions
- Comptime that embeds policy better left as data/config
- `anytype` public APIs without a single documented shape
- Second encoder for the same stock package
- `catch {}` without intentional drop + comment
- Global mutable allocator or sim RNG
- `Thread.spawn` per parallel-for invocation
- Magic numbers on wire/tick paths
- Narrating comments; missing RE cites on wire layout
- Pre-0.16 `ArrayList` init / allocator styles
- Using `@import` cycles to avoid a facade (`ecs/root.zig`, etc.)
- Ignoring edge cases (empty, max, malformed) because the happy path works

---

## Success criteria

- [ ] Findings are actionable with `path:line` and severity
- [ ] Comptime/inline/`anytype` called out explicitly
- [ ] **Hot-path alloc findings listed** (or explicit "none found" after search)
- [ ] I/O debt classified: std abstraction vs OS-specific legacy vs fix-now
- [ ] Zig Zen called out where a fix chooses the clearer/one-way path
- [ ] No P0 left unmentioned in scope
- [ ] If fixes applied: `make check` green, diffs minimal
- [ ] No em dashes / AI attribution
- [ ] Stock wire behavior unchanged unless bugfix was incorrect code

---

## Optional user addenda

- "Review only `src/util/parallel.zig` and `src/world/worldgen.zig`."
- "Fix all P0/P1 I/O: migrate touched files to std.Io / io_fs; no second FS path."
- "Comptime focus: package maps and binary layouts."
- "Hot path only: fail every heap alloc / growing list on tick and interest."
- "Apply Zig Zen as the primary rubric; cite which zen line each P0/P1 maps to."
- "Compare to agave AGENTS.md habits where they do not conflict with zdtd."
- "Produce ast-grep rules for catch-empty, linux.open, and allocator.alloc in ecs/wire."
- "Do not edit game.zig; findings only."
