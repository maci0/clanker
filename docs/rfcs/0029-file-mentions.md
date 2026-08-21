# RFC 0029 — How composer @file mentions inject path contents

## Status

Decided — 2026-08-21. ADR 0041

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Kimi Code loads a relative path when the operator types @path in the composer. Clanker has no mention expander. Decide how mentions are parsed, which paths they may read, and where the bytes land in the saved session.

**Decision to make.** How does a composer @path mention become file bytes the model sees, and which paths are refused?

**Why now.** Kimi Code interaction.md (opened 2026-08-21) makes @ the default way to hand a file to the agent. Operators here paste or call read_file. The expander must share secret_dotenv refusal with the sandbox.

**Drivers.** Untrusted path from the operator still must not read .env. Model-visible input lands in the saved session (AGENTS.md). WASM-by-default: the expander is a host-tested helper the REPL and web composer both call. No new dependency.

**Out of scope.** TUI @ completion UI (picker). Image/video mentions (PRD 0041). Directory expansion.

## Current state

Composer text is sent as the user message. /attach queues images only. Workaround: paste the file or ask the model to read_file. Files: a helper (tools/zig/mention_expand.zig), src/tui/repl.zig submitTask, optionally ui/app composer later.

## Options considered

Sources opened: kimi docs/en/guides/interaction.md File references (2026-08-21), src/util/secret_dotenv.zig, src/tui/repl.zig submitTask. Seeded steal headings from the research note were inventory, not candidates for this decision.

### Option A — host-tested expander inlines fenced file bytes into the saved user message

What it is: parse whitespace-bounded @rel/path tokens (not email @), read the file, refuse secret_dotenv names and paths outside sandbox prefixes, replace the token with a fenced block. The saved session holds the bytes.

Maturity: kimi interaction.md File references, opened 2026-08-21. Parser is std only.

How it would fit: tools/zig/mention_expand.zig in host_tested_helpers; REPL submitTask calls it before Agent.run. Web composer is a later phase.

Pros: one helper both surfaces can share; unit-testable without TUI; dotenv refusal is the existing rule.

Cons: large files blow the user message; need a byte cap and a truncated notice.

Cost to adopt: helper + tests + one submit path. Cost to leave: stop calling it.

Evidence: interaction.md File references; secret_dotenv.zig; AGENTS.md model-visible means logged.

### Option B — expander becomes a synthetic read_file tool result

What it is: leave the user text as @path, append a tool-result-shaped message the host forged.

How it would fit: session append a tool message without a model tool call.

Pros: keeps the user line short.

Cons: forges a tool result the model did not request; append-only log would show a lie.

Cost to adopt: session shape change. Cost to leave: stop forging.

Evidence: AGENTS.md append-only history.

### Option C — status quo

What it is: paste or read_file.

Pros: no expander footgun.

Cons: extra turn per file.

Cost to adopt: zero now.

### Option D — out of the box: reuse /attach for text

What it is: /attach already queues paths; extend it to text files.

Pros: one command.

Cons: @ in prose is the advertised kimi shape; /attach is image-shaped (ImagePart).

Evidence: PRD 0041.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** REPL @path inlines files; tests cover dotenv refuse and cap.
- **If B:** forged tool results confuse session search.
- **If status quo:** paste remains the workaround.

### Medium term (3–12 months)

- **If A:** web composer reuses the helper.
- **If B:** every mention is a fake tool row in graphs.
- **If status quo:** operators keep burning a read_file turn.

### Long term (12+ months)

- **If A:** completion UI can land later without changing the expander.
- **If B:** the lie is load-bearing.
- **If status quo:** still no @.

## Next steps / action items

- [ ] ADR whose title is the expander choice
- [ ] PRD: helper + REPL phase 1, web later
- [ ] Tests drive expandMentions, not a copy

## Recommendation

**Recommended option:** Adopt Option A: host-tested expander inlines fenced file bytes into the saved user message

**Confidence:** 8/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** Shares one helper, refuses dotenv, and logs model-visible bytes. B forges tool results. D mismatches /attach image shape.

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
