# Bug — rfc create writes a seeded research link that does not resolve

## TL;DR

- **What failed:** renderSeededOptions in tools/zig/rfc.zig formatted the seeded link as [{s}]({s}) over relativeToRfcs, which only strips the docs/ prefix, so a create passing docs/research/x.md wrote (research/x.md) into docs/rfcs/<n>-<slug>.md. That resolves to docs/rfcs/research/x.md and is dead. The References line in the same create formats its own ../ and was always right.
- **Impact:** Latent. No RFC in docs/rfcs/ carried the dead link on 2026-08-22; every RFC seeded from a research note after that would have.
- **Resolution:** Resolved on 2026-08-22. Fixed in tools/zig/rfc.zig: renderSeededOptions writes (../{s}). Verified by re-running clanker rfc create with a research note and resolving the target path.

## Status

Resolved on 2026-08-22. Fixed in tools/zig/rfc.zig: renderSeededOptions writes (../{s}). Verified by re-running clanker rfc create with a research note and resolving the target path.

## Symptom and impact

An RFC created with a research note carries a "Seeded from" line at the top of
its Options considered section. The link in that line does not resolve: it
points one directory below `docs/rfcs/` instead of across to `docs/research/`.

Impact is latent rather than observed. `grep -rn "](research/" docs/rfcs/*.md`
over the tree on 2026-08-22 returned no shipped RFC, so no record in the store
carries the dead link today; every RFC created from a research note from now on
would have carried it.

## Reproduction

    clanker rfc create "Probe" "Probe overview" probe docs/research/decentralized-state-store.md
    grep -n "Seeded from" docs/rfcs/0036-probe.md

Before the fix the href read `research/decentralized-state-store.md`.

## Root cause

`renderSeededOptions` in `tools/zig/rfc.zig` formatted the href as `({s})` from
`relativeToRfcs(research_path)`, and `relativeToRfcs` only strips the `docs/`
prefix — its own comment claimed it produced `../research/x.md`. The
References line the same `create` writes formats `../research/{s}` itself and
was therefore always correct, which is why the two links in one generated
document disagreed.

## Resolution

The format string in `renderSeededOptions` now writes `(../{s})`, and
`relativeToRfcs` says in its doc comment that the caller supplies the `../`.

## Verification

Rebuilt with `zig build tools`, re-ran the reproduction, and the href read
`../research/decentralized-state-store.md`. `ls
docs/rfcs/../research/decentralized-state-store.md` resolved the target. The
probe RFC and its inventory row were reverted afterwards.

## Follow-up

The seeded link has no unit test: `relativeToRfcs` and `renderSeededOptions`
are private to a WASM guest, which cannot run `test` blocks. The check above is
by running the verb.

## References

- Investigation: none yet
