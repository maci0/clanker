# Bug — janitor reports removing orphaned staging dirs but large ones survive

## TL;DR

- **What failed:** fsDeleteTree deletes via a truncating ck_fs_list, so a directory with 1800+ entries is only partially deleted; the parent removal then fails silently and janitor reports success anyway.
- **Impact:** Orphaned staging directories from killed improve runs (~1.4 GB observed) survived every `clanker janitor --yes` while its output claimed they were reclaimed, so the disk kept filling behind a green report.
- **Resolution:** Resolved — fsDeleteTree re-lists until a listing comes back empty (52828dbd), janitor re-stats each staging directory and refuses to credit a survivor's bytes (9417997a), and a sandbox runtime test now pins the multi-page case.

## Status

Resolved on 2026-08-21. Fixed on main by 52828dbd (fsDeleteTree loops list-and-delete passes, capped at `fs_delete_tree_max_passes`) and 9417997a (janitor's prune re-stats after fsDeleteTree; a survivor counts as failed). Verified by the new runtime test below.

## Symptom and impact

`clanker janitor --yes` ran twice within about 10 minutes and both times reported `1.9 GB reclaimable / 3 orphaned staging directories... / Removed 1.9 GB.` The count and phrasing were identical both times, which was the first tell — a real removal should shrink the count on the next scan.

Manually checked `state/staging/` after the second run: three directories from 2026-08-12 (`imp-1786466082217541286`, `imp-1786467023382284242`, `imp-1786472748789843131`) were still present, 438M/465M/477M respectively (`du -sh`), totaling the same ~1.4G `state/staging` reported by `du -sh state/*`. No live improve-self process was running at the time (checked via `ps aux`), and janitor's own `isImpId` classification already treats these as orphaned (that is why they were listed at all).

## Reproduction

Pinned by the runtime test "janitor prune removes a staging tree larger than one ck_fs_list page" (`src/sandbox/runtime.zig`): a staging directory with 60 files under a Sandbox whose `max_fs_bytes` is 256 makes one `ck_fs_list` page hold only a fraction of the entries; before the fix the tree survived its own deletion.

## Root cause

`fsDeleteTree` in `tools/zig/lib.zig` recursively deleted a tree by calling `fsList` (which wraps `ck_fs_list`) once, `fsDelete`-ing every name the listing returned, recursing into subdirectories, and finally calling `fsDelete` on the directory itself — every step best-effort, every failure swallowed.

`ck_fs_list`'s host implementation (`ckFsList`, `src/sandbox/host.zig`) is written for safe *browsing*: it serializes directory entries into a fixed `h.sandbox.max_fs_bytes` buffer and, when a directory has enough entries that the JSON would overflow that buffer, deliberately stops and returns a truncated-but-valid JSON array instead of failing the whole call. The right contract for a read — and the wrong assumption for a delete. When the listing truncated, `fsDeleteTree` deleted only the first page, the parent `fsDelete` failed ENOTEMPTY, that failure was swallowed, and janitor's cleanup pass reported the pre-computed `bytes` figure as reclaimed regardless.

Observed on three orphaned directories, each holding 4000+ files from a full staged build tree; the worst single subdirectory (`.zig-cache/z`) had 1848 entries, comfortably enough to overflow one `ck_fs_list` page.

## Resolution

- 52828dbd: `fsDeleteTree` loops list-and-delete passes until the parent `fsDelete` succeeds, bounded by `fs_delete_tree_max_passes` (64) so a directory growing under the sandbox's feet cannot loop forever. Each pass clears at least one full listing page.
- 9417997a: janitor's prune pass re-stats a staging directory after `fsDeleteTree`; a directory that is still there counts as failed and its bytes stay out of the reclaimed figure, so a partial failure is visible instead of reading as success.
- This change adds the regression test pinning the truncated-page case end to end through the janitor wasm tool.

## Verification

`zig build test` runs "janitor prune removes a staging tree larger than one ck_fs_list page" (`src/sandbox/runtime.zig`): 60 files, `max_fs_bytes = 256` (several listing pages), prune must leave `state/staging/imp-123` absent and report no "could not be removed". Immediate occurrence was cleared by hand earlier with `rm -rf` outside the sandbox (`state/staging` → 0 bytes).

## Follow-up

- `ck_fs_list` still has no truncation flag in its JSON envelope; callers that need completeness must loop like `fsDeleteTree` does. Worth a flag if a second looping caller appears.

## References

- Investigation: none — root cause was traced directly in this report.
- Fixed by 52828dbd (tools/zig/lib.zig) and 9417997a (tools/zig/janitor.zig).
