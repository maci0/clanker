# RFC 0034 — How nested runs pick explore/plan/coder profiles

## Status

Decided — 2026-08-21. ADR 0046

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Kimi Code ships built-in subagents: coder writes, explore is read-only, plan has no shell. Clanker ck_subagent is generic; ADR 0030 shipped main-session presets. Decide how nested runs name a profile.

**Decision to make.** One sentence, phrased as the question the reader must
answer — "which X do we adopt for Y", not "we should adopt X".

**Why now.** What forces the choice: a blocked implementation, a cost, a
failure, a deadline, a dependency that is going away.

**Drivers.** The constraints any acceptable option has to satisfy (language and
toolchain, sandbox model, dependency budget, licence, operational cost, who
maintains it). These are what the options are scored against below, so keep
them concrete enough to disqualify something.

**Out of scope.** What this RFC deliberately does not decide, so a reader does
not read a broader mandate into it.

## Current state

How the thing works today, including the workaround being used in place of a
decision. Name the files, tools, or config that would change. If the status quo
is viable, it belongs in the options below as a real candidate, not as a
strawman.

## Options considered

Sources opened: kimi docs/en/customization/agents.md Built-in Sub-Agents (2026-08-21); ADR 0030 preset.toml; ck_subagent.

### Option A — shipped presets explore/plan/coder, subagent_type names one

What it is: three preset.toml files. explore denies writes and exec; plan denies exec too; coder is the current default. subagent tool gains subagent_type (default coder). Nested runs cannot spawn further nested runs unless the preset says so (kimi: built-ins cannot recurse).

How it would fit: presets/explore.toml etc; tools/zig/subagent.zig type field; loop.zig applies the preset to the nested Agent.

Pros: reuses ADR 0030; enforcement is the existing tools_deny, not prose.

Cons: three more files to keep matching the catalog.

Cost to adopt: three presets + one field. Cost to leave: delete them.

Evidence: agents.md; ADR 0030; PRD 0033.

### Option B — hard-code three types in ck_subagent

What it is: a switch in the host.

Pros: no files.

Cons: a closed type table outside presets; harder to add reviewer.

### Option C — status quo

What it is: one generic nested agent.

Pros: simple.

Cons: "explore" is a polite request.

### Option D — out of the box: operator passes --preset on the parent only

What it is: nested inherits parent preset.

Pros: zero nested API.

Cons: a write-capable parent cannot spawn a read-only explore.

## Implications by horizon

### Short term
- **If A:** subagent {type:explore} is enforced read-only.
- **If B:** host switch.
- **If status quo:** generic.

### Medium term
- **If A:** more profiles are more preset.toml.
- **If B:** every new type is a host edit.
- **If status quo:** personas in the prompt only.

### Long term
- **If A:** nested types and main-session presets are one mechanism.
- **If B:** two systems.
- **If status quo:** fine if nobody delegates explore.

## Next steps / action items

- [ ] ADR: nested types are shipped presets, not a host enum
- [ ] PRD: three files + subagent_type phase 1; recurse allowlist later

## Recommendation

**Recommended option:** Adopt Option A: shipped presets explore/plan/coder, subagent_type names one

**Confidence:** 8/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** Reuses ADR 0030 enforcement. A host enum is a second type table. Prompt-only explore is not read-only.

**Reversibility.** How hard it is to undo, and the point of no return (a
migrated data format, a public API, a dependency baked into the build).

## Open questions

Questions whose answers could change the recommendation, each with who or what
can answer it. Keep them here until they are answered; do not silently drop the
ones that turned out to be inconvenient.

## Next steps / action items

- [ ] What happens if this recommendation is accepted, in order.
- [ ] The experiment or spike that would settle an open question above.
- [ ] Who is being asked for comment, and by when.
- [ ] Write the ADR once the decision is made.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).


- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
