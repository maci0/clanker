# PRD — Fallback provider chain (general failure, not vision-only)

## Status

Draft. Nothing in this PRD is built yet. Sources of truth once built:
`src/config.zig` (`Agent.fallback_provider`, `~L260`), `src/cli.zig`
(`visionFallbackProvider`, `~L9456-9480`, and its one call site,
`~L9668-9676`), `src/llm/client.zig` (`isRetryable`, `max_attempts`, the
existing same-provider retry loop, `~L49-120`), `src/agent/loop.zig`
(`self.provider: *const config.Provider`, `~L68`, and its `client.chat`/
`chatStream` call sites).

## Problem

`agent.fallback_provider` is one name, and it is wired to exactly one
trigger: an image is attached, `cfg.modules.multimodal` is on, and the
selected model does not declare `image_in`
(`req.images.len > 0 and cfg.modules.multimodal and
!imageAttachmentsSupported(...)`, `src/cli.zig:9668`). When that condition
holds, `visionFallbackProvider` picks a *different* provider **before any
request is sent** — a pre-emptive, capability-based swap, zero wasted
requests, decided once at run setup in `cli.zig`, before `Agent.init` even
runs.

Nothing in the codebase reacts to a request that actually *fails*. The one
retry mechanism that exists, `client.zig`'s `isRetryable` +
`max_attempts = 3` loop, retries the **same** provider on a retryable status
(429/500/502/503/504) with backoff, and gives up after three attempts — at
which point the caller just gets an error. A provider that is down, rate
limited past what three backoff attempts can absorb, or misconfigured
(bad key, wrong endpoint) fails the whole run, even when a second configured
provider sits idle in the same `config.toml` and could have served the
request.

The field's own doc comment already describes the general case it doesn't
yet do: "used when the selected/default provider cannot serve the request
(e.g. an image attached to a model that does not declare vision)"
(`src/config.zig:257-259`) — the parenthetical is the only case actually
implemented; the sentence it's attached to reads as the general one.

## Goals

1. `agent.fallback_provider` becomes an ordered list of provider names,
   tried in order, instead of one name — matching the "hierarchy" framing:
   several fallbacks, not a single alternate.
2. The trigger widens from "vision capability gap" to "this provider could
   not serve this request" generally: `client.zig`'s existing retry loop
   exhausts its same-provider attempts (or hits a terminal, unambiguously
   non-retryable failure — see Design for which), and only then does the
   fallback chain advance to the next configured provider for the *same*
   turn.
3. The vision case (Goal-adjacent, not replaced) keeps its pre-emptive
   behavior — checking capability before sending is strictly better than
   sending and failing when the failure is predictable from config alone
   (no image-capable model means every attempt would fail identically, so
   retrying is pure waste). The general chain in Goal 2 is for failures that
   are *not* knowable in advance: rate limits, an outage, a bad key.
4. A mid-run provider swap does not corrupt the conversation: the swap
   happens between an internal neutral `types.Message` list and a next
   provider's `buildRequest`, the same conversion every provider already
   does independently today, and does not require re-sending anything the
   first provider already answered — only the turn that failed retries
   against the next provider.
5. Exhausting the entire chain (every configured fallback also fails) is a
   normal, clearly-reported terminal failure, not a crash or a silent hang.

## Non-goals

- Changing the pre-emptive vision-routing decision logic
  (`visionFallbackProvider`) itself. It keeps deciding *before* sending, on
  capability, because that failure is 100% predictable and retrying it
  after the fact would be pure waste. This PRD adds a second, reactive
  mechanism for a different class of failure; it does not touch the first.
- Health checking or pre-flight probing of fallback providers before a
  request fails. The chain is reactive only, tried in the configured order,
  not reordered by any live signal (e.g. "which fallback answered fastest
  last time"). That is a real future refinement, not this PRD.
- Splitting one failed turn across providers mid-stream (i.e., if provider A
  starts streaming tokens and then the connection drops mid-response). A
  failure that happens after a stream has already started emitting content
  the user has seen is a different, harder problem (what does the user see:
  a garbled partial answer, a retry that repeats itself?) than a failure
  before any content reached the client, which is what `isRetryable`'s
  existing same-provider loop already assumes (it retries whole failed
  attempts, not partial streams). This PRD's chain only engages for a turn
  that failed with **no content yet delivered** to the caller.
- A user-facing "which fallback served this turn" indicator beyond a log
  line. Surfacing that in the webui/REPL transcript is a reasonable
  follow-up, not required to ship the mechanism.

## Design

**Config shape.** `Agent.fallback_provider: []const u8` becomes
`fallback_providers: []const []const u8`, parsed from either a single JSON/
TOML string (normalized to a one-element list, same backward-compatibility
approach as PRD 0022's `tools_dir`) or an array — a user with today's single
`fallback_provider = "ollama"` sees identical behavior; the list form is new
surface, not a breaking change to the existing key.

`RunRequest.fallback_provider` (the per-run webui override,
`src/cli.zig:5627-5631`) gets the equivalent pluralization for consistency,
though a single override remains a valid, common case.

**Trigger (Goal 2).** `client.zig`'s existing loop already distinguishes
retryable statuses from everything else (`isRetryable`,
`too_many_requests`/`internal_server_error`/`bad_gateway`/
`service_unavailable`/`gateway_timeout`) and already gives up after
`max_attempts` (3) exhausted retries on those. The chain engages at exactly
that give-up point, plus any error that doesn't reach `isRetryable` at all
(connection refused, TLS failure, malformed response) — anything that
currently propagates as an error out of `client.chat`/`chatStream` today
becomes the chain's advance signal instead of an immediate failure, as long
as no content has been delivered yet (Non-goals).

**Where the chain lives.** `client.zig` is provider-agnostic per call — it
takes one `*const config.Provider` and knows nothing about any other
configured provider, by design (it's the shared HTTP/SSE/retry core every
vendor's codec sits behind). The chain therefore cannot live inside
`client.zig`'s own retry loop; it has to wrap `client.chat`/`chatStream`
one layer up, in `src/agent/loop.zig`, which already holds `self.cfg` (every
configured provider) alongside `self.provider` (the one currently in use).
Each of the loop's `client.chat`/`chatStream` call sites (`~L544`, `~L549`,
`~L568`, `~L1303`) becomes: call with the current provider; on a chain-
eligible failure (previous paragraph) with `self.cfg.agent.fallback_providers`
non-empty, advance `self.provider` to the next entry not yet tried this
turn and retry the same built request against it; on success, log which
provider actually served the turn; on exhausting the whole chain, propagate
the last error as today.

**`self.provider` becomes swappable mid-run.** Today it is set once at
`Agent.init` and never reassigned (`src/agent/loop.zig:68`, every read site
listed in Problem). This PRD requires the field (or the call sites that read
it) to tolerate a provider that changes between turns — the harness already
does this exact swap once, pre-emptively, in `cli.zig`'s vision-fallback path
(swap happens *before* `Agent.init`, so `self.provider` is simply
constructed pointing at the fallback from the start); this PRD is the first
case where the swap has to happen **after** `Agent.init`, mid-run, which is
new structural surface on `Agent`, not a copy of the existing mechanism.

## Known issues

None — draft, nothing built yet.

## Failure modes

| Condition | Behavior |
|---|---|
| No `fallback_providers` configured | Unchanged: `client.zig`'s existing same-provider retry runs out, the turn fails, exactly as today |
| Primary exhausts retries (3 attempts, retryable status) | Chain advances to the next configured fallback for this turn only |
| Primary fails with a non-retryable, non-content-delivered error (bad key, connection refused) | Chain advances immediately, no 3-attempt wait against a provider that cannot possibly succeed |
| Failure occurs after streamed content has already reached the caller | Chain does **not** engage (Non-goals); propagates as a mid-stream failure exactly as today |
| Every provider in the chain fails | Terminal failure, reported with which providers were tried and each one's last error, not just the last provider's |
| A name in `fallback_providers` does not match any configured `[providers.X]` | Skipped with a warning, chain continues to the next name — a typo in the chain must not silently stop the chain, matching how a missing `tools_dir` directory degrades (PRD 0022) rather than failing hard |
| Fallback provider also lacks the capability the primary needed (e.g. vision) | Not this PRD's concern for the vision case specifically — `visionFallbackProvider` already handles that check pre-emptively and independently; if this general chain ever engages *and* the failing turn also happens to need vision, whichever provider it reaches next must still pass the existing vision gate, so an incapable fallback is refused by that gate as it is today, not silently sent an image it can't take |

## Acceptance criteria

- [ ] `agent.fallback_provider` (string) and a new `fallback_providers`
      (array) both parse; a bare string behaves identically to today's
      single-fallback behavior.
- [ ] A turn whose primary provider exhausts `client.zig`'s existing retry
      budget is retried against the next configured fallback, verified by a
      test that fails the first provider deterministically and asserts the
      second one received the request.
- [ ] A turn that fails after streamed content has already been delivered
      does **not** trigger the chain (verified by a test asserting no
      second-provider call happens in that case).
- [ ] Exhausting the whole chain reports every provider tried and each
      one's terminal error, not just the last.
- [ ] A `fallback_providers` entry naming an unconfigured provider is
      skipped with a warning; the chain continues past it.
- [ ] The pre-emptive vision-routing path (`visionFallbackProvider`) is
      unchanged by this work — its own existing tests still pass unmodified.

## Open questions / future work

- **Ordering intelligence.** The chain is tried in configured order only.
  Whether a smarter order (skip a fallback that failed recently, prefer one
  with capacity) is worth the added state is future work, not blocking this
  PRD's mechanism.
- **Cost/latency signaling.** A fallback provider may be meaningfully more
  expensive or slower than the primary. Should a chain-triggered swap be
  logged more loudly than a debug line (e.g. surfaced in the run's cost
  accounting, or the webui transcript) so a user notices they silently paid
  more for a turn? Left open; the mechanism should ship with at least a log
  line (Design) and grow louder reporting if that turns out to be needed.
- **Does `Agent.provider` becoming mid-run-mutable open any other assumption
  elsewhere** (cost accounting keyed by `self.provider.name` at run start,
  `src/agent/loop.zig:386-404`, reads it per-event already, so it may already
  be safe — but every read site enumerated in Problem needs auditing for
  "assumes provider never changes after `Agent.init`" before this ships, not
  just the four call sites that dispatch requests).
