# RFC 0009 — REPL block-level markdown in the vaxis transcript

## Status

Decided — 2026-08-17. ADR 0021

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

The vaxis REPL renders markdown line-by-line (headings, bold/italic, single bullet). Tables, block quotes and nested lists remain unstyled, unlike clanker run's MdStream. Decide the parser/renderer shape, reuse, and performance budget for extending src/tui/repl.zig to block-level.

**Decision to make.** Which parser/renderer do we adopt for block-level markdown (tables, blockquotes, nested lists) in the vaxis REPL transcript, and how does it relate to the existing `MdStream` used by `clanker run`?

**Why now.** ROADMAP Planned and PRD 0005 list this as the next REPL gap. Multi-line constructs currently render as plain text, degrading readability of model output that relies on them.

**Drivers.** No new runtime dependency (Zig 0.16 only); no WASM guest for pure UI rendering; must run at ~30fps draw cost; must reuse theme/sanitize/width stack; must not break line-level inline semantics; must stay vaxis-native (no external markdown C lib).

**Out of scope.** Multi-line input, image input, and plan-mode wiring (separate RFCs). No change to `MdStream` for `clanker run`; it already renders block-level in ANSI.

## Current state

`src/tui/repl.zig:mdLineSegments` + `appendInline` does line-level markdown per transcript line (headings `#..######`, single bullet `-/*/+`, inline `**bold**`/`*italic*`/`_italic_`/`code`). `src/tui/transcript.zig:MdStream` does block-level streaming md for `clanker run` (fences, headings, quotes, lists) over ANSI. REPL draws via vaxis segments/styles, not ANSI. Gap: `> quote`, `| table |`, nested `  - ` lists.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Extend repl.zig with pure-Zig block parser emitting vaxis segments

- **What it is:** Add `parseBlock`, `renderTable`, `renderQuote`, `renderNestedList` in `repl.zig` reusing `appendInline`/`mdStyles`; walk transcript `lines` per draw, emit extra leading/border segments. No new file, no dep.
- **Maturity:** Local code, no external dep; same inline semantics already shipped.
- **How it would fit:** Touch `src/tui/repl.zig` only; new helpers + tests in same file. No build.zig change.
- **Pros:** Zero dep; consistent style; cheap to iterate; matches `MdStream` semantics when viewed side-by-side.
- **Cons:** Hand-rolled table alignment/quoting is fiddly; need perf cap for huge tables.
- **Cost to adopt:** ~200-400 LOC + tests; one PR.
- **Cost to leave:** Delete helpers, revert to plain segments.
- **Evidence:** `src/tui/repl.zig:6004 mdLineSegments` and `src/tui/transcript.zig:MdStream` exist in tree — verified.

### Option B — Port MdStream to vaxis segments (shared renderer)

- **What it is:** Refactor `MdStream` (or extract a shared `md_block.zig`) to emit either ANSI or `vaxis.Segment` via a writer interface.
- **Maturity:** Reuses proven block parser already handling fences/headings/quotes/lists in streaming mode.
- **How it would fit:** New `src/tui/md_block.zig` shared by `transcript.zig` and `repl.zig`; both callers pick the output backend.
- **Pros:** Single block parser for whole project; fewer divergences.
- **Cons:** Couples REPL draw to `MdStream`'s streaming hold/lookahead state; riskier refactor.
- **Cost to adopt:** Extract + adapt + re-test MdStream; 2-3× Option A.
- **Cost to leave:** Reintroduce ANSI-only MdStream.
- **Evidence:** `MdStream` streaming hold logic in `transcript.zig:25-190` — verified.

### Option C — Use an off-the-shelf markdown lib (e.g. C comrak via cImport)

- **What it is:** Vendor comrak/cmark; call into C for block parse, then style segments.
- **Maturity:** Mature C libs, but adds C dep, build fragility, and licence weight.
- **How it would fit:** `build.zig` cImport, cross-compile burden, no WASM; still need vaxis styling pass.
- **Pros:** Full CommonMark compliance.
- **Cons:** Heavy dep for 3 constructs; build/toolchain complexity; not Zig-idiomatic here.
- **Cost to adopt:** Build + FFI + styling bridge; hardest to back out.
- **Cost to leave:** Rip out C dep and rebuild.
- **Evidence:** Out-of-box: not in tree, not in `build.zig` — verified absent.

### Option D — status quo

- **What it is:** keep doing what we do today.
- **Pros:**
- **Cons:**
- **Cost to adopt:** zero now; state what it costs later.
- **Evidence:**

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:** Tables/quotes/nested lists styled in REPL; parity with `clanker run` where it matters.
- **If B:** Same, plus shared parser reduces future drift.
- **If D:** No change; readability gap remains.

### Medium term (3–12 months)

- **If A:** Incremental polish (alignment, wrapping) without refactor; easy to later merge into shared module.
- **If B:** Shared module starts paying off if more consumers appear.
- **If D:** Gap accumulates as model output leans more on tables.

### Long term (12+ months)

- **If A:** May eventually extract shared md_block once stable — natural sequence.
- **If B:** Shared abstraction amortizes, but was premature if REPL usage stays narrow.
- **If D:** Permanent debt.

## Recommendation

**Recommended option:** Adopt Option A — extend repl.zig with a pure-Zig block parser emitting vaxis segments

**Confidence:** 7/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Smallest scope that closes the roadmap gap with no new dependency and no cross-cutting MdStream refactor; reuse existing appendInline/mdStyles; easy to later extract into shared md_block if a second consumer needs it.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Max table width/wrapping policy — `repl.zig` draw vs. pre-wrap?
- Whether quote nesting depth needs visual distinction beyond `▎` bar.

## Next steps / action items

- [ ] PRD checklist for block-level md; ADR for the choice.
- [ ] Implement A, add tests, verify draw perf.
- [ ] Write the ADR once decided.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
