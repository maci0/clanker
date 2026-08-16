# RFC 0004: Pipe LLM inputs and outputs into MuninnDB

## Status

Decided, 2026-08-16. Choice recorded in
[ADR 0015](../adrs/0015-llm-io-journal-to-muninn.md).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Every model call (agent turn, subagent, `ck_llm`, improve, arena) already
hits one choke point: `src/llm/client.zig` `chat` / `chatStream`. That
path writes **counts** to `state/token_stats.jsonl` and never the bodies
("Never a request body: those can echo prompts and credentials"). Session
transcripts keep the operator-visible chat, not every internal completion.

The operator wants those inputs and outputs in [MuninnDB](https://muninndb.com/)
so later recall, graph links, and RAG can see what the models actually
said, not only Knowledge docs the operator uploaded.

This is **not** the same as PRD 0007's unused `vector.backend = "muninndb"`
(rank Knowledge chunks). That is a search index. This is a journal of
LLM I/O.

**Decision to make.** Where do we tap LLM I/O, what of each call is stored,
and how does it reach MuninnDB?

**Why now.** Chat and goal attachments (RFC 0002/0003) land operator files
in Knowledge. Internal model text still dies in the request arena. A
second tap invented in the agent loop will miss `ck_llm` and improve.

**Drivers.**

- One tap. `client.chat` / `chatStream` already records usage. A second
  site will drift. The OpenAI/Anthropic **proxy** must not go through
  `client.chat` (AGENTS.md); proxy I/O is out of this RFC.
- Fail-open. A Muninn outage must not fail the completion. Same spirit as
  token_stats: best-effort append.
- Opt-in. Bodies can contain secrets, retrieved untrusted text, and
  customer data. Default off. A config flag, not a surprise.
- Not a second Knowledge store. Operator uploads stay
  `state/knowledge/` (ADR 0014, RFC 0003). Muninn I/O is a different
  corpus (turns), or a clearly named vault/collection inside Muninn.
- Native sink. Muninn is reached over HTTP/gRPC/SDK from the host. A
  WASM guest cannot see every call (improve and the client are native)
  and must not hold a Muninn token on `env_allow` by default.
- Cap what we write. Full system prompts repeat every turn. Tool results
  can be megabytes. Store a bounded excerpt plus hashes, not unbounded
  copies of every `ck_fs_read`.
- Failed calls too (`ok:false`), matching token_stats. A log of only
  successes cannot answer "what did we send when it 500'd?"
- Retrieved fences stay fences. If we persist the assembled request,
  `<retrieved_knowledge>` blocks are untrusted data in Muninn. Do not
  promote them to operator task text.

**Out of scope.** Implementing Muninn as `vector.backend` for Knowledge
chunk search (PRD 0007). Proxy `/v1/*` bodies. Auto-injecting Muninn hits
into the next prompt (that is a later retrieve RFC). REPL display of the
journal. Muninn cloud vs self-host topology.

## Current state

| Stream | What is kept | Bodies? |
|---|---|---|
| `token_stats.jsonl` | provider, model, tokens, cost, ok, http_status, err | no |
| Session transcript | operator/assistant/tool messages for that chat | yes, that session only |
| Improve / arena / `ck_llm` | ephemeral in the run arena | no durable journal |
| Knowledge / memory | operator docs, hash embed at query time | not LLM I/O |
| `vector.backend = muninndb` | parsed in config | unused (PRD 0007) |

There is no Muninn client in the tree. Muninn speaks MCP, REST, gRPC, and
an SDK ([how it works](https://muninndb.com/how-it-works/)). This checkout
does not link any of them.

## Options considered

### Option A: tap `client.zig`, opt-in sink to Muninn (and a local buffer)

- **What it is:** next to `recordUsage` / `recordFailure`, if enabled,
  write one journal record per attempt: provider, model, ok, a redacted
  bounded copy of messages in, text/tool-calls out, usage, `request_id`.
  If `[memory] muninn_url` (or equivalent) is set, POST that record to
  Muninn (`remember` / engram create). Always also append a capped jsonl
  under `state/` so a missing Muninn process does not drop the turn.
- **Maturity:** the tap site is proven (token_stats). Muninn HTTP is
  documented; we have not vendored a client.
- **How it would fit:** `src/llm/client.zig` one fail-open call.
  `src/config.zig` keys (enable, url, vault, max_bytes). Redact via
  existing `src/util/redact.zig`. No guest. No `switch (provider.kind)`.
- **Pros:**
  - Every harness completion is in one place (agent, subagent, ck_llm,
    improve, arena).
  - Survives Muninn downtime (jsonl).
  - Matches how we already count tokens.
- **Cons:**
  - Bodies on disk and in Muninn are a privacy surface.
  - System prompt duplication unless we hash and store once.
  - Native HTTP to Muninn is a new outbound dependency (loopback by
    default).
- **Cost to adopt:** config + journal struct + HTTP POST + caps/redact
  tests at the client.
- **Cost to leave:** stop writing; delete jsonl and the Muninn vault.
- **Evidence:** `recordUsage` in `client.zig`; token_stats comment
  forbidding request bodies; Muninn REST on 8475 (vendor docs).

### Option B: agent loop only

- **What it is:** after each Agent turn, the loop (or a guest) pushes
  the visible messages to Muninn.
- **Pros:** smaller payload (no internal classifier calls).
- **Cons:** misses `ck_llm`, improve, arena, advisor. The operator said
  *all* inputs and outputs.
- **Evidence:** `ck_llm` and improve call `client.chat` without going
  through `Agent.run`'s transcript writer.

### Option C: status quo

- **What it is:** counts in token_stats, chat in sessions, nothing else.
- **Pros:** no new secret store; no volume risk.
- **Cons:** cannot ask Muninn "what did we tell the model about X?"
- **Cost to adopt:** zero now; the next memory feature will scrape
  sessions and miss internal calls.

### Option D: out of the box, jsonl only (no Muninn process)

- **What it is:** the same bounded records as A, written only to
  `state/llm_io.jsonl` (cap like token_stats' 32 MiB). A later importer
  or a configured Muninn URL (A) consumes it. No SDK in v1.
- **Maturity:** we already do this for usage. Zero new runtime.
- **Pros:** shippable without Muninn installed; one record shape.
- **Cons:** not "in Muninn" until something ships the rows. Operators
  who already run Muninn get a file, not a graph.
- **Cost to adopt:** journal writer next to token_stats.
- **Cost to leave:** delete the jsonl.
- **Evidence:** `src/stats/tokens.zig` append + cap.

### Option E: Muninn as Knowledge `vector.backend` only

- **What it is:** implement PRD 0007's stub so Knowledge search uses
  Muninn. Do not journal LLM I/O.
- **Pros:** useful for RFC 0002/0003 docs.
- **Cons:** does not capture model I/O. Different RFC.
- **Evidence:** `vector.backend` is parsed and unread.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** opt-in flag + jsonl + POST when url is set. Off by default.
- **If B:** chat looks covered; ck_llm/improve are not.
- **If status quo:** still counts only.
- **If D:** jsonl exists; Muninn wait for a sink.
- **If E:** Knowledge search changes; I/O still gone.

### Medium term (3–12 months)

- **If A:** retrieve RFC can read Muninn for "similar past turns"
  behind the same untrusted fence as Knowledge.
- **If D then A:** importer backfills.
- **If B / C / E:** a third log appears for arena/improve.

### Long term (12+ months)

- **If A:** Muninn holds the turn graph; Knowledge holds operator
  docs; token_stats stays the cheap counter. Three jobs, three stores.
- **If D only:** we reinvent Muninn poorly in jsonl.
- **If E only:** RAG over uploads, amnesia about our own calls.

## Recommendation

**Recommended option:** Phased **D then A**. Ship the bounded, opt-in
jsonl journal at the `client.zig` tap first (same record both sinks will
use). When `muninn_url` is set, POST each record to Muninn as well
(fail-open). Do not wait on a vendored SDK. Do not turn this on by
default. Do not replace Knowledge or token_stats. Do not treat this as
`vector.backend`.

**Confidence:** 6/10

**Why this confidence.** The tap site is obvious and already tested for
counts. What holds the score down: we have not integrated Muninn's
remember API in-tree, body caps vs "all I/O" will be argued, and default
off may feel like we did not do what was asked. Confidence rises after a
spike POSTs one redacted turn to a local Muninn and retrieves it.
It sinks if Muninn requires an LLM enrich plugin for every write (then
we would pay tokens to store tokens).

**Rationale.** B is incomplete. C refuses the request. E is a different
product. A-only blocks on a client we do not have. D-then-A uses the
pattern we already trust (jsonl at the choke point) and grows a Muninn
sink without a second schema.

**Reversibility.** Additive file + optional HTTP. Delete jsonl and the
vault. The point of no return is operators treating Muninn as the
system of record for prompts (retention, legal). Keep the flag off
until that is accepted.

## Open questions

1. **What is "the input"?** Full message list, or last user + reply?
   Bias: last user (or tool result) + assistant out, plus a hash of
   the system prompt, not the full system prompt every time.
2. **Default off or on?** Bias: off. Bodies are secrets until someone
   opts in.
3. **Vault / collection name.** Bias: one vault `llm-io`, not mixed
   with Knowledge `uploads` / `goal-*`.
4. **Link to session / goal / arena id** when the call has one, so
   Muninn can graph them. Bias: yes, when `request_id` or session id
   is on the ctx.
5. **Should failed bodies (4xx) be stored?** Bias: store the outgoing
   excerpt, not the raw provider error page (token_stats already
   keeps `err` short).

## Next steps / action items

- [x] Comment on default off (question 2) and what slice of the
      prompt is stored (question 1).
- [ ] Spike: opt-in jsonl at `recordUsage` / `recordFailure` with a
      byte cap and redact.
- [ ] Spike: POST one record to a local Muninn REST endpoint; fail-open.
- [ ] Do not implement `vector.backend = muninndb` in this RFC.
- [ ] Do not send proxy `/v1/*` bodies.
- [x] Write the ADR once the decision is made.

## References

- [ADR 0015: LLM I/O is journaled at the client tap, then optionally to Muninn](../adrs/0015-llm-io-journal-to-muninn.md)
- [PRD 0007: Memory layer](../prds/0007-memory.md) (`vector.backend` unused)
- [ADR 0014: Chat uploads land in Knowledge](../adrs/0014-chat-uploads-land-in-knowledge.md)
- [RFC 0002](0002-chat-upload-into-knowledge.md), [RFC 0003](0003-goal-card-file-attachments.md)
- `src/llm/client.zig` (`recordUsage`, `recordFailure`)
- `src/stats/tokens.zig` (jsonl, 32 MiB cap, no bodies)
- `src/util/redact.zig`
- Muninn: https://muninndb.com/how-it-works/ (REST 8475, MCP 8750, engrams)
- AGENTS.md: proxy must not go through `client.chat`
