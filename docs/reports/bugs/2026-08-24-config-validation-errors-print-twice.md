# Bug — Every config validation error is printed twice, once by the startup dotenv probe

## TL;DR

- **What failed:** loadQuiet suppresses only logTomlSyntaxError/logDiagnostic/logUndiagnosedError; the dozens of direct log.log(.error_) calls in the provider/model validators and in loadInner bypass diagnostics_suppressed, so the speculative dotenv-probe load prints each one and the real load prints it again. In clanker doctor the second copy lands inside the report body, between the [ok] config.toml line and the [FAIL] config parses line.
- **Impact:** Noise, not a wrong answer -- the command still fails with the correct error and hint. `clanker doctor` is the exception worth naming: the second copy lands inside its report, between the `[ok  ] config.local.toml` line and the `[FAIL] config parses` line, so the section reads as two separate failures.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Every operator-facing config validation error is printed twice, verbatim, on
the same millisecond. `src/config.zig`'s `loadQuiet` exists to prevent exactly
this -- its docstring says "Suppressing this speculative read prevents printing
every diagnostic twice when configuration is invalid" -- but the suppression
covers only three helpers.

Impact is noise, not a wrong answer: the command still fails with the right
error and the right hint. Two places where it is worse than noise:

- `clanker doctor` renders a report, and the second copy lands *inside* it,
  between the `[ok  ] config.local.toml` line and the `[FAIL] config parses`
  line it is about. The section reads as if two different things failed.
- The duplicate is byte-identical, so a reader looking at one line of the pair
  cannot tell which load produced it, and a log collector counts each
  invalid-config startup twice.

## Reproduction

In an empty directory, a `config.toml` naming a `default_provider` that no
`[providers.*]` declares:

```bash
mkdir /tmp/dupcheck && cd /tmp/dupcheck
printf 'default_provider = "nope"\n\n[providers.a]\nbase_url = "https://a.test"\n\n[models."a/m"]\nprovider = "a"\n' > config.toml
clanker sessions
```

Observed on 6a7de0cd (macos/aarch64):

```
[ERROR] ts_ms=1787559699744 default_provider 'nope' is not in "providers"
[ERROR] ts_ms=1787559699744 default_provider 'nope' is not in "providers"
error: default_provider names a provider not in config; run `clanker doctor`
```

A provider with no models is the same shape, and `clanker doctor` is where it
reads worst:

```
[ERROR] ts_ms=1787559748197 provider 'b': no models declared (add a [models."b/<name>"] entry)
clanker doctor 0.1.0 (macos/aarch64)

config
  [ok  ] config.toml
  [ok  ] config.local.toml
[ERROR] ts_ms=1787559748198 provider 'b': no models declared (add a [models."b/<name>"] entry)
  [FAIL] config parses              ProviderMissingModel
```

`--help` and `--version` are exempt (`src/main.zig` skips the probe for both),
and `--dump-config` returns before it, so those three print one copy.

## Root cause

`src/main.zig` loads the config twice on purpose: once speculatively through
`Config.loadQuiet`, to read `modules.dotenv` before deciding whether to load
`.env`, and then again inside `cli.run` for the command itself. `loadQuiet`
sets `diagnostics_suppressed` around its load to keep the speculative pass
silent.

Only three functions consult that flag -- `logTomlSyntaxError`,
`logDiagnostic` and `logUndiagnosedError`. Every other operator-facing config
error is a direct `log.log(.error_, ...)` call that never reads it: roughly
forty of them across `parseProvider`, `distributeModels`,
`validateProviderModels`, `validateModelRanges`, `parseAgent`,
`parseMcpServers`, `validateToolResultPrune`, `validateRepeatToolThresholds`,
plus `loadInner`'s own `no providers defined` warning and
`default_provider '...' is not in "providers"`. `warnUnknownKeys` is ungated
too, so an unknown key warns twice as well.

So the split is not "which layer failed" but "which helper happens to route
through the gate", and the errors an operator is most likely to hit -- an
undeclared provider, a provider with no models -- are all on the ungated side.

## Resolution

Open. Two shapes, unverified which is better:

- Gate at the sink: have `log` calls in this file go through one helper that
  returns early on `diagnostics_suppressed`, the way `logDiagnostic` does.
  That is ~forty call sites, but it makes the flag mean what its name says
  and a new validator cannot regress out of it.
- Gate at the source: make the speculative pass not log at all, e.g. by
  reading `[modules] dotenv` with a parse that stops before validation. The
  probe wants one boolean and throws the rest away, so most of what it
  validates is work it does not need either.

Whichever is chosen, the check is that the count drops to one and the
`--dump-config` / `--help` / `--version` paths still print exactly one.

## Verification

Not fixed, so nothing verified. What was verified is the claim above: the
reproduction was run against the tree at 6a7de0cd, and the three gated helpers
were established by `grep -n "if (diagnostics_suppressed) return" -B 3
src/config.zig`, which names `logTomlSyntaxError`, `logDiagnostic` and
`logUndiagnosedError` and nothing else.

## Follow-up

Found while fixing PRD 0042's `--profile` edges (PR #389). The new
`--profile names <path>, which does not exist` diagnostic added there *is*
gated on `diagnostics_suppressed`, precisely so it would not join this set --
so a missing profile prints one line while an undeclared provider beside it
prints two. That asymmetry is this report, not that fix.

## References

- Investigation: none yet
