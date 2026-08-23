# Bug — One transient allocation failure pins a web UI asset to the uncached render path for the process's life

## TL;DR

- **What failed:** RenderCache in src/cli.zig falls through from .failed to rendering again, but the publish cmpxchg only accepts .idle, so a slot that ever reads .failed can never become .ready. .failed is set by the gpa.dupe OOM on the publish path, so one transient allocation failure pins that asset to the uncached path, measured in webui_assets.zig at 348ms and 187KB per request. GzipCache remembers a failure so as not to retry; RenderCache retries, so .failed only blocks the publish. Read from the source.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Unquantified, and only reachable through an allocation failure. If it fires, the
asset is served correctly forever and slowly forever, with no way back short of
a restart and nothing on the page or in the log to say why.

## Reproduction

Not reproduced: it needs `gpa.dupe` to fail on the publish path. Read from the
source.

## Root cause

`RenderCache` reads `.failed` and falls through to rendering again, which is the
right behaviour, but the publish is
`cache.state.cmpxchgStrong(.idle, .rendering, ...)` and `.failed` is not
`.idle`. So the state that means "an attempt failed once" also means "no attempt
may ever publish again". Either `.failed` should be dropped from `RenderCache`,
which does retry, or the publish should accept it.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
