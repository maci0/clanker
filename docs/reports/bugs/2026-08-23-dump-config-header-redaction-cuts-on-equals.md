# Bug — dump-config leaks the secret half of any header whose value contains an equals sign

## TL;DR

- **What failed:** writeKvNames in src/config.zig serves both the env and headers lists and cuts at the first equals sign before trying the colon, unconditionally. A header's separator is the colon, so any equals inside the value wins and the cut lands past the secret: a Basic credential ending in base64 padding is dumped almost whole. Any padded token or signature header is the same. The existing test uses a value with no equals sign, so it passes.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed in ac242be4; writeKvNames now takes the separator from the caller (':' for headers, '=' for env) and the redaction test carries a base64-padded Basic credential. Verified by clanker gate (11/11 PASS) and by a live --dump-config over an mcp_servers entry with '=' in both a header and an env value.

## Status

Resolved on 2026-08-24. Fixed in ac242be4; writeKvNames now takes the separator from the caller (':' for headers, '=' for env) and the redaction test carries a base64-padded Basic credential. Verified by clanker gate (11/11 PASS) and by a live --dump-config over an mcp_servers entry with '=' in both a header and an env value.

## Symptom and impact

`--dump-config` redacts the value half of `[providers.*]` `env` and `headers`
entries by printing only the part before the separator. One function serves both
shapes and picks the separator as "first `=`, else first `:`", unconditionally.

`env` entries are `NAME=value`, so `=`-first is right. `headers` entries are
`Name: value`, so any `=` *inside the value* wins and the cut lands past the
secret. A `Basic` credential is base64 and therefore frequently `=`-padded:

```toml
headers = ["Authorization: Basic dXNlcjpwYXNzd29yZA=="]
```

dumps as `"Authorization: Basic dXNlcjpwYXNzd29yZA"` — the whole credential,
one padding character short, on stdout. Any padded bearer token or an
`X-Signature: …=` header is the same shape.

The existing test uses `"Authorization: Bearer tok_very_secret"`, which contains
no `=`, so it passes and the branch is never exercised on a value that would
fail.

## Reproduction

Put the header above in `config.local.toml` and run `clanker --dump-config`.

## Root cause

One separator-detection expression shared by two formats whose separators are
different, with the wrong one preferred.

## Resolution

Open. Pass the separator in from the caller, which already knows which field it
is dumping: `':'`-first for `headers`, `'='`-first for `env`. The test wants a
header value containing `=` on both sides of the fix.

## Verification

Needs the existing dump-config redaction test extended with an `=`-bearing
header value.

## Follow-up

Lower confidence, same surface: `McpServer.args` and `McpServer.url` are dumped
verbatim, so a stdio server configured with `args = ["-y","srv","--api-key",
"sk-…"]`, or an HTTP server with a token in the URL query, leaks through
`--dump-config`. PRD 0042's non-goal ("API keys stay env-based") partly excuses
it, but the redaction of `env`/`headers` right beside it shows the intent.

## References

- PRD: [0042-config-profiles-profile-and-dump-config-file-overlay.md](../../prds/0042-config-profiles-profile-and-dump-config-file-overlay.md)
- Code: `src/config.zig` (`writeKvNames` and its caller's `env`/`headers`
  dispatch)

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
