# RFC 0024 — Whether repo_search attaches enclosing symbols to grep hits

## Status

Decided — 2026-08-21. ADR 0036

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

jcode agent-grep returns enclosing functions with each hit so the model infers file shape without a full read. clanker's repo_search and symbols tools are separate; hits carry no outline. Decide whether to attach enclosing symbols on the grep path.

**Decision to make.** Should repo_search attach enclosing symbols to grep hits, and where does that walk live?

**Why now.** Each hit currently forces a follow-up read_file or symbols call to learn which function it sat in. jcode agent-grep returns that with the hit. Inventory: docs/research/jcode-features.md.

**Drivers.** WASM-by-default: the outline walk is a guest helper (host-tested, no ABI), called from repo_search. Do not spawn a second grep. Language coverage can start with Zig. Cap extra bytes so a 200-hit grep does not explode.

**Out of scope.** Adaptive truncation from a seen-set (defer). Replacing ast-grep/semcode. A new catalog tool name.

## Current state

tools/zig/repo_search.zig returns rg/ast-grep/semcode matches as file:line:text. tools/zig/symbols.zig finds Zig declarations by name, not enclosing scope of a line. The model must call both. Files: a host-tested helper (tools/zig/grep_outline.zig) imported by repo_search; tests in host_tested_helpers.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Enclosing-symbol walk on repo_search hits (Zig first)

What it is: for each rg/host hit, if the file is readable, walk backward from the line for the nearest fn/const/struct/enum/union (and a generic `function`/`def `/`class ` fallback). Attach {symbol, kind, line} on the match. Skip binary. Cap at N extra bytes.

Maturity: jcode agent-grep ships structure; we have symbols.zig as a sibling, not this walk.

How it would fit: tools/zig/grep_outline.zig host-tested; repo_search.zig calls it on structured matches. No new catalog name.

Pros: one tool call; token savings on follow-up reads; tests drive the real helper.

Cons: heuristic, not an AST; Zig-first then a weak fallback.

Cost to adopt: one helper + wiring. Cost to leave: stop attaching the field.

Evidence: jcode README Agent grep; tools/zig/repo_search.zig; tools/zig/symbols.zig.

### Option B — Teach the model to call symbols after repo_search

What it is: prompt_guidance telling the model to follow grep with symbols.

How it would fit: manifest prompt_guidance only.

Pros: zero code.

Cons: two round trips; symbols looks up a name, not a line; models skip it.

Cost to adopt: a sentence. Cost to leave: delete it.

Evidence: symbols.zig matches declarations by name.

### Option C — status quo

What it is: grep returns lines; the model reads the file.

Pros: no false enclosing symbols.

Cons: extra reads; 200-hit cap already hides file shape.

Cost to adopt: zero; token burn continues.

Evidence: repo_search output shape today.

### Option D — out of the box: ast-grep engine is already the default

What it is: repo_search defaults to ast-grep, which is structural.

How it would fit: nothing; tell operators to use engine=ast-grep.

Pros: already shipped.

Cons: ast-grep answers a pattern query, not enclosing scope of a regex hit. A text grep still has no outline. Zig grammar is custom.

Cost to adopt: docs. Cost to leave: n/a.

Evidence: repo_search.zig default engine ast-grep.

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

If A: rg hits carry enclosing Zig symbols this release. If B: a prompt sentence nobody will obey. If status quo: extra reads. If D: ast-grep users unchanged, rg users unchanged.

### Medium term (3–12 months)

If A: add more languages by extending the helper, not a new tool. Seen-set truncation can land as phase 2.

### Long term (12+ months)

If A: outline stays a field on the existing tool. If C: we keep paying for read_file.

## Recommendation

**Recommended option:** Option A: attach enclosing symbols on repo_search hits via a host-tested helper, Zig first

**Confidence:** 8/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** One tool call, no new catalog name, testable without HTTP. Prompt-guidance will be skipped. ast-grep default does not outline a regex hit.

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



- Research: [jcode feature inventory](../research/jcode-features.md).
- tools/zig/repo_search.zig, tools/zig/symbols.zig. jcode README Agent grep (2026-08-21).

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
