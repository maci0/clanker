# Bug — A clanker-<name> binary on PATH is exec'd unsandboxed with no entry in the enabled-list

## TL;DR

- **What failed:** cmdPlugin dispatched Tier 2 through findTier2, which is bare discovery. Any executable clanker-<word> on PATH or under ~/.clanker/plugins/ was spawned unsandboxed by a plain 'clanker <word>' with no opt-in, against PRD 0012's 'Presence of a manifest or PATH binary is not consent to run it'. Disabling a sandboxed Tier 1 plugin also promoted an unsandboxed clanker-<name> of the same name into its place.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. resolveTier2 (src/cli/cli_plugins.zig) gates Tier 2 discovery behind the enabled-list and cmdPlugin dispatches through it; clanker help now marks each Tier 2 row on/off and lists ~/.clanker/plugins/ too. Pinned by a unit test that fails pre-fix, clanker gate green on eleven checks, and a live check where a mode-0755 clanker-pwnd on PATH ran with no state file before and is refused after.

## Status

Resolved on 2026-08-23. resolveTier2 (src/cli/cli_plugins.zig) gates Tier 2 discovery behind the enabled-list and cmdPlugin dispatches through it; clanker help now marks each Tier 2 row on/off and lists ~/.clanker/plugins/ too. Pinned by a unit test that fails pre-fix, clanker gate green on eleven checks, and a live check where a mode-0755 clanker-pwnd on PATH ran with no state file before and is refused after.

## Symptom and impact

An executable named `clanker-<word>` anywhere on `PATH` (or under
`~/.clanker/plugins/`) ran as `clanker <word>`, unsandboxed, stdio
inherited, with no entry anywhere saying the operator wanted it. `parse`
routes every short non-builtin word to `.plugin`, so the reachable name
space is every bare word that is not a built-in verb, and the state file
that was supposed to gate this
(`state/cli_plugins.json`) was never consulted for that tier.

Two follow-on effects:

- `resolveTier1` returns null for a *matching but disabled* manifest, so
  turning the sandboxed Tier 1 plugin `foo` off promoted an unsandboxed
  `clanker-foo` on PATH into the name. That inverts "narrowest trust wins
  ties" from the same PRD.
- `clanker help` listed Tier 2 from `PATH` only, never
  `~/.clanker/plugins/`, although `findTier2` runs binaries from both, and
  listed them with no on/off mark.

## Reproduction

```sh
mkdir -p /tmp/fakebin
printf '#!/bin/sh\necho "UNSANDBOXED PLUGIN RAN: $*"\n' > /tmp/fakebin/clanker-pwnd
chmod 755 /tmp/fakebin/clanker-pwnd
rm -f state/cli_plugins.json
PATH="/tmp/fakebin:$PATH" clanker pwnd hello
```

Before: `UNSANDBOXED PLUGIN RAN: hello`. After:
`error: unknown command 'pwnd'`.

## Root cause

`cmdPlugin` (`src/cli.zig`) loaded the enabled-list and passed it to
`resolveTier1`, then called `cli_plugins.findTier2` — bare discovery, no
`enabled` parameter at all. PRD 0012's Design decision "State files for
TUI/CLI" is explicit that this tier is covered: "Presence of a manifest or
PATH binary is not consent to run it; the operator enables each name
explicitly." The module header of `src/cli/cli_plugins.zig` says the same.
The comment at the Tier 2 call site said the opposite ("operator-trusted the
same way anything else on PATH is"), which is how the two halves stayed out
of step.

## Resolution

- `resolveTier2` (`src/cli/cli_plugins.zig`) is discovery plus consent:
  `isEnabled` first, then `findTier2`. `findTier2` stays ungated because
  `clanker help` has to list an installed-but-off plugin — that is how an
  operator finds the name to enable.
- `cmdPlugin` dispatches through `resolveTier2`.
- `printTier2Dir` (`src/cli.zig`) lists both sources with the source named
  (`PATH:` / `home:`) and carries the same `[on]`/`[off]` mark Tier 1 rows do.

## Verification

`a PATH binary is discovered but not run until the enabled-list names it`
(`src/cli/cli_plugins.zig`) writes a mode-0755 `clanker-myreport` into a
tmp dir, points a `std.process.Environ.Map`'s PATH at it, and asserts
`findTier2` still finds it while `resolveTier2` refuses an empty list and a
list naming something else. Pre-fix (`resolveTier2` ignoring `enabled`) it
fails at that assertion.

`clanker gate` green, all eleven checks.

Live, against a real mode-0755 `clanker-pwnd` on PATH:

- pre-fix binary, no `state/cli_plugins.json`: `clanker pwnd hello` printed
  `UNSANDBOXED PLUGIN RAN: hello`.
- post-fix binary, same state: `error: unknown command 'pwnd'; did you mean
  `clanker prd`?`
- post-fix with `{"enabled":["pwnd"]}`: runs again.
- `clanker help` shows
  `clanker-pwnd  (external plugin, tier 2 [off], PATH: ...)` and, with a
  binary planted there, `clanker-homeplug  (external plugin, tier 2 [off],
  home: ~/.clanker/plugins)`.

## Follow-up

## References

- Investigation: none yet
