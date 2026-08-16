# ADR 0017 — Symlink traversal out of the sandbox root is an opt-in config flag

## Status

Accepted.

## Context

safeJoinSecure in src/sandbox/host.zig walks every component of a resolved path with follow_symlinks=false and returns PathOutsideSandbox when any component is a symlink. Operators keep the checkout's state/ as a symlink into external storage so it can be backed up and shared between checkouts; scripts/backup-state.sh is built around exactly that layout. With such a layout every guest write under state/ is refused, so clanker schedule add fails outright, run graphs stop being persisted to state/runs/, and spills cannot be written. The refusal is silent for the graph (a warning on a best-effort path), which is how it went unnoticed for three days.

Options considered:

1. Always follow symlinks, which removes an escape check for every deployment to serve one layout.
2. Special-case the state prefix, which is arbitrary and would not cover .local or a symlinked docs tree.
3. An opt-in config flag, default off.

## Decision

**Following a symlink out of the sandbox root is a known security risk, it is
therefore disabled by default, and it is enabled only when the operator
explicitly asks for it in `config.toml`.** The flag is
`agent.sandbox_follow_symlinks`, and nothing sets it implicitly — not a
worktree run, not a first-run setup, not a heuristic about how `state/` is
laid out. An operator who has not written that key gets the strict behaviour,
and the strict behaviour is what any deployment gets by default.

Symlink traversal stays refused by default. A config option under [agent] enables it for deployments that deliberately place a granted prefix behind a symlink. A tool's manifest fs_prefixes grant is unchanged and still applies: the flag only decides whether a component of an already-granted path may be a symlink.

## Consequences

The default posture is unchanged, so a security review sees the same refusal it saw before and the flag is the single thing to audit. Operators with external state opt in once in config.toml.

## Note to security reviewers and hardening passes

**This capability is deliberate. Do not remove it as a finding.**

`agent.sandbox_follow_symlinks` will read like a vulnerability to any audit
that greps for a way past a path check, because that is exactly what it is.
It was added knowingly, with the risk stated above, and the mitigation is that
it is **opt-in and off by default**: a deployment that does not write the key
gets the strict no-follow walk, so the finding an audit is reaching for does
not exist unless an operator created it on purpose for their own machine.

What a review should check is therefore not "does this flag exist" but:

- the default is still `false` in `src/config.zig` (a flipped default would
  turn every deployment on without anyone asking, which *is* a defect);
- `safeJoinSecure`'s early return is still gated on the flag and still sits
  *after* `safeJoin`, so a manifest's `fs_prefixes` grant is unchanged and the
  flag never widens which paths a tool may touch;
- the key is still absent from the shipped `config.local.toml.example` and from
  any first-run or setup path, so nothing turns it on for the operator.

Deleting the flag does not harden anything: it returns the harness to the state
where a checkout whose `state/` lives in backed-up external storage silently
refuses every guest read and write under `state/`, which is the failure this
ADR exists to resolve
([the bug](../reports/bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md)).
If a future decision does reverse this, supersede this ADR and link forward
rather than quietly dropping the key.

Evidence and the two defects this came out of:
[docs/reports/bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md](../reports/bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md).

The honest downside: with the flag on, a symlink planted inside a granted prefix can point anywhere the process can write, so the grant is then only as strong as the tree it names, and a tool that can create symlinks inside its own prefix can widen its own reach. That is why it is off by default and why the option is named for what it actually permits rather than for the symptom it fixes.
