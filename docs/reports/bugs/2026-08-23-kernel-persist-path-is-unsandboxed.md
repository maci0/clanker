# Bug — Production kernel cells run unsandboxed while ADR 0010 specifies a WASI sandbox

## TL;DR

- **What failed:** ck_kernel reaches a plain host python3 supervisor (src/sandbox/kernel.zig). runPythonCell and runPythonCellSandboxed, the WASI-confined functions ADR 0010 calls the primary Python path, have no production caller: only their own test. Every cell runs with the harness's full filesystem and network access, exec_allow applies to neither %%bash nor subprocess, and the deprecation warning the ADR promises never fired. Unfixed: WASI here is one-shot, and the kernel exists to keep __main__ across cells.
- **Impact:** An operator who turns `kernel.enabled` on gets arbitrary code execution with the harness process's full ambient permissions, while ADR 0010 and the config docs tell them it is WASI-confined with fuel, memory and timeout limits. Not a regression: it has never been sandboxed on this path.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

`kernel.enabled = true` plus a `kernel` tool call runs the cell in a host
`python3` process that inherits everything the clanker process can reach: the
whole filesystem, the network, and every binary on PATH. `%%bash` runs
`bash -c <body>` with no policy consulted, and a plain cell can do the same with
`import subprocess` without going near the bash route.

What makes it a defect rather than a documented trade-off is that the documents
say otherwise. ADR 0010, revised 2026-08-14, states that the Python kernel "runs
under a real WASM/WASI sandbox" and that "a configured Python kernel is bounded
by the sandbox, not by config + confirm alone: fuel/memory/timeout traps replace
'the sandbox does not bound this' as the actual answer to 'what stops a runaway
cell.'" `src/config.zig:632` repeats the framing. An operator reading either one
and enabling the kernel gets a materially different posture than the one they
were promised, with nothing at runtime to correct them.

The ADR also promises that the unsandboxed fallback "logs a deprecation warning
naming the setup script". That warning lives in `runPythonCell`, which nothing
calls, so until the change that filed this record it never fired.

## Reproduction

Deterministic, no model needed. `test "every kernel reply states that this path
is unsandboxed, and it really is"` in `src/sandbox/kernel.zig` runs a cell
through the shipped `eval` and asserts the process really does reach a shell:

- `{"bash": "echo AMBIENT-SHELL-REACHED"}` returns that text in `stdout`.
- `{"cell": "import subprocess; subprocess.run([...])"}` returns `ok:true`.

Neither consults `exec_allow`, and the second does not use the `%%bash` route at
all.

The dead-code half is a two-command check:

```
grep -rn "runPythonCell" src/
```

Every hit is the definition, its two helpers, `src/config.zig`'s comment, or the
test at `src/sandbox/host.zig:2159`. The production entry point is `ckKernel`
(`src/sandbox/host.zig:1897`), which calls `kernel_mod.eval` and never
`runPythonCell`.

## Root cause

Two functions that both claim to be "the Python kernel", only one of which is
wired up.

`runPythonCell` / `runPythonCellSandboxed` implement ADR 0010: a WASI
interpreter under zwasm with fuel, memory and timeout limits, one preopen. They
run a **one-shot** cell.

`kernel_mod.eval` implements PRD 0016: a persistent supervisor holding
`__main__` across cells. It is a real subprocess with no confinement.

Cross-cell persistence is the reason the kernel exists ("Python state persists
across calls in the same session", a checked PRD 0016 criterion), and a one-shot
WASI cell cannot provide it. So the persist path could never have adopted the
sandboxed function, and the ADR revision that declared WASI primary described an
intent rather than the code. The passing test on `runPythonCell` is what kept it
looking live: a green test on a path production never takes.

## Resolution

**Open. Not fixed.**

What landed alongside this record is honesty, not confinement, and it must not
be mistaken for a fix:

- every reply from `eval` now carries `"sandboxed": false` and a
  `sandbox_warning` naming the exposure, so a caller can see the posture;
- starting a supervisor logs the warning that ADR 0010 always promised and that
  never fired;
- ADR 0010, PRD 0016 and `src/config.zig` now say the WASI functions are
  test-only and that the persist path is unsandboxed.

The kernel is not safer than it was yesterday. It is only no longer
misdescribed.

Real fixes, none of them small, and none chosen here:

1. **A confined persistent interpreter.** A WASI CPython kept resident across
   cells rather than re-entered per cell. This is the one that keeps both the
   PRD's persistence and the ADR's confinement, and it is the most work: the
   current `python_wasi.run` is a one-shot by construction.
2. **OS-level confinement of the supervisor.** Sandbox the subprocess itself
   (seatbelt/`sandbox-exec` on macOS, seccomp plus namespaces on Linux), so the
   ambient permissions shrink without changing the interpreter. Platform
   specific, and cgroup quotas are already listed in ADR 0010 as a
   pre-default-on requirement.
3. **Route guest-initiated exec through `ck_exec`.** Would put `exec_allow` back
   in the path for `%%bash`, but on its own it is not a boundary while
   `import subprocess` is in scope in the same process, so it is only worth
   doing as part of (1) or (2).

Note that enforcing `exec_allow` on `%%bash` alone was the shape this was
originally going to be fixed in, and it was rejected for that reason. PRD 0016
now records it as a non-goal with the reason attached rather than as an
unchecked box.

## Verification

Nothing here claims the defect is fixed, so there is nothing to verify about a
fix. What is verified, and how:

- That the WASI functions have no production caller: read at `src/sandbox/host.zig`
  and confirmed by grep, not inferred from behaviour.
- That the production path is the unsandboxed supervisor: read from `ckKernel`
  (`src/sandbox/host.zig:1897`) through `kernel_mod.eval`.
- That the process really has ambient access: asserted by the reproduction test
  above, which runs a real `python3`. It skips where `python3` is absent.
- That the reply labelling and the supervisor warning work: same test, which
  fails on the parent commit because neither existed.

The test is deliberately written so that **confining this path breaks it.** That
is the intent: whoever does the real fix is forced to update the notice, the
ADR and the test together, instead of leaving a stale warning claiming an
exposure that no longer exists.

## Follow-up

- ADR 0010 needs a decision, not just the correction it got: either supersede
  the WASI-primary framing or commit to option 1 above.
- `runPythonCell`, `runPythonCellSandboxed` and `src/sandbox/python_wasi.zig`
  are dead outside tests. They should be either wired up or deleted; keeping an
  unreferenced sandbox implementation around is how this divergence stayed
  invisible.

## References

- Investigation: none. The divergence was clear from the two call graphs, so no
  tracing record was needed.
- [ADR 0010](../../adrs/0010-kernels-are-an-opt-in-unsandboxed-class.md) — the
  document this contradicts.
- [PRD 0016](../../prds/0016-eval-kernel.md) — already carried the contradiction
  under Known issues; that entry is what this record was opened from.
- `src/sandbox/kernel.zig` — the unsandboxed supervisor that ships.
- `src/sandbox/host.zig` — `ckKernel` (production) and `runPythonCell` (not).
## Update 2026-08-23 — still open; two slices off it have landed

This record stays **Open**. The kernel is still an unsandboxed host `python3`
with the harness's filesystem and network reach, and none of the three real
fixes above has been done. Two things that were part of the exposure have been
split off and fixed, and neither should be read as progress toward
confinement:

- **The documents this record says lie now do not.** The correction of
  2026-08-23 reached `src/config.zig`, ADR 0010 and PRD 0016 but missed
  `tools/manifests/kernel.tool.json` (both `description` and
  `llm_description`, so the *model* was still being told cells run
  WASI-sandboxed), `config.toml`'s `[kernel]` comment, and
  `docs/configuration.md`. All three now state the real posture.
- **A cell's environment is now the guest's own `env_allow` set.** `eval`
  spawned with no `environ_map`, so it was whatever the `Io` carried -- two
  variables and no `HOME` in practice, and every harness key on an `Io` that
  inherits. `ckKernel` now passes `execEnvironment`, the same filter `ck_exec`
  and `ck_job` use. Own record:
  [the supervisor's environment was unspecified](2026-08-23-kernel-supervisor-environment-is-unspecified.md).

What that leaves is exactly the substance of this record: a cell has arbitrary
code execution in a process with the harness's ambient filesystem and network
access, and `exec_allow` reaches neither `%%bash` nor `import subprocess`. The
credential surface is narrower; the confinement surface is unchanged.

The posture test still asserts the exposure is real, and confining this path
still breaks it on purpose.