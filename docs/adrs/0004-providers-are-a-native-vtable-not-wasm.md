# ADR 0004 — Providers are a native vtable, the pure codec is the only WASM-eligible slice

## Status

Accepted.

## Context

A provider today is a `config.ProviderKind` enum (`openai_compat`, `anthropic`,
`vertex_anthropic`) switched on in ~7 places across two files:

- `src/llm/providers.zig` (pure): `buildRequest`, `parseResponse`,
  `parseErrorDetail`, and the streaming-event parse. JSON in, JSON out, no I/O,
  no keys. Already unit-tested per kind.
- `src/llm/client.zig` (trust root): `authHeaders` and `resolveBearer` (read
  `*_API_KEY` env vars, mint GCP tokens via `vertex_token.zig`/`gcp_jwt.zig`),
  the endpoint-path switch, and `chat`/`chatStream` (HTTP + SSE, tool-call
  accumulation, `Agent.on_token` streaming).

Adding a fourth kind means editing every one of those switches, and the three
concerns a provider actually has — **wire codec**, **auth strategy**,
**transport quirks** — are interleaved rather than grouped per provider. That
is the modularity the rethink is after.

The open question was whether to make each provider a WASM module (one per
provider, plus shared modules), the way tools already are. Three constraints
decide it:

1. **Keys must not enter the sandbox.** The whole point of `env_allow` is that
   a WASM tool declaring nothing gets `PWD`/`HOME`/`PATH` and *not* the API
   keys this process loads from `.env`. A provider that does its own HTTP needs
   the key. Handing it in inverts the sandbox: sandboxed code would hold the
   credential the sandbox exists to withhold. `docs/prompts/wasm-review.md`
   already classifies `client.zig` as a trust root that stays native for this
   reason, and `ck_llm` exists precisely so a tool gets model access *without*
   the key (the host does the call).
2. **The transport is on the hottest path.** `chatStream` runs per turn and
   `on_token` per streamed token. A WASM boundary there adds a marshalling hop
   to the one call that already dominates latency and is inherently native
   (raw socket, SSE, a writer the agent loop reads from live).
3. **The pure codec is genuinely movable**, but moving *only* it (leaving auth
   and transport native) buys little: it is already pure, tested, and cheap to
   call as a native function. A WASM hop would serialize the whole request/
   response body twice per call for no capability the native function lacks.

## Decision

Group the per-kind concerns behind a native `Provider` vtable (a struct of
function pointers, resolved once from `ProviderKind`), not a WASM module per
provider. One native file per kind implements `buildRequest`, `parseResponse`,
`parseStreamEvent`, `authHeaders`, and `endpointUrl`; a shared core module
keeps the HTTP/SSE/retry/token-counting transport that every kind uses. Adding
a provider becomes one new file registered in one table, instead of edits to
seven switches.

The pure codec half (`buildRequest`/`parseResponse`/`parseErrorDetail`) stays
native but is written so it *could* become a WASM "codec" module later if a
concrete need appears (a third-party provider format shipped as a plugin, say).
That is deferred, not adopted: nothing today needs an untrusted party to define
a wire format, and until something does, the native function is strictly
cheaper.

## Consequences

- Adding or changing a provider is one file plus one registry line; the three
  concerns live together per provider instead of smeared across switches.
- API keys stay native, so the sandbox invariant (`env_allow` withholds
  credentials from guests) is untouched, and `ck_llm` remains the one way a
  tool reaches a model.
- No per-token marshalling cost: the hot path stays a native call.
- The cost, if the context changes: if we ever want community providers as
  drop-in untrusted plugins, the codec-to-WASM move is available but the auth
  and transport still cannot follow, so such a plugin would define only the
  wire format and lean on a host `ck_llm`-style call for the actual request.
  That is a real limit on "fully pluggable providers," accepted here because
  the alternative leaks credentials into the sandbox.
- Migration is mechanical and low-risk: the switches already isolate the
  per-kind code, so lifting each arm into a vtable entry is a refactor with the
  existing per-kind tests as the safety net. It is not yet done; this ADR
  records the target shape, and `src/llm/` is where it lands.
