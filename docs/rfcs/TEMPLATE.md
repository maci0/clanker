# RFC {{number}} — {{title}}

## Status

{{status}} — opened {{date}}.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

{{overview}}

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

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — <name>

- **What it is:** one or two sentences.
- **Maturity:** release cadence, last release, maintainer count, licence,
  who else runs it in production.
- **How it would fit:** what changes here — files, dependencies, build steps,
  sandbox policy, operational surface.
- **Pros:**
- **Cons:**
- **Cost to adopt:** work to land it, plus the recurring cost of keeping it.
- **Cost to leave:** what it takes to back out after six months.
- **Evidence:** links, with what each one actually shows. Mark anything not
  verified as `unverified`.

### Option B — <name>

- **What it is:**
- **Maturity:**
- **How it would fit:**
- **Pros:**
- **Cons:**
- **Cost to adopt:**
- **Cost to leave:**
- **Evidence:**

### Option C — status quo

- **What it is:** keep doing what we do today.
- **Pros:**
- **Cons:**
- **Cost to adopt:** zero now; state what it costs later.
- **Evidence:**

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:**
- **If B:**
- **If status quo:**

### Medium term (3–12 months)

- **If A:**
- **If B:**
- **If status quo:**

### Long term (12+ months)

- **If A:**
- **If B:**
- **If status quo:**

## Recommendation

**Recommended option:** <A / B / status quo / phased: A now, B if X happens>

**Confidence:** {{confidence}}/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** Why this option beats the runner-up against the drivers above,
in terms of the trade-off accepted — not a restatement of its pros.

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

{{references}}

- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
