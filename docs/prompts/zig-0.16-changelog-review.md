# Agent prompt: Zig 0.16 changelog conformance review (zdtd)

Your goal is to find code that drifted from the Zig 0.16.0 release notes:
removed APIs (absent by construction, spot-check), deprecated-but-present
APIs, and 0.15-era idioms that still compile but fight the `std.Io`
interface. Fix per the changelog upgrade guides, not by taste.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing and optionally fixing **Zig code** in **zdtd**
(`/home/maci/Desktop/7dtd/zdtd`): a clean-room Zig 0.16 dedicated server for the
stock 7DTD client wire.

Ground truth is the
[**Zig 0.16.0 release notes**](https://ziglang.org/download/0.16.0/release-notes.html),
sections **Language Changes**, **Standard Library**, **Build System**. Where the
changelog gives an upgrade guide (for example
`std.time.Instant -> std.Io.Timestamp`), zdtd code must already follow the
right-hand side. Cite the changelog subsection per finding.

This is **not** the general idiom review (`zig-idiomatic-review.md`), **not**
the abstraction lifecycle review (`abstractions-review.md`), **not** the
SIMD pass (`simd-review.md`), **not** the language best-practices review
(`zig-best-practices-review.md`), **not** the ECS/SoA state-ownership review
(`ecs-soa-review.md`), and **not** the hardcoded-data audit
(`hardcoded-data-review.md`). Focus only on 0.16 conformance: API names,
interface shape, and removed/deprecated surface. Style and hot-path rules from
AGENTS.md still apply where they interact (tick path, no em dashes).

### Key framing: what can actually be wrong

zdtd pins Zig 0.16 and `make check` is green, so genuinely **removed** APIs
cannot exist in the tree. The review hunts:

1. **Deprecated-but-present** APIs the changelog flags (`@intFromFloat`,
   `std.meta.Int`, `std.mem.indexOf*` aliases, `@cImport`).
2. **0.15-era idioms that still compile** but fight the 0.16 interface:
   medium-level `std.posix` calls outside the sanctioned residual table,
   managed-style containers, time/thread patterns that bypass the `Io` model.
3. **Missed 0.16 opportunities** in touched or new code: `Io.Reader` /
   `Io.Writer.fixed`, unmanaged containers, `std.testing.io`, `process.Init`
   args, `Io.Dir.createFileAtomic`.
4. **Drift from the documented residuals**: every `std.posix` / `posix.system`
   call in application code must be listed in `docs/STD_ABSTRACTIONS.md`
   (Residual thin posix table). Anything else is a finding.

## Read first

| Doc | Why |
|---|---|
| [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html) | Ground truth: upgrade guides per change |
| `AGENTS.md` (Zig style, critical rules, checklist) | House style and tick-path rules |
| `docs/STD_ABSTRACTIONS.md` | Sanctioned residual thin posix + why clock/accept stay low |
| Touched source files | Actual code under review |

## Non-negotiable constraints

- **Zig 0.16+** only. No pre-0.16 shims, no compat wrappers that exist solely
  to hide a 0.15 name.
- **No em dashes. No AI attribution** in commits, docs, comments, or PRs.
- **Keep `make check` / `zig build test` green.**
- **Minimal diffs.** A rename is a rename; do not refactor surrounding code.
- **Do not change wire or sim semantics.** `@intFromFloat` -> `@trunc`/
  `@floor` keeps the same conversion and the same deliberate trap on
  NaN/inf/huge (that trap is wire safety, keep it).
- **Tick path stays cheap.** No new `std.Io.Threaded` per call (its `init`
  installs SIGIO/SIGPIPE handlers, `Io/Threaded.zig:1652`).
- **Do not touch the documented residual posix** (`docs/STD_ABSTRACTIONS.md`):
  `posix.setsockopt` REUSEADDR/V6ONLY, `posix.poll` + `accept4`, `posix.read`/
  `system.write`/`system.close`, `posix.system.clock_gettime`/`nanosleep`.
  The changelog's "posix and os.windows removals" section sanctions exactly
  two directions: higher (`std.Io`) or lower (`std.posix.system`). zdtd's
  residuals are the low direction, each justified.

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Findings + `../reviews/ZIG_0_16_REVIEW.md`. No code changes. |
| **Fix** | Review + apply the rename/migration fixes; `make check` green. |

Default if unspecified: **review only**, all of `src/`.

## Changelog-grounded checklist (work through every section)

### A. Language changes

| Changelog change | Check |
|---|---|
| `@Type` replaced with `@Int`/`@Enum`/`@Struct`/`@Union`/`@Pointer`/`@Fn`/`@Tuple`/`@EnumLiteral` | No `@Type(` anywhere; `std.meta.Int` -> `@Int` (same args) |
| `@cImport` deprecated (moves to build system) | No `@cImport` in src |
| `@intFromFloat` deprecated ("redundant with `@trunc`") | `@intFromFloat(f)` -> `@trunc(f)`; `@intFromFloat(@floor(v))` -> `@floor(v)` with int result type |
| Small ints coerce to floats (`u24` -> `f32`, not `u25`) | No needless `@floatFromInt` under the precision limit |
| switch prong captures may no longer all be discarded | Compiler-enforced; verify no all-`_` captures remain |
| Packed unions: no pointers; explicit backing ints; extern contexts need explicit tag/backing | Compiler-enforced; spot-check wire `packed struct`/`union` for `usize`-style pointer fields |
| No runtime vector indexes; no in-memory array/vector coercion | Compiler-enforced; spot-check SIMD code |

### B. Time (changelog "Time")

| Upgrade guide | Check |
|---|---|
| `std.time.Instant` -> `std.Io.Timestamp` | Absent (removed) |
| `std.time.Timer` -> `std.Io.Timestamp` | Absent (removed) |
| `std.time.timestamp` -> `std.Io.Timestamp.now` | Absent (removed) |
| `Clock.resolution` added | Not needed by zdtd; do not add |

`util/clock.zig` is the deliberate Io-free leaf (vDSO `posix.system.clock_gettime`
per `docs/STD_ABSTRACTIONS.md`). This is correct; the changelog removed the
middle layer and sanctions `posix.system`. Do not flag, and do not "fix" by
constructing `Io.Threaded` per call. `Io.Threaded.init_single_threaded` exists
as a comptime-const Io (the release notes' own "no Io handy" workaround) but is
a single-thread fallback global; `clock.zig` stays on `posix.system`.

### C. I/O as an interface (changelog "I/O as an Interface", File System, Networking, Process)

| Upgrade guide | Check |
|---|---|
| Every fs/net/process API takes `io` | `io_fs` calls, `std.Io.Dir`/`File` methods, `litenet` use `io` params |
| `std.io` -> `std.Io`; `GenericReader`/`AnyReader` -> `Io.Reader`; `FixedBufferStream` -> `Io.Reader.fixed(buf)` / `Io.Writer.fixed(buf)` | Absent (removed); new code uses `Io.Reader`/`Io.Writer` fixed variants (webui HTTP path already does) |
| `std.leb.readUleb128`/`readIleb128` -> `Io.Reader.takeLeb128` | Any `std.leb` read sites migrate |
| `Dir.atomicFile(...)` -> `Dir.createFileAtomic(io, path, .{ .replace = true })`; writer via `file.writer(io, &buf)`; `renameIntoPlace()` -> `replace(io)` | `io_fs` atomic-write path |
| `process.Child.init`+`spawn` -> `process.spawn(io, .{...})`; `Child.run` -> `process.run(allocator, io, .{...})`; `execv` -> `process.replace(io, .{...})` | Any child-process use |
| `getCwd`/`getCwdAlloc` -> `currentPath(io, buf)`/`currentPathAlloc(io, allocator)` | Absent or migrated |
| `File.Stat.atime` now `?i128`-style optional; `setTimestamps` takes `.{ .access_timestamp, .modify_timestamp }` | Any stat/timestamp code |
| Added: `Io.Dir.walkSelectively`, `readFileAlloc`, `readToEndAlloc` | Optional; do not add unless needed |

### D. posix removals (changelog "posix and os.windows removals")

"Most `std.posix` and `std.os.windows` functions existed at an awkward
medium-level abstraction and have thus been removed. You must now choose a
direction: **Go higher: use `std.Io`** or **Go lower: use `std.posix.system`
directly**. More removals are planned."

- Every `std.posix.X` call in application code is either (a) in the residual
  table of `docs/STD_ABSTRACTIONS.md`, or (b) a finding: prefer `std.Io`, or
  move to `posix.system` with a documented reason.
- `Io.net.Server.accept` maps EAGAIN to `errnoBug` (debug panic,
  `Io/Threaded.zig:12467`), so the documented `poll(0)` + `accept4` stays.
- No new `std.posix.open/read/write` loops for ordinary files.

### E. Containers and allocators (changelog "Migration to Unmanaged Containers", allocator entries)

| Change | Check |
|---|---|
| `ArrayHashMap`/`AutoArrayHashMap`/`StringArrayHashMap` removed -> `array_hash_map.Custom`/`Auto`/`String` | Absent or migrated |
| `PriorityQueue`/`PriorityDequeue` no longer hold an allocator | Not used |
| `ArrayList` unmanaged: `.empty`, methods take `allocator` | No managed-style `ArrayList(...).init` with allocator field |
| `heap.ThreadSafeAllocator` removed | Absent |
| `heap.ArenaAllocator` now thread-safe and lock-free | Fine to use at init/load, never on tick |

### F. Threading (changelog "Thread.Pool Removed")

- `std.Thread.Pool` and `spawnWg` are **removed** -> `std.Io.async` /
  `std.Io.Group.async` for fire-and-forget work. zdtd parallelism stays on the
  project pool `util/parallel.zig`; verify it does not reference `Thread.Pool`.
- When Io-based concurrency is used, `Thread.Mutex`/`Thread.Condition`/
  `Thread.ResetEvent` must be `Io.Mutex`/`Io.Condition`/`Io.Event`.

### G. Process, env, args (changelog "Juicy Main", "Environment Variables and Process Arguments Become Non-Global")

- `main` takes `std.process.Init` or `std.process.Init.Minimal` (AGENTS: zdtd
  uses `Minimal`); argv via `init.args`, env via `init.environ` /
  `init.environ_map`. No `std.os.environ` global reads.
- No bare-arg `main()` if the process needs args/env.

### H. `std.mem` naming (changelog "mem: introduce cut functions; rename 'index of' to 'find'")

- `indexOf*` -> `find*` family (`find`, `findPos`, `findScalar`, `findAny`,
  `findNone`, ...). The `indexOf*` names remain as aliases (`mem.zig:1414`),
  so they compile; new/touched code must use `find*`.
- New `cut`/`cutPrefix`/`cutSuffix`/`cutScalar`/`cutLast`/`cutLastScalar` are
  the idiom for split-at-substring; prefer them in new code.

### I. Formatting (changelog "Replace {D} format specifier with Io.Duration format method")

- `{D}` is removed. Duration formatting is `{f}` with
  `std.Io.Duration{ .nanoseconds = ns }`.

### J. Build system (changelog "Build System")

- Dependencies fetch into project-local `zig-pkg/` (zdtd already does).
- `zig build --fork=[path]` overrides are available for local package forks.
- `build.zig.zon` requires `fingerprint` and enum-literal `name` (verify).
- Unit test timeouts, `--error-style`, `--multiline-errors` are opt-in; do not
  add unless useful.

## Known suspects (pre-scanned, start here; re-verify line numbers)

Drift confirmed at scan time (all compile, all deprecated/renamed per the
changelog). Line numbers rot; re-verify each pin before citing or fixing:

```text
src/apm/metrics.zig:153          @intFromFloat(@ceil(...))        -> @ceil(...) int result
src/wire/packages.zig:2646       @intFromFloat(bd)                -> @trunc(bd)
src/world/sleepers.zig:70-71     @intFromFloat(@floor(x/z))       -> @floor(x/z) int result
src/ecs/interest.zig:53          std.meta.Int(.unsigned, lanes)   -> @Int(.unsigned, lanes)
src/apm/report.zig:143-159       std.mem.indexOf (tests)          -> std.mem.find
```

Comments to sweep when fixing: `src/wire/packages.zig:685` and
`src/wire/stock_entity.zig:232` describe the deliberate NaN trap of
`@intFromFloat`; the semantics survive the rename (the new conversions still
trap), so update the comment wording, keep the behavior.

Already clean (spot-check only, do not re-search for hours): no `@Type(`,
no `@cImport`, no `std.time.Instant/Timer/timestamp`, no `Thread.Pool` /
`spawnWg`, no `ArrayHashMap*`, no `getAppDataDir`, no `process.getCwd`, no
`GenericReader`/`AnyReader`/`FixedBufferStream`, no `std.io` old namespace, no
`Thread.Mutex/Condition` in code (one doc comment, see recipe), no `{D}` format.

## Search recipes (run early)

```bash
# Deprecated-but-present
rg -n '@intFromFloat' src --type zig
rg -n 'std\.meta\.Int|@Type\(' src --type zig
rg -n 'std\.mem\.indexOf|\.indexOf\(' src --type zig
rg -n '@cImport' src --type zig

# Removed (code hits must be zero; proves the audit ran. One sanctioned hit:
# a util/parallel.zig doc comment on IoMutex naming the old Thread.Mutex)
rg -n 'std\.time\.(Instant|Timer)|Thread\.Pool|spawnWg|ArrayHashMap|getAppDataDir|GenericReader|AnyReader|FixedBufferStream|std\.io\.|Thread\.(Mutex|Condition|ResetEvent)|\{D\}' src --type zig

# Residual-posix drift (every hit must be in docs/STD_ABSTRACTIONS.md)
rg -n 'posix\.(system\.)?(open|read|write|close|poll|setsockopt|clock_gettime|nanosleep|accept4|socket|bind|listen|fcntl|stat)' src --type zig

# Io-conformance spot checks
rg -n '\.atomicFile\(|renameIntoPlace|process\.(Child|execv)|getCwd' src --type zig
rg -n 'ArrayList\(' src --type zig   # .empty + allocator-arg style only
```

Classify each hit: **deprecated rename** (fix, semantics unchanged) /
**residual, sanctioned** (in STD_ABSTRACTIONS.md; leave) / **0.15 idiom that
still compiles** (migrate to the 0.16 shape) / **removed** (should not exist;
if found, the pin or the build is wrong).

## Finding severity

| Sev | Meaning | Examples |
|---|---|---|
| **P0** | Fights the 0.16 interface where it matters (hot path, wire) | New `posix` call on tick path outside residual table; alloc per call |
| **P1** | Deprecated API on a core path | `std.meta.Int` in interest; `@intFromFloat` in wire/stream encode |
| **P2** | Deprecated API on init/log/test paths or pure rename drift | `std.mem.indexOf` in tests; `@intFromFloat` in sleepers |
| **P3** | Nit | Comment wording left from a rename |

## Deliverables

### Always

1. **`../reviews/ZIG_0_16_REVIEW.md`** (create or update) with:
   - Scope (paths, mode, date) and the release-notes URL
   - Per-section tables: location (`path:line`), changelog subsection, 0.15
     form, 0.16 form, severity
   - A "residual posix" re-verification note: every call site cross-checked
     against `docs/STD_ABSTRACTIONS.md`
   - A "removed API audit" line: the rg for removed APIs returned nothing
     beyond the sanctioned `src/util/parallel.zig` doc-comment mention
   - Ordered fix plan (small PRs, one rename theme per PR)
2. Short note in chat: top 5 findings + whether tests were run

### If fixing

- Minimal patches; rename-only diffs; keep wire/sim behavior identical
- `make check` green
- Update `docs/STD_ABSTRACTIONS.md` only if a residual changes (it should not
  for this pass)
- Do **not** mix in general idiom cleanup

## Success criteria

- [ ] Every deprecated/renamed API listed in the changelog is hunted, with a
      verdict per hit
- [ ] Residual-posix call sites match `docs/STD_ABSTRACTIONS.md` exactly
- [ ] Removed-API rg is provably empty apart from the sanctioned
      `src/util/parallel.zig` doc comment
- [ ] Wire/sim behavior unchanged; NaN-trap comments updated, not removed
- [ ] If fixes applied: `make check` green, diffs minimal
- [ ] No em dashes / AI attribution

## Optional user addenda

- "Fix all deprecated APIs found; do not touch residual posix."
- "Review only `src/wire`, `src/ecs`, `src/util` for 0.16 drift."
- "Also flag missed 0.16 opportunities in new code, not just renames."
- "Verify `build.zig`/`build.zig.zon` against the Build System changelog
  section."
- "Produce a `zig build test` run to prove the audit did not break anything."
