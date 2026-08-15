# Research — {{title}}

## Status

{{status}} — searched {{date}}.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

{{question}}

State it precisely enough that a source either answers it or does not. "What
should we use for X" is not answerable; "which X can run inside a
wasm32-freestanding guest with no libc" is.

## TL;DR

Three to six bullets, each one a finding with a link. Everything below is the
evidence for these lines.

- **Finding.** What it means for us — `high` / `medium` / `low` confidence — [source](https://example.invalid)

## Scope and method

- **Searched:** the queries and sources actually used (web, GitHub, code search,
  discussion archives, papers, the local tree).
- **Not searched:** what was skipped and why, so the next reader knows where the
  gaps are.
- **Freshness:** the date of the sweep, and the newest source found. Anything
  that ages fast (release cadence, pricing, hosted APIs) should say so.

## Options found

One subsection per candidate. Include what it is before whether it is good.

### <Option> — <one line>

- **What it is:**
- **Maturity:** stars, last release, commit cadence, maintainer count, licence,
  known production users. Give the numbers and the date they were read.
- **Fit:** against the constraints in the question — language and toolchain,
  dependency budget, sandbox and network policy, platform support.
- **Pros:**
- **Cons:**
- **Unknowns:** what could not be established from the sources at hand.
- **Evidence:** links, each with what it actually shows.

## Out-of-the-box options

The candidates that a plain search does not return. Check each one explicitly
and say why it does or does not work, rather than dropping the heading:

- **Already in the tree:** an existing dependency, tool, or module that covers
  this if used differently.
- **Standard library / OS primitive:** the boring answer that needs no
  dependency at all.
- **Do nothing:** keep the workaround, and what that costs over time.
- **Adjacent domain:** how a neighbouring field solves the same shape of
  problem.
- **Buy, host, or delegate:** an external service or an existing binary called
  out to instead of code written here.

## Comparison

| Option | Maturity | Licence | Fit | Main risk |
|---|---|---|---|---|
|  |  |  |  |  |

## Evidence log

Every claim above traces to a row here. Keep the rejected leads: knowing a
promising-looking option was checked and failed is worth as much as the winner.

| Claim | Source | Read on | Confidence |
|---|---|---|---|
|  |  |  |  |

## Open questions

What is still unresolved, and the specific search, benchmark, or spike that
would settle it.

## What would change the answer

The conditions under which this research goes stale — a release, a licence
change, a deprecation, a change in our own constraints.

## References

- Every source cited above, grouped by kind.

## Appendix

Optional: raw sweep output, long quotes, benchmark numbers, and the queries in
full so the sweep can be repeated.
