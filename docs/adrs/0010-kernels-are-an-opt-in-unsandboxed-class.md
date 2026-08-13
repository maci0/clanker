# ADR 0010 — Eval kernels are an opt-in unsandboxed tool class

## Status

Accepted.

## Context

ADR 0007's posture is that the plugin manifest is the security boundary and
it is enforced. A persistent eval kernel (PRD 0016) is a real `python3` or
`bun` subprocess with the host's ambient filesystem permission: the inverse
of that posture once the process is running. DAP (PRD 0017) will share the
same session-scoped subprocess registry.

## Decision

Kernels are a named, opt-in unsandboxed tool class:

- `kernel.enabled = false` by default. Calling the tool while off returns a
  disabled error and starts no process.
- The `kernel` manifest sets `"confirm": true`.
- cgroups (or equivalent) CPU/memory quotas are required before any
  recommended/default config flips `kernel.enabled` to true. Opt-in use
  without quotas is allowed.

The session subprocess registry (`src/agent/subprocess.zig`) is the shared
lifecycle: register by `<session-id>/<kind>`, SIGTERM the group on session
end. DAP reuses that surface rather than inventing a second one.

## Consequences

- The sandbox does not bound a running kernel. The gate is config + confirm.
- A missing `python3`/`bun` is a soft runtime error, not a build dependency.
- Quota work is a pre-default-on requirement, not a v1 opt-in ship blocker.
