# Bug — Vertex error bodies reach the operator as a bare HTTP status: the Google error envelope is parsed by no codec and unrecognised bodies are discarded

## TL;DR

- **What failed:** The vertex kinds reused their publisher codec's error parser, which cannot read Google's platform envelope in its array-wrapped rawPredict form, and both HTTP error paths dropped any body no codec recognised — every google-vertex-anthropic failure surfaced as a bare HTTP 400. Fixed: shared parseGoogleErrorMessage (object + array), tried first by both vertex kinds; an unrecognised body is logged capped at warn, callers keep the bare status.
- **Impact:** google-vertex-anthropic failed 4/4 improve-self attempts across a session with every failure reported as a bare "HTTP 400"; the one line in which Google names the actual problem was discarded, so the outage could not be root-caused and the investigation stalled for a day.
- **Resolution:** Resolved on 2026-08-19. parseGoogleErrorMessage (object + array envelope) tried first by both vertex kinds, and httpErrorDetail logs a capped snippet of any body no codec recognised; verified by three new unit tests and a green zig build test (1691/1702, 11 skipped)

## Status

Resolved on 2026-08-19. parseGoogleErrorMessage (object + array envelope) tried first by both vertex kinds, and httpErrorDetail logs a capped snippet of any body no codec recognised; verified by three new unit tests and a green zig build test (1691/1702, 11 skipped)

## Symptom and impact

Every request to the operator's `google-vertex-anthropic` provider failed as
`HTTP 400` in ~150-400ms, with no further detail anywhere — not in the
terminal, not in the log, not in `token_stats.jsonl`'s `err` field. A 400
that fast carries a response body in which Google names the rejected field
or the unfulfilled precondition; nothing surfaced it, so
docs/reports/investigations/2026-08-19-vertex-anthropic-400.md could record
only "not root-caused; response body not logged" while the default provider
stayed down.

## Reproduction

Deterministic at the unit level, no GCP project needed:
`httpErrorDetail` (src/llm/client.zig) with the `vertex_anthropic` codec and
the array-wrapped envelope Vertex `rawPredict` answers with —

```json
[{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}]
```

— returned `HTTP 400` before the fix and returns
`HTTP 400: INVALID_ARGUMENT: Request contains an invalid argument.` after;
the new tests in client.zig, vertex.zig and common.zig pin exactly this.

## Root cause

Two layered omissions:

1. **The vertex kinds parsed errors with their publisher's codec only.**
   `vertex_anthropic` set `parseErrorDetail = anthropic.provider.parseErrorDetail`,
   and `vertex` tried gemini's then anthropic's. A Vertex deployment answers
   in two error dialects: the *model publisher's* (Anthropic's
   `{"type":"error","error":{...}}`), and the *platform's* — Google's
   `{"error":{"code","message","status"}}`, which `rawPredict` wraps in a
   one-element array. Anthropic's parser happens to read the object form
   (`ignore_unknown_fields` plus a matching `error.message` field), but the
   array form fails `parseFromSliceLeaky` into a struct and returned null.
   Platform-side refusals — quota, IAM, project/model addressing, exactly the
   class a fast 400-on-every-request belongs to — are the ones in that
   envelope.
2. **A body no codec recognised was discarded outright.** Both the
   non-streaming (`doFetch`) and streaming (`chatStream`) HTTP >= 400 paths
   set `err_detail` to the bare status when `parseErrorDetail` returned null
   and dropped the body on the floor, by deliberate policy ("never surface
   the complete raw body") with no logging fallback of any kind.

The request-building side was checked and is not implicated:
`anthropic.buildBody` with `anthropic_version = vertex-2023-10-16` correctly
omits `model` from the body, and `endpointUrl` addresses the model in the
URL, so the every-request 400 is not a malformed-body bug in this tree.

## Resolution

- `common.parseGoogleErrorMessage` reads Google's envelope in both the
  object and the array-wrapped form and renders `STATUS: message`.
- Both vertex kinds try it first: `vertex.zig` gains its own
  `parseErrorDetail` (Google, then Anthropic), `vertex_ai.zig` prepends it
  to its gemini→anthropic chain.
- The two HTTP error paths share a new `httpErrorDetail` helper: parsed
  message when a codec recognises the body, bare status otherwise — but an
  unrecognised non-empty body is now logged at warn, capped to
  `redact.max_log_detail_len` (256), whitespace-flattened, and only when
  valid UTF-8. The caller-facing string still never carries raw body bytes,
  preserving the redaction policy.

## Verification

- `zig build test`: green, 323/323 steps, 1691/1702 passed (11 skipped),
  including the three new tests: `parseGoogleErrorMessage reads the object
  and array envelopes` (common.zig), `vertex parseErrorDetail reads Google's
  envelope and Anthropic's` (vertex.zig), and `httpErrorDetail keeps the
  parsed message and never the raw body` (client.zig).
- The operator-side 400 itself is not reproducible from this environment
  (no GCP credentials here); what is verified is that the next occurrence
  names itself: the detail string now carries Google's status and message
  through `err_detail`, the error log line, and `token_stats.jsonl`.

## Follow-up

- When the next google-vertex-anthropic failure occurs with this fix in
  place, read the surfaced message and close
  docs/reports/investigations/2026-08-19-vertex-anthropic-400.md's remaining
  question (why that deployment rejects requests). The mixed evidence
  already recorded there (HTTP 400 runs 1-2 and 4, network-level WriteFailed
  run 3) points at the environment rather than the request encoder, which
  matches the encoder check above.

## References

- Investigation: [google-vertex-anthropic returns HTTP 400 on every request](../investigations/2026-08-19-vertex-anthropic-400.md)
- `src/llm/providers/common.zig` — `parseGoogleErrorMessage`.
- `src/llm/providers/vertex.zig`, `src/llm/providers/vertex_ai.zig` —
  per-kind `parseErrorDetail` chains.
- `src/llm/client.zig` — `httpErrorDetail`, shared by `doFetch` and
  `chatStream`.
