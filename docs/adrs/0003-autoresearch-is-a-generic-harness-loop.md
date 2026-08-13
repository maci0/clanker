# ADR 0003 — Autoresearch is a generic harness loop

## Status

Accepted. Shipped as [PRD 0004 — Autoresearch](../prds/0004-autoresearch.md);
the implementation is `src/research/autoresearch.zig`, `src/research/ledger.zig`
and `src/research/harness.zig`.

## Context

[karpathy/autoresearch](https://github.com/karpathy/autoresearch) demonstrates
the shape: an unattended loop that proposes a change, measures one scalar, and
keeps the change only if the number moved the right way. The reference
implementation is deliberately narrow: one file under optimization, one metric,
GPU kernels as the domain.

Clanker already had most of that loop's machinery, built for a different
purpose. The self-improve engine (`src/improve/engine.zig`) proposes patches,
validates which files a proposal may touch (`validatePath` in
`src/improve/proposal.zig`), applies them through the sandboxed `patch_apply`
tool against a staged copy, and gates on a measurement before accepting. Those
pieces are exactly what an experiment loop needs, and they are also where the
anti-cheat guarantees live: a proposal cannot write outside its declared
targets, and "improved" is decided by running the thing and reading a number,
not by asking the model whether it improved.

Three options:

- **Copy the reference design narrowly.** A standalone loop for one fixed
  domain would reuse none of the proposal validation or the sandboxed patch
  path, so it would either re-implement the anti-cheat properties or ship
  without them. And clanker has no reason to privilege GPU kernels: the
  interesting contract is "any command that emits a scalar".
- **Extend the self-improve engine.** The improve loop's job is changing
  clanker's own source under its own gates; an experiment's target is
  arbitrary user files measured by an arbitrary harness command. Folding both
  into one engine means every improve-engine invariant (allowed surface, gate
  policy, staging conventions) grows an "unless this is a research run"
  branch, which is how invariants stop being invariants.
- **A generic sibling loop.** `src/research/` gets its own state
  (`state/autoresearch/<run-id>/`), its own CLI (`clanker autoresearch`), and
  its own read-only WASM tool, while reusing the improve engine's loop shape
  and idioms (`parseProposal`, `validatePath`, `patch_apply` against a staged
  copy) rather than forking them. Same guarantees, no shared mutable
  machinery, no cross-contamination of invariants.

## Decision

Autoresearch is a generic sibling loop in `src/research/`, neither an
extension of the self-improve engine nor a port of the reference design. The
harness contract is the whole of the domain coupling: any shell command that
exits 0 and emits one scalar metric, either as `<pattern><number>` in its
output or as a `metric.json` file (`src/research/harness.zig`'s
`extractMetric`). Proposal parsing, path validation and patch application are
borrowed from the improve engine, so the anti-cheat properties are inherited
rather than re-derived. State, CLI surface and the results-reading tool are
the loop's own.

## Consequences

Makes easy: the loop works for any domain that can phrase itself as
`command -> scalar`, with no per-domain code. The anti-cheat posture is
preserved for free: an iteration can only touch files named in `--target`,
every change goes through the sandboxed patch tool against a staged copy, and
the ledger records every iteration, pass or fail, in an append-only file a
human can read in the morning.

Makes hard: the reuse is real coupling. `src/improve/proposal.zig` now has
two consumers, so a change to the proposal format or to `validatePath` must
consider both loops, and a reader of `state/` has to know which engine a
given run directory belongs to. That is the price of inheriting the
guarantees instead of copying them, and it is the cheaper direction to be
wrong in: a copy would have drifted silently.

Two items this ADR originally deferred have since been resolved
(`docs/ROADMAP.md`'s autoresearch entry records the phases as done): web UI
ledger visibility shipped as the read-only `autoresearch` WASM tool, callable
from any agent conversation including one in the web UI, with a dedicated web
UI page made an explicit non-goal in PRD 0004; and parallel experiments via
swarm did not ship and were likewise settled by PRD 0004 as a non-goal, with
iterations running strictly sequentially in one process. What remains open is
tracked in the PRD's Known issues (an unenforced `--budget`, an empty `best/`
directory), not here.
