# ADR 0015: LLM I/O is journaled at the client tap, then optionally to Muninn

## Status

Accepted. Records the choice in
[RFC 0004](../rfcs/0004-llm-io-into-muninndb.md). Not yet
implemented (2026-08-19): `recordUsage` / `recordFailure` still write only
`state/token_stats.jsonl`; there is no `state/llm_io.jsonl` journal and no
`muninn_url` config.

## Context

`src/llm/client.zig` already records every harness completion as **counts**
in `state/token_stats.jsonl` and refuses to store request bodies (they can
echo prompts and credentials). Session transcripts keep the visible chat,
not `ck_llm`, improve, or arena calls. PRD 0007's `vector.backend`
key was unused and has since been removed; restoring Muninn as a Knowledge
vector backend would only rank chunks, not capture model I/O.

RFC 0004 compared a Muninn POST at that tap (A), journaling only the
agent loop (B), status quo (C), a local jsonl with no Muninn process (D),
and implementing Muninn solely as the Knowledge vector backend (E). B
misses internal calls. E is a different product. A-only blocks on a
client we do not have in-tree.

## Decision

Phased D then A. An opt-in journal at `recordUsage` / `recordFailure`
writes one bounded, redacted record per attempt (last user or tool
result, assistant out, hash of the system prompt, usage, `ok`, ids).
Default off. Fail-open.

Records go to `state/llm_io.jsonl` first (capped, same idea as
token_stats). When `muninn_url` is set, each record is also POSTed to
Muninn vault `llm-io`. No vendored SDK required. Link session / goal /
arena id when the ctx has one.

This does not replace Knowledge, token_stats, or session transcripts.
It is not `vector.backend`. Proxy `/v1/*` bodies stay out (the proxy
must not go through `client.chat`). Failed calls store the outgoing
excerpt, not the raw provider error page.

## Consequences

Operators who opt in can ask Muninn what the models were sent and what
they returned, including improve and `ck_llm`. Bodies on disk and in
Muninn are a retention and secrecy surface: keep the flag off until
that is accepted.

System prompts are not stored in full every turn (hash only). Tool
results are capped. Retrieved Knowledge fences stay untrusted if they
appear in a stored excerpt.

A later retrieve path can read vault `llm-io` behind the same untrusted
fence as Knowledge. Implementing `vector.backend = muninndb` remains a
separate change.
