# Local dependency patches

Patches applied to packages under `zig-pkg/` (which is gitignored and
hash-pinned in `build.zig.zon`). A fresh checkout fetches the pristine
upstream tarball, so **none of these are active until re-applied or
upstreamed**. `scripts/apply-patches.sh` is that re-application: run it
after the trees are extracted (a bare `zig build --fetch=all` extracts
without compiling) and after any later fetch of pristine trees — it is
idempotent and skips what is already applied. `build.zig` refuses to
configure against an unpatched tree (it checks one marker line per patch
in the extracted sources, so a missing patch is a loud build failure
naming this script, not a green build with the fixes compiled out);
`scripts/verify.sh` and CI run extraction + this script before any
compile for the same reason. Each entry says what breaks without it.

**The `.patch` file in this directory is the canonical record of each
change.** It must always apply with `patch -p1` to the pristine upstream
package at the pinned commit, with no other input — never treat a fork
branch as the source: branches (the `ywy50/libvaxis` ones below included)
are one-way mirrors pushed *from* these files so an upstream PR has
somewhere to come from, and nothing keeps them alive or current. If a
branch and its patch file ever disagree, the file wins; recreate the branch
by applying the file to the pinned commit and committing the result.

To verify the set is still self-contained: check out the pinned commit of
the dependency (`build.zig.zon` names it), apply every patch that targets
it in the order listed here, and `diff -r` the result's `src/` against the
`zig-pkg/` copy — it must come back empty. Get pristine sources from a git
checkout of the pinned commit, **not** from `zig fetch`: run inside this
project, `zig fetch` of the pinned URL materializes the tarball from the
already-patched `zig-pkg/` copy (the content hash is never re-verified
after extraction), so it silently returns the patched tree. Verified for
both vaxis patches against `82cec0db` on 2026-08-17.

## vaxis-sixel-graphics.patch

Target: vaxis 0.6.0 (`zig-pkg/vaxis-0.6.0-*`). Apply with `patch -p1` inside
that directory.

Adds SIXEL raster graphics to libvaxis: the capability, the encoder, and an
image lifecycle owned by the renderer. Without it the mascot has kitty
graphics and unicode half-blocks only — [ADR 0013](../docs/adrs/0013-sixel-precedes-unicode-mascot-fallback.md)
and [PRD 0036](../docs/prds/0036-sixel-mascot-rendering.md) describe why the
middle renderer is worth having: a terminal with SIXEL but not kitty can show
the real artwork in the same number of cells, where half-blocks have two
colour samples per cell.

Nothing in clanker breaks without the patch. `mascot.zig` gates every SIXEL
path behind `sixel_supported`, which is `@hasField(vaxis.Vaxis.Capabilities,
"sixel_graphics")`, so an unpatched dependency compiles the path out and the
mascot falls back to cells exactly as it did before. That is what makes a
patch (rather than a pinned fork) safe here: a fresh clone builds and passes
`zig build test` and `clanker gate` with one fewer renderer.

The e2e pty journeys (`zig build e2e`) used to be the exception, and it cost
two investigation records before anyone connected them to this paragraph. Their
shared harness *required* an answer to the sixel geometry query, which only the
patched query phase sends, and it gated its DA1 answer behind having sent that
answer — so on an unpatched dependency DA1 went unanswered too, even though it
had arrived, and both journeys failed at the handshake. Since `patches/` lands
in gitignored `zig-pkg/`, every fresh worktree is unpatched, which is why this
read first as a headless-session problem
([2026-08-22-pty-e2e-capability-queries-unanswered.md](../docs/reports/investigations/2026-08-22-pty-e2e-capability-queries-unanswered.md))
and then as a worktree problem
([2026-08-22-pty-e2e-fails-in-a-worktree.md](../docs/reports/investigations/2026-08-22-pty-e2e-fails-in-a-worktree.md)).
`answerQueries` now answers that query when it arrives and skips it when it does
not, so both journeys complete their handshake either way.

What a green `zig build e2e` on a pristine tree does **not** mean: with
`sixel_supported` false every SIXEL path is compiled out, so those journeys then
exercise strictly less than the same journeys in a patched checkout. It is not
evidence about sixel. `pty_resize_test` is the sharper case — it is the
regression test for the SIGWINCH crash that `vaxis-winch-self-pipe.patch` fixes,
so on a pristine tree it reproduces that crash and fails by design
(`error.ReplStoppedReadingTty`, whose message names this file). Run
`scripts/apply-patches.sh` before reading anything into an e2e result.

What the patch contains:

- `Capabilities.sixel_graphics`, set only when the primary device attributes
  claim attribute 4 **and** the terminal answered the XTSMGRAPHICS geometry
  query. The geometry query is sent before DA1, which is what ends the query
  phase, so both answers are in hand when the decision is made. A terminal
  name is never consulted; a multiplexer that forwards the attribute bit
  without implementing the protocol fails the second half.
- `src/sixel.zig`: a deterministic 6x6x6 cube quantizer and a DCS encoder that
  defines only the registers a raster uses, keeps transparent pixels
  untouched, and bounds decoded dimensions, palette size and output bytes
  before anything is written.
- `Vaxis.loadSixelImage` / `hasSixelImage` / `clearSixelImages`, plus
  `Cell.sixel`. Applications place a raster on a cell; only `Vaxis.render`
  writes DCS. It erases the rectangle before each frame (so a transparent
  frame cannot reveal the one it replaces), saves and restores the cursor
  around the payload, and drops every raster on resize and teardown because a
  payload is only valid for the cell geometry it was encoded at.

Status: local-only, and upstreamable as-is. This file is what survives a
`zig-pkg` wipe until the fix lands upstream and the pin in `build.zig.zon`
moves. A mirror of the same change is pushed to `github.com/ywy50/libvaxis`
on the `sixel-graphics` branch, which is where a PR to `rockorager/libvaxis`
would come from; the branch is derived from this file (apply it to
`82cec0db`, the commit `build.zig.zon` pins, and commit), never the other
way around.

## vaxis-ss3-keypad-enter.patch

Target: vaxis 0.6.0 (`zig-pkg/vaxis-0.6.0-*`). Apply with `patch -p1` inside
that directory.

Adds `'M' => kp_enter` to `Parser.zig`'s SS3 table. `ESC O M` is keypad Enter,
and it is also what Konsole's default keytab sends for Shift+Return
(`key Return+Shift : "\EOM"`); the unpatched parser drops the sequence with
`warning(vaxis_parser): unhandled ss3: 4d` and no key event, so Shift+Enter in
`clanker repl` on Konsole could never reach the line-break handler and each
press painted a stderr warning over the alt-screen instead (that painting is
fixed separately by `std_options.logFn` in `src/main.zig`, which this patch
does not depend on).

Without the patch nothing in clanker breaks: on terminals speaking the kitty
keyboard protocol Shift+Enter arrives as `enter` + shift mods and the repl's
line-break handler fires; the repl also matches `kp_enter` so the patched
legacy path lands in the same branch. A fresh clone or CI merely loses
Shift+Enter on legacy-Konsole-style terminals.

The patch also carries a `parse: ss3 keypad enter` test beside the other
parser tests. It never runs inside clanker's build (vendored dependency
tests are not part of `zig build test`); it exists for the upstream PR, and
vaxis's own `zig build test` passes with the patch applied at the pinned
commit.

Status: local-only, upstreamable as-is. This file is what survives a
`zig-pkg` wipe until the fix lands upstream and the pin moves. A mirror is
pushed to `github.com/ywy50/libvaxis` on the `ss3-keypad-enter` branch —
same arrangement as `sixel-graphics` above: derived from this file, never
its source.

## vaxis-winch-self-pipe.patch

Target: vaxis 0.6.0 (`zig-pkg/vaxis-0.6.0-*`). Apply with `patch -p1` inside
that directory, after the two patches above — it touches `src/main.zig`, which
`vaxis-sixel-graphics.patch` also edits.

Unlike the other two, **clanker is broken without this one.** Resizing the
terminal during `clanker repl` aborts the process and leaves the terminal in
raw mode with the alt-screen still up and mouse tracking on — no scroll, no
copy, and the panic message invisible inside the alt-screen that was never
popped. There is no capability check that compiles the path out, because the
path is "the operator resized the window". Full mechanism and measurements:
[the bug report](../docs/reports/bugs/2026-08-17-tui-resize-crash-sigwinch-in-signal-handler.md).

Two changes, one per link in the failure:

- `tty.zig`: SIGWINCH becomes a self-pipe. `handleWinch` used to run the
  registered winsize callbacks inside the signal handler, and those callbacks
  are not async-signal-safe — `handler_mutex` and `Loop.winsizeCallback`'s
  `postEvent -> queue.push` are `std.Io` operations. A `std.Io` call issued
  from a signal that interrupted an `Io.Threaded` pool thread mid-syscall hits
  `.blocked => unreachable` in `Syscall.start`, and `Loop.ttyRun` sits in
  `readv` on the tty for the process's whole life, so it is the thread the
  signal lands on. Now the handler does one raw `write(2)` onto a static pipe —
  skipped when a wakeup is already queued, so a resize storm cannot fill the
  buffer and make the handler block — and a detached plain `std.Thread` reads
  that pipe and runs the callbacks normally. A plain thread is the whole trick:
  `Io.Threaded.Thread.current` is null off the pool, so `Syscall.start` returns
  early instead of inspecting a status that was never set.
- `main.zig`: `recover()` stops going through `std.Io`. It is documented as
  panic-context-only, and the panic it most needs to survive is one raised *by*
  `std.Io` — so the buffered tty writer re-raised the identical panic from
  inside the panic handler, ~6900 times, until the stack overflowed. It now
  writes the reset string with raw `write(2)` and restores termios with
  `tcsetattr`, and no longer calls `Tty.deinit`, whose `close` is also a
  `std.Io` call. The tty is deliberately left open; the process is exiting.

An uncontended `std.Io.Mutex.lock` is a CAS with no syscall, which is why the
crash is intermittent rather than immediate: it needs a signal to land while
the lock is already held. Measured on a pty harness, the unfixed build dies
between 246 and 1594 resizes; the fixed one survived 5000 twice.

The matching one-shot guard on clanker's side (`claimTerminalRecovery` in
`src/main.zig`) is *not* in this patch — it is clanker's own source. Both are
needed: this patch stops `recover()` raising the second panic, and the guard
stops any future one recursing.

Status: local-only, upstreamable as-is. This file is the only durable copy of
both edits — `zig-pkg/` is gitignored, so a wipe or a re-fetch loses them and
nothing in `git status` will say so. Verified 2026-08-17 to apply cleanly with
`patch -p1` and reproduce the two files byte for byte.

## zwasm-lazy-mem-cksum.patch

Target: zwasm 2.5.0 (`zig-pkg/zwasm-2.5.0-*`, the `build.zig.zon` pin).
Apply with `patch -p1` inside that directory. Originally written against
2.4.1; re-derived against 2.5.0 (same six call sites, line numbers shifted
by one) when the pin moved — `scripts/apply-patches.sh` applies it like the
vaxis set.

zwasm's D-331A diagnostic fingerprints linear memory at every host-call
boundary: `dbg.print("mem.cksum", ..., .{dbg.fnv1a(rt.memory)})`. Zig
evaluates arguments eagerly, so the FNV-1a hash of the *entire* linear memory
(16 MiB for clanker guests) runs on every host call even with `ZWASM_DEBUG`
unset — `dbg.print`'s own enable-check happens after the argument is built.
Measured on `clanker tools list` (94 `ck_fs_read` calls): 58% of all cycles
in `dbg.fnv1a`, ~12 ms per host call, 1.25 s total; with the patch, 102 ms.
Every WASM tool call in every agent run pays this, not just listing.

The patch guards all six call sites (1 interp, 5 JIT/WASI) with
`if (dbg.on("mem.cksum"))` — the short-circuit pattern zwasm's own
`support/call_profile.zig` documents for exactly this reason. Behaviour with
`ZWASM_DEBUG=mem.cksum` set is unchanged.

Status: local-only. The right fix is an upstream PR to
`github.com/clojurewasm/zwasm` and a version bump here; this file and the
patch exist so the fix survives a `zig-pkg` wipe until then. Related tracked
change that *is* in the repo: `build.zig` passes `target`/`optimize` through
to the zwasm dependency, so release builds stop compiling the interpreter at
zwasm's Debug default.
