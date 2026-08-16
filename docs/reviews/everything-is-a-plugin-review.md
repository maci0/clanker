# Everything-is-a-plugin review log

The repeatable audit lives in
[`docs/prompts/everything-is-a-plugin-review.md`](../prompts/everything-is-a-plugin-review.md)
(`./scripts/clanker-review.sh everything-is-a-plugin` once that directory is
on `--prompts`). Re-run it after a stretch of feature work; append a dated
findings section here and move actionable items into `docs/ROADMAP.md`.

## Findings

### 2026-08-16 (initial)

Full findings in docs/ROADMAP.md under "Everything-is-a-plugin audit
(2026-08-16)". Headline items: the webui plugin registry duplicated
native+guest with diverging fresh-checkout defaults (bug); six
route-to-guest migrations (`workflows` is one line; `schedule` has no
plugin shape at all); advisor and the thinking classifier as the purest
guest extractions; `pluginApi()` missing POST/live-bus/dialogs/workspace/
icons/storage; eleven `provider.kind ==` sites in the proxy; themes and
slash commands as data still shipped as code.
