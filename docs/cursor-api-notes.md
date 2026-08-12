# Cursor's API — the shenanigans (a provider case study)

Cursor is the case that bounds the provider architecture ([ADR 0004](adrs/0004-providers-are-a-native-vtable-not-wasm.md),
[ADR 0005](adrs/0005-auth-is-a-strategy-axis-separate-from-wire-kind.md)). It
looks like it should be an `openai_compat` entry and is nothing of the sort.
These notes are drawn from
[maci0/cursor-openai-api @ fix/cursor-api-compatibility](https://github.com/maci0/cursor-openai-api/tree/fix/cursor-api-compatibility),
a standalone proxy that re-exposes Cursor as a real OpenAI `/v1/chat/completions`
endpoint. The proxy exists precisely because none of the below is OpenAI-shaped.

## Auth: PKCE OAuth with JWT refresh (the `oauth_refresh` strategy, for real)

Not an API key. A browser authorization-code flow:

1. Generate a PKCE challenge/verifier + a UUID; open
   `https://cursor.com/loginDeepControl?challenge=...&uuid=...&mode=login&redirectTarget=cli`.
2. Poll `https://api2.cursor.sh/auth/poll?uuid=...&verifier=...` (up to ~150
   attempts, exponential backoff 1s to 10s) until it returns `accessToken` and
   `refreshToken`, both JWTs.
3. Expiry comes from decoding the JWT `exp` claim minus a 5-minute margin (falls
   back to 1 hour if the decode fails).
4. Refresh: POST `https://api2.cursor.sh/auth/exchange_user_api_key` with
   `Authorization: Bearer <refreshToken>` and an empty body; response carries a
   fresh `accessToken`/`refreshToken` pair.

This is exactly ADR 0005's `oauth_refresh` strategy: a login flow, a stored
refresh token, in-process renewal near expiry. It is the concrete provider that
makes that strategy a real need rather than a hypothetical, and it is the
"genuinely new surface" (a `clanker auth login` subcommand + token store) that
ADR 0005 says to build only when a provider forces it. Cursor forces it.

## Wire: gRPC Connect over HTTP/2, protobuf, not JSON

The extreme end of ADR 0004's codec axis. There is no JSON request body:

- Transport is the **gRPC Connect protocol over HTTP/2**, POST to
  `https://api2.cursor.sh` path `/agent.v1.AgentService/Run`.
- Framing is length-prefixed protobuf: a Connect frame is
  `[1-byte flags][4-byte big-endian length][payload]`.
- The request is a protobuf `AgentClientMessageSchema` wrapping an
  `AgentRunRequestSchema`; OpenAI messages map onto Cursor's schema
  (`UserMessageSchema` with random UUIDs, `ConversationStateStructureSchema`
  for turns/file-state/pending-tools, `ConversationActionSchema`).
- **System prompts do not travel inline.** They go into a SHA256-keyed blob
  store and are referenced from `rootPromptMessagesJson` by hash.
- Streaming responses are Connect frames: a flags byte
  (`CONNECT_END_STREAM_FLAG = 0b10` marks end-of-stream, whose payload is a
  JSON error), server messages are protobuf `AgentServerMessageSchema` decoded
  with `fromBinary`.

## Tools: MCP, not OpenAI `tool_calls`

Tool definitions convert to protobuf `McpToolDefinition`; a tool call arrives as
an `ExecServerMessage` with case `mcpArgs` (arguments are protobuf `Value`
objects); results go back as `McpResultSchema` (`McpSuccessSchema` /
`McpErrorSchema`). Cursor's whole tool vocabulary is MCP, so the adapter is a
protobuf-to-MCP bridge, not an OpenAI `tool_calls` array.

## Session: a stateful HTTP/2 bridge with heartbeats

This is what puts Cursor beyond a stateless request/response transport:

- A **persistent bridge per conversation**, keyed by `SHA256(model + first user
  message)`, kept alive across a multi-turn tool exchange.
- A **heartbeat every 5000ms** (`ClientHeartbeatSchema`); idle timeout capped at
  255 seconds.

## Sanitization Cursor demands (or it rejects the request)

- Max **8 tools** (more returns `resource_exhausted`).
- Tool descriptions truncated to **200 chars**.
- System prompt truncated to **3000 chars** (before the blob-store hashing).
- Consecutive user messages **merged** (Cursor rejects two in a row).

## What this means for clanker

Adding Cursor is not a config-only `openai_compat` line. It needs, in order of
cost:

1. `oauth_refresh` auth (ADR 0005): a PKCE login flow, a token store, JWT-expiry
   renewal. Reusable groundwork for any real-OAuth provider.
2. A protobuf/Connect codec (ADR 0004's per-provider codec, at its most extreme:
   framed protobuf both ways, a blob store, MCP tool translation).
3. A **stateful HTTP/2 bridge with heartbeats**, which the current transport
   core (stateless `chat`/`chatStream` over HTTP/1.1, `src/llm/client.zig`) does
   not have. This is the part the vtable alone does not solve: the shared
   transport core would have to grow an HTTP/2 + long-lived-bridge mode, not
   just a new codec entry.

So Cursor is the honest upper bound on "how modular can providers get": the
codec and auth axes (ADR 0004/0005) absorb the wire-format and credential
divergence, but a provider that needs a persistent bidirectional HTTP/2 session
with heartbeats needs the transport core extended, and that is a much larger
change than adding a provider file. It is documented here rather than
implemented; treat it as the reference for what a maximally hostile provider
integration costs, and note that the standalone proxy above is the pragmatic
alternative (run it, point an `openai_compat` clanker provider at its local
`/v1` endpoint, and none of the above touches clanker at all).
