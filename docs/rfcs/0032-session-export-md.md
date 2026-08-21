# RFC 0032 — How session export grows a markdown form

## Status

Decided — 2026-08-21. ADR 0044

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Kimi Code /export-md writes a human-readable markdown file. Clanker session export is HTML-only. Decide a second renderer that does not re-parse untrusted text as HTML.

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

Sources opened: kimi docs/en/guides/sessions.md Exporting a session (2026-08-21); tools/zig/session_export_logic.zig (HTML, escape, no markdown re-render).

### Option A — format=md on the existing session_export guest, preformatted text

What it is: second renderer in session_export_logic.zig. Role headings plus fenced bodies. Escape is not HTML entities; markdown special chars in untrusted text stay literal inside fences. No CommonMark parse of model output.

How it would fit: session_export op format html|md; clanker session export --format md; TUI /export-md later.

Pros: one guest; HTML path unchanged; host-tested.

Cons: two renderers to keep in lockstep on new message fields.

Cost to adopt: format switch + tests with hostile <script> and ```. Cost to leave: drop md.

Evidence: session_export_logic.zig doc comment; sessions.md /export-md.

### Option B — a new export_md guest

What it is: second tool.

Pros: HTML guest untouched.

Cons: two implementations of session shape.

### Option C — status quo

What it is: HTML only.

Pros: one escaper.

Cons: no markdown share.

### Option D — out of the box: session_search + copy

What it is: humans copy from the TUI.

Pros: zero code.

Cons: not a file.

## Implications by horizon

### Short term
- **If A:** clanker session export --format md writes a .md file.
- **If B:** extra guest.
- **If status quo:** HTML remains.

### Medium term
- **If A:** TUI /export-md.
- **If B:** drift.
- **If status quo:** operators convert HTML by hand.

### Long term
- **If A:** HTML stays the safe share; md is the readable one.
- **If B:** two guests forever.
- **If status quo:** fine for file:// HTML.

## Next steps / action items

- [ ] ADR: markdown export is a second renderer in the same guest
- [ ] PRD: format=md phase 1 on the CLI; TUI later

## Recommendation

**Recommended option:** Adopt Option A: format=md on the existing session_export guest, preformatted text

**Confidence:** 9/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** One guest, HTML unchanged, no CommonMark parse of untrusted text. A second guest would duplicate session shape.

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
