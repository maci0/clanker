# Runbook — A worktree's linked state entry was replaced by a private copy

## TL;DR

- **Use when:** clanker doctor's worktree links section FAILs state/improvements.jsonl or state/history: the symlink back to the main checkout is now a regular file, so every write from that worktree lands in a copy nobody else reads and is thrown away with the worktree. Recovery is to merge the copy's own lines back into the shared file and re-create the link.
- **Recover by:** Merging the copy's own lines into the main checkout's file, deleting the copy, and re-creating the symlink.
- **Verify with:** `clanker doctor` in the worktree: the entry reads `[ok] ... links to <checkout>/<path>`.

## Scope and preconditions

Applies to a linked git worktree — one whose `.git` is a FILE naming a main
checkout — where `linkSharedState` (an improve-self worktree) or
`clanker worktree prepare` (a hand-made one) put a symlink and a regular file
is there now.

The two lists of names are in `src/improve/worktree.zig`:
`shared_state_link_names` is `state/improvements.jsonl` and `state/history`,
`local_config_names` is `.env` and `config.local.toml`. Only the first pair is
reported as a failure; a worktree may legitimately hold its own copy of the
second, since `prepareLinked` never overwrites an existing name.

Do this while no run is using the worktree. The recovery rewrites the main
checkout's shared file, and a live improve run appending to the copy at the
same time will strand whatever it writes after the read.

## Diagnose

```bash
clanker doctor
```

A detached entry prints under `worktree links` with the path it should point
at:

```
[FAIL] state/improvements.jsonl   a private copy, not a link to /home/y/code/clanker/state/improvements.jsonl: every write lands in a copy thrown away with the worktree
```

`state/history` beside it is the control. It is a *directory* link and nothing
renames over a directory, so it normally survives; the pair disagreeing is the
signature of this failure, and it is what identified the original defect in ten
worktrees at once.

## Recover

`clanker` has no symlink verb — creating a link is a host job the guest ABI
deliberately does not expose ([ADR 0017](../adrs/0017-sandbox-symlink-traversal-is-opt-in.md))
— so this half is shell.

Take the copy's own lines first. This is the comparison the ledger bug used:
every line the worktree copy has that the shared file does not.

```bash
grep -Fvx -f /path/to/checkout/state/improvements.jsonl state/improvements.jsonl
```

Append what that printed to the main checkout's file:

```bash
grep -Fvx -f /path/to/checkout/state/improvements.jsonl state/improvements.jsonl >> /path/to/checkout/state/improvements.jsonl
```

Line counts are not the whole answer. A whole-file rewrite can also change
lines the two files share — `markReverted` flipping `"status":"accepted"` to
`"status":"reverted"` is what broke the link in the first place, and that edit
adds no lines at all. Diff the shared prefix and carry any such flip across by
hand before continuing:

```bash
diff /path/to/checkout/state/improvements.jsonl state/improvements.jsonl
```

Then replace the copy with the link it should have been:

```bash
rm state/improvements.jsonl
ln -s /path/to/checkout/state/improvements.jsonl state/improvements.jsonl
```

## Verify

```bash
clanker doctor
```

The entry now reads as a link, and the target printed is the main checkout's
file:

```
[ok  ] state/improvements.jsonl   links to /home/y/code/clanker/state/improvements.jsonl
```

Nothing of the copy is left unmerged:

```bash
grep -Fvx -f /path/to/checkout/state/improvements.jsonl /path/to/checkout/state/improvements.jsonl
```

## Escalate or follow up

A link that detaches *again* after this is a live defect, not a leftover.
`atomic_write.writeFile` resolves a leaf symlink before renaming, so a writer
that goes through it cannot cause this; a writer that renames onto the name
some other way can. Find what wrote the file and file the report:

```bash
clanker reports create bug <YYYY-MM-DD-slug> "<title>" "<TL;DR>"
```

## References

- Report: [The improve ledger is written to a worktree copy that is never merged back](../reports/bugs/2026-08-17-improve-ledger-written-to-a-worktree-copy.md)
  — the original instance, its mechanism, and the recovery this procedure is
  drawn from.
- Runbook: [hand-made-worktree-has-no-local-config](hand-made-worktree-has-no-local-config.md)
  — the neighbouring failure, where the names were never linked at all.
- Code: `src/improve/worktree.zig` (`linkSharedState`, `prepareLinked`,
  `local_config_names`, `shared_state_link_names`), `src/doctor.zig`
  (`checkWorktreeLinks`), `src/util/atomic_write.zig` (`writeFilePerms`).
