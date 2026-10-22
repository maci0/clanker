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

## 2026-10-22: isolate process-registry test cleanup

The enrollment build reproduced a SIGTERM failure in `clanker gate` after
the direct test run passed. A syscall trace showed the unit-test executable
calling `kill(42, SIGTERM)`; PID 42 was a build-runner thread in that container.
The `register and get by session+kind` fixture registered that numeric PID,
and registry teardown signaled it. Replaced numeric PID fixtures in
`src/agent/subprocess.zig`, `src/cli.zig`, and `src/sandbox/kernel.zig` with
owned child processes, retaining the existing assertions and bounded cleanup.
Production functions are unchanged. Updated shifted source citations and
recorded the fixture ownership rule in `AGENTS.md`; all 532 citations and
16 checker tests pass. Full candidate gate verification is recorded below
when complete.

## 2026-10-22: deterministic file-view test imports

After isolating registry cleanup, the full gate completed 2,587 native tests
with seven skips but exposed a file-view fixture failure. Three renders used
`Date.now()` in their import URLs; two calls within one millisecond reused the
module cache and never registered the view in the new test registry. Replaced
the timestamp with a monotonically increasing render ID in
`ui/plugins/files/icons.test.mjs`. Existing rendering assertions are unchanged.

The lint gate rejects mutable module-level setup outside a test hook, so the
import URL now uses `crypto.randomUUID()` instead of a shared counter. It
retains unique imports without adding shared fixture state.

## 2026-10-22: fixture verification

The candidate passed all 16 `clanker gate` checks and `zig build e2e -j2`
with networking disabled, two CPUs and 8 GiB RAM (container exit 0).
Formatting and all 532 citation checks passed; the 16 checker tests passed.
The file-view suite passed 20 consecutive runs, and JavaScript lint and types
passed without changing the lint baseline. Verification used read-only mounts
of the candidate files over the cached enrollment environment. No production
code, live provider, real credentials, or production service was exercised.
