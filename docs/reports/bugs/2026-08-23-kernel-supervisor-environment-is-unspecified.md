# Bug — The kernel supervisor's environment was whatever the Io carried, not a policy

## TL;DR

- **What failed:** eval spawned the persistent python3 supervisor with no environ_map, which std.process.spawn reads as 'whatever the Io implementation carries'. Live, a cell saw two variables and no HOME or PATH, while ck_exec and ck_job hand their children host.execEnvironment's filtered map. A cell's environment was an accident, and on an Io that does inherit it would carry every key the harness loaded.
- **Impact:** A Python cell had no `HOME`, `PATH`, `TMPDIR`, `LANG` or `USER`, so anything reading them, and any child it started that needed a `PATH`, behaved differently inside a cell than the same code anywhere else. The confinement half is latent rather than observed: nothing leaked on this `Io`, because it carried almost nothing.
- **Resolution:** Resolved on 2026-08-23. EvalOpts.environ_map is now required and non-optional, and ckKernel supplies execEnvironment(gpa, sandbox) -- the same envAllowed filter ck_exec and ck_job use. The manifest (both descriptions), config.toml and docs/configuration.md now state the real posture. Pinned by 'a cell's environment is exactly the one the caller named' in src/sandbox/kernel.zig, which gives [None, None, False] when the spawn passes null. Live: [2,[],False] before, [7,[],True,True] after. Not a confinement fix.

## Status

Resolved on 2026-08-23. EvalOpts.environ_map is now required and non-optional, and ckKernel supplies execEnvironment(gpa, sandbox) -- the same envAllowed filter ck_exec and ck_job use. The manifest (both descriptions), config.toml and docs/configuration.md now state the real posture. Pinned by 'a cell's environment is exactly the one the caller named' in src/sandbox/kernel.zig, which gives [None, None, False] when the spawn passes null. Live: [2,[],False] before, [7,[],True,True] after. Not a confinement fix.

## Symptom and impact

A Python cell could not see the environment. `os.environ` held two entries,
both contributed by the platform (`LC_CTYPE` and `__CF_USER_TEXT_ENCODING` on
macOS), and neither `HOME` nor `PATH` was among them.

Nothing failed loudly, which is why it went unnoticed: `python3` itself is
resolved from the *parent* environment by `std.process.spawn`, and a child a
cell starts with no `PATH` falls back to `confstr(_CS_PATH)`, so `%%bash` and
`subprocess.run(["echo", ...])` both still worked. What broke was anything a
cell read out of its own environment.

The confinement half of this is **latent, not observed.** `std.process.spawn`
documents a null `environ_map` as "inherit", and on an `Io` whose captured
environment is populated this call site would have handed the supervisor every
key the harness holds -- including the API keys `ck_env` denies the guest that
started the cell. That did not happen here. It was one `Io` away from
happening, and it was not anybody's decision either way, which is the actual
defect.

## Reproduction

Found live while checking whether the kernel leaked credentials -- the answer
turned out to be the opposite problem. With `kernel.enabled = true`:

```bash
FAKE_PROBE_API_KEY=sk-not-a-real-key clanker run --model deepseek-v4-flash \
  "Use the kernel tool once with the cell: import os
[len(os.environ), os.environ.get(\"FAKE_PROBE_API_KEY\"), os.environ.get(\"HOME\") is not None]"
```

Before: `[2, None, False]`. The variable was not leaked, and `HOME` was not
there either.

Deterministically, `test "a cell's environment is exactly the one the caller
named"` in `src/sandbox/kernel.zig`.

## Root cause

`ensureSupervisor` (`src/sandbox/kernel.zig`) spawned with no `environ_map`:

```zig
var child = std.process.spawn(opts.io, .{
    .argv = &.{ opts.python, "supervisor.py" },
    .cwd = opts.cwd,
    .stdin = .pipe,
```

`std.process.spawn` treats a null `environ_map` as "replace nothing", and
`Io.Threaded` then falls back to its own `environ.process_environ` -- which is
empty unless whoever built the `Io` populated it. So the answer to "what may a
cell see" came from the `Io` construction, three layers away from the tool
whose policy it is.

Every other child a guest causes to exist goes through
`host.execEnvironment(gpa, sb)`, the `envAllowed` filter: empty `env_allow`
means the safe defaults (`PWD`, `HOME`, `PATH`, `LANG`, `LC_ALL`, `TERM`, `TZ`,
`USER`) and never a credential. `ck_exec` does it, and `ck_job` was fixed to do
it after spawning with the full harness environment. The kernel did neither.

Alongside it, three documents still described a posture the kernel does not
have -- and one of them is model-visible:

- `tools/manifests/kernel.tool.json`, both `description` and
  `llm_description`: "Python cells run sandboxed under the WASI CPython from
  scripts/setup-python-wasi.sh when it is present ... without it they fall back
  to a deprecated unsandboxed python3 subprocess". The model reads this.
- `config.toml`'s `[kernel]` comment, which an operator reads before flipping
  `enabled`.
- `docs/configuration.md`'s `[kernel]` section.

`src/config.zig`, ADR 0010 and PRD 0016 were corrected on 2026-08-23; these
three were missed, so the correction had not reached either the model or the
operator.

## Resolution

Fixed.

`EvalOpts.environ_map` is now a required, non-optional
`*const std.process.Environ.Map`, and `ensureSupervisor` passes it. Required
rather than defaulted on purpose: the defect was an unstated policy, so a
caller that does not say what a cell may see should not compile. An empty map
is a legitimate answer; silence is not.

`ckKernel` (`src/sandbox/host.zig`) supplies `execEnvironment(gpa, sandbox)`,
so a cell now sees exactly the `kernel` tool's `env_allow` set, which is the
same rule as `ck_exec` and `ck_job`. `runPythonCellUnsandboxed` in the same
file got it too -- it has no production caller, but a spawn there that left the
environment to the `Io` would be this defect ready-made for whoever wires it
up.

The three documents now say what the code does, including that naming anything
in `env_allow` *replaces* the default set rather than adding to it, which is
the trap an operator who needs one extra variable will otherwise hit.

This is **not** a fix for
[the confinement defect](2026-08-23-kernel-persist-path-is-unsandboxed.md). A
cell still runs in an unsandboxed host `python3` with the harness's filesystem
and network reach; it just no longer carries credentials it was never meant to,
on any `Io`.

## Verification

`test "a cell's environment is exactly the one the caller named"`
(`src/sandbox/kernel.zig`) hands `eval` a map naming `KERNEL_ENV_PROBE` and
`HOME` and asserts a cell answers

```
['named-by-the-caller', '/kernel-probe-home', False]
```

for `[os.environ.get('KERNEL_ENV_PROBE'), os.environ.get('HOME'), 'PATH' in
os.environ]`. Both directions are asserted at once: the named variables arrive
with the caller's values, and `PATH` -- which the harness running the test
certainly has and the map does not name -- does not. It asserts three answers
rather than `sorted(os.environ)` because the platform adds its own entries.

That it fails for the reported reason: passing `.environ_map = null` at the
spawn gives `[None, None, False]`, the before-state exactly.

Live, same command as the reproduction, `deepseek-v4-flash`:

| | `[len(os.environ), API_KEY names, HOME?, PATH?]` |
|---|---|
| before | `[2, [], False, ...]` |
| after | `[7, [], True, True]` |

`FAKE_PROBE_API_KEY` was exported into the harness's own environment in both
runs and reaches a cell in neither -- before by accident, now by the filter.

## Follow-up

- A cell has no `TMPDIR`, because `TMPDIR` is not in `env_default_allow`. That
  is now a stated consequence rather than an accident: `tempfile` falls back to
  `/tmp`, which the supervisor already relies on for its fd-capture files.
  Worth revisiting if a cell ever needs a writable temp area inside its own
  kernel directory.
- The loopback bridge PRD 0016 specifies passes `CLANKER_BRIDGE_URL` and
  `CLANKER_BRIDGE_TOKEN` to the kernel. Whoever builds it has to add those two
  names to the map here; with the field required, they cannot forget the map
  itself.

## References

- Investigation: none. Found while trying to demonstrate a credential leak for
  the confinement record; the probe answered the other way and named this.
- [production kernel cells run unsandboxed](2026-08-23-kernel-persist-path-is-unsandboxed.md)
  -- the confinement defect this narrows and does not fix.
- [ADR 0010](../../adrs/0010-kernels-are-an-opt-in-unsandboxed-class.md),
  [PRD 0016](../../prds/0016-eval-kernel.md).
- `src/sandbox/kernel.zig` -- `EvalOpts.environ_map`, `ensureSupervisor`.
- `src/sandbox/host.zig` -- `execEnvironment`, `envAllowed`, `ckKernel`.
- `src/sandbox/jobs.zig` -- the same rule, with the same reason written down.

- Investigation: none yet
