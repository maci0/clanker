# Bug — janitor reports removing orphaned staging dirs but large ones survive

## TL;DR

- **What failed:** fsDeleteTree deletes via a truncating ck_fs_list, so a directory with 1800+ entries is only partially deleted; the parent removal then fails silently and janitor reports success anyway.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

`clanker janitor --yes` ran twice within about 10 minutes and both times reported `Excuse me. One moment. / 1.9 GB reclaimable / 3 orphaned staging directories.../ Hold my mop. / Removed 1.9 GB.` The count and phrasing were identical both times, which was the first tell — a real removal should shrink the count on the next scan.

Manually checked `state/staging/` after the second run: three directories from 2026-08-12 (`imp-1786466082217541286`, `imp-1786467023382284242`, `imp-1786472748789843131`) were still present, 438M/465M/477M respectively (`du -sh`), totaling the same ~1.4G `state/staging` reported by `du -sh state/*`. No live improve-self process was running at the time (checked via `ps aux`), and janitor's own `isImpId` classification already treats these as orphaned (that is why they were listed at all).

## Root cause

`fsDeleteTree` in `tools/zig/lib.zig` recursively deletes a tree by calling `fsList` (which wraps `ck_fs_list`), then `fsDelete`-ing every name the listing returned, recursing into subdirectories, and finally calling `fsDelete` on the directory itself. Every step is best-effort: `fsDelete(sub) catch {}` and the final `fsDelete(path) catch {}` both swallow their error.

`ck_fs_list`'s host implementation (`ckFsList`, `src/sandbox/host.zig`, function starts around line 2940) is written for safe *browsing*: it serializes directory entries into a fixed `h.sandbox.max_fs_bytes` buffer and, when a directory has enough entries that the JSON would overflow that buffer, it deliberately stops and returns a truncated-but-valid JSON array instead of failing the whole call. The comment there says exactly that: 'A huge directory must not fail the whole listing: stop at the cap and return a truncated (but still valid JSON) array instead of Err.too_large, so tools always learn at least part of a directory.' That is the right contract for a read.

`fsDeleteTree` was written against a different assumption: that `fsList` returns everything in the directory. When it does not, `fsDeleteTree` deletes only the names in the truncated page, then calls `fsDelete` on the directory itself, which fails with ENOTEMPTY because most of the contents are still there — and that failure is swallowed along with every other one. The caller (`janitor.zig`'s cleanup pass, `.staging => lib.fsDeleteTree(a, c.path)`) never checks whether the directory actually disappeared; it just reports the pre-computed `bytes` figure as reclaimed.

Reproduced on all three orphaned directories: each holds 4000+ files from a full staged build tree (src/, zig-pkg/, .zig-cache/, zig-out/). The worst single subdirectory, `.zig-cache/z` in `imp-1786466082217541286`, has 1848 entries by itself — comfortably enough long cache filenames to overflow one `ck_fs_list` page well before reaching the end of the directory.

## Resolution

Not fixed in code this pass. Worked around the immediate occurrence by deleting the three directories by hand with a plain `rm -rf` outside the sandbox (verified: `state/staging` is 0 bytes afterward). `fsDeleteTree` itself still has the bug.

The fix belongs in `tools/zig/lib.zig`'s `fsDeleteTree`: either loop `fsList` + delete until a listing comes back empty (bounded by a retry cap so a directory that keeps growing under the sandbox's feet cannot loop forever), or have `ck_fs_list` grow a truncation flag in its JSON envelope that `fsDeleteTree` checks and refuses to call the final `fsDelete` on the parent when set. Either way, `janitor.zig`'s report line should reflect what was actually removed, not the pre-scan estimate, so a partial failure like this one is visible instead of reading as success.

## Verification

`state/staging` confirmed empty (`du -sh state/staging` → `0`) after the manual `rm -rf`. The underlying `fsDeleteTree`/`ckFsList` interaction was not changed, so the same failure will recur the next time an orphaned staging directory grows past one `ck_fs_list` page.