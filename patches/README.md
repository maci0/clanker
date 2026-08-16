# Local dependency patches

Patches applied by hand to packages under `zig-pkg/` (which is gitignored and
hash-pinned in `build.zig.zon`). A fresh checkout fetches the pristine
upstream tarball, so **none of these are active on a fresh clone or in CI**
until re-applied or upstreamed. Each entry says what breaks without it.

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
patch (rather than a pinned fork) safe here: a fresh clone and CI build and
pass their tests, they just have one fewer renderer.

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

Status: local-only, and upstreamable as-is. The same commit is pushed to
`github.com/ywy50/libvaxis` on the `sixel-graphics` branch, which is where a
PR to `rockorager/libvaxis` would come from. Until that lands and the pin in
`build.zig.zon` moves, this file is what survives a `zig-pkg` wipe. Regenerate
it from that branch with `git diff 82cec0db..sixel-graphics -- src/`, where
`82cec0db` is the commit `build.zig.zon` pins.

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
tests are not part of `zig build test`); it is there because the same commit
is pushed to `github.com/ywy50/libvaxis` on the `ss3-keypad-enter` branch,
which is where a PR to `rockorager/libvaxis` would come from — same
arrangement as `sixel-graphics` above. Until that lands and the pin in
`build.zig.zon` moves, this file is what survives a `zig-pkg` wipe.
Regenerate it from that branch with
`git diff 82cec0db..ss3-keypad-enter -- src/`, where `82cec0db` is the
commit `build.zig.zon` pins (`zig build test` passes on the branch at that
base).

Status: local-only, upstreamable as-is.

## zwasm-lazy-mem-cksum.patch

Target: zwasm 2.4.1 (`zig-pkg/zwasm-2.4.1-*`). Apply with `patch -p1` inside
that directory.

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
