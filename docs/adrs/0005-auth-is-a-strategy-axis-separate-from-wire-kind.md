# ADR 0005 — Auth is a strategy axis, separate from the wire kind

## Status

Accepted. Extends [ADR 0004](0004-providers-are-a-native-vtable-not-wasm.md)
(the provider vtable); this ADR is about one of its entries, `authHeaders` /
credential acquisition.

## Context

A provider's auth is not one-per-`ProviderKind`. The code already proves it:

- **Anthropic picks the method from the token shape.** `isOauthToken` in
  `client.zig` matches the `sk-ant-oat` prefix; an OAuth access token goes on
  `Authorization: Bearer` with an `anthropic-beta: oauth-...` header, a plain
  key goes on `x-api-key`. Same wire kind, two auth paths, chosen by inspecting
  the credential.
- **Vertex mints a GCP OAuth token** from `service_account_file`
  (`vertex_token.zig`), cached until it nears expiry, or takes an env override.
- **openai_compat is bearer-only** today.

Many providers offer both an API key and OAuth. xAI is the example: the model
API is `openai_compat` over `https://api.x.ai/v1`, and the credential can be a
static `xai-...` API key or an OAuth access token, both presented as
`Authorization: Bearer <credential>`.

So the real shape is `(wire kind) x (auth strategy)`. Baking auth into the kind
switch means every new provider that supports two methods multiplies the
switch, and a provider like xAI that is `openai_compat` for the wire but needs
an OAuth path has nowhere clean to put it.

Two things are being conflated and must be split:

1. **Credential acquisition** — where the secret comes from: an env var, a
   pasted OAuth access token, or a minted-and-refreshed token. This is the part
   that differs and is worth a strategy.
2. **Header application** — how the resolved credential rides the request:
   `Authorization: Bearer` (openai_compat, vertex, anthropic-oauth) or
   `x-api-key` (anthropic-key), plus any beta header. This is a small per-wire-
   kind detail, not a strategy of its own.

## Decision

Make auth a strategy axis in the provider vtable, distinct from the wire kind.
A config field selects it, defaulting to auto-detection from the credential
shape where tokens are distinguishable (keeps Anthropic's zero-config
behaviour), with an explicit `auth = "..."` override to disambiguate:

- `api_key` — read `api_key_env`, apply per the wire kind (`Bearer` for
  openai_compat/vertex, `x-api-key` for anthropic).
- `oauth_static` — a pasted OAuth access token (env var or a stored file),
  applied as `Bearer`, plus any provider beta header. This is what Anthropic's
  `sk-ant-oat` path already is, generalized.
- `oauth_refresh` — an authorization-code flow with a cached refresh token,
  minted and renewed in-process. `vertex_token.zig` is the existing instance
  of this pattern (GCP-specific); the general form is a `clanker auth login
  <provider>` subcommand that runs the flow once and stores the refresh token,
  with the client renewing the access token near expiry the way vertex already
  does.

Credential acquisition is the strategy; header application stays a per-wire-kind
detail the codec/transport already owns.

## Consequences

- Adding a provider with two auth options is two small vtable entries, not a
  multiplied switch. A provider that is `openai_compat` for the wire (xAI) can
  carry an OAuth strategy without a new wire kind.
- **xAI, concretely.** The API-key path works today with no new code:
  `kind = "openai_compat"`, `base_url = "https://api.x.ai/v1"`,
  `api_key_env = "XAI_API_KEY"` already produces `Authorization: Bearer`.
  Adding OAuth adds only *credential acquisition* (obtain and refresh the
  token), not a new header path, because both methods end as `Bearer`. That is
  the payoff of splitting the two concerns.
- **Static vs refresh is the real cost boundary.** `oauth_static` (a pasted
  token) is cheap: it is the Anthropic path generalized, no new subsystem. A
  full `oauth_refresh` flow (a `clanker auth login` subcommand, a token store,
  background renewal) is genuinely new surface and should be built only when a
  provider actually requires it, not speculatively. Vertex is the one provider
  that needs minting today and already has its own path; folding it into a
  generic `oauth_refresh` strategy is a later cleanup, not a prerequisite.
- Auto-detect keeps zero-config working but is only safe where a provider's
  two credential types are distinguishable (a prefix like `sk-ant-oat`). Where
  they are not, the explicit `auth =` field is required, and the default should
  fail loudly rather than guess wrong and send a token on the wrong header.
- Auth stays native (ADR 0004): the token is a secret, and resolving or minting
  it is exactly what the sandbox withholds from guests.
