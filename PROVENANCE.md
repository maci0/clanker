# Change and verification ledger

Append dated changes with their request, evidence, and verification.

## 2026-10-22: license and private security reporting

The user selected GPL-3.0-or-later for Clanker and requested security scanner
enrollment. Added the GPL version 3 text, an explicit or-later grant in
`README.md`, package metadata, and the security mailbox in `SECURITY.md`.
Corrected the undeclared-license statement in `THIRD_PARTY_LICENSES.md`;
third-party licenses remain unchanged. Included the license in Zig package
paths. Verified the license text against the existing Katamaran license and
reviewed the diff. No runtime code changed.

## 2026-10-22: security documentation consistency

Updated `docs/THREAT_MODEL.md` to reference the new private reporting contact;
it previously said `SECURITY.md` was absent. Recorded license, reporting and
ledger ownership in `AGENTS.md`. Evidence: the reporting policy and the
explicit GPL-3.0-or-later grant in `README.md`.

## 2026-10-22: refresh threat-model source locations

The reporting checks found 215 stale references in the existing threat model.
Mapped cited lines from revision `110cc199` to identical source lines in the
current tree and updated the checker's asserted-location keys without changing
their expected text or validation logic. All 532 references now resolve, with
zero skipped or unverified references; all 16 checker tests pass. The mapping
had no unmatched lines. Runtime code and security claims are unchanged.
