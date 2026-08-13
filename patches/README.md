# Local dependency patches

Patches applied by hand to packages under `zig-pkg/` (which is gitignored and
hash-pinned in `build.zig.zon`). A fresh checkout fetches the pristine
upstream tarball, so **none of these are active on a fresh clone or in CI**
until re-applied or upstreamed. Each entry says what breaks without it.

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
