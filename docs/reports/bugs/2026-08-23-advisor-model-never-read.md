# Bug — advisor.model is parsed, documented and never read, so every critique bills the main model

## TL;DR

- **What failed:** cfg.advisor.model was declared, range-checked, listed in warnUnknownKeys and documented in docs/configuration.md and PRD 0015 as the cheap-model knob, while advisor.review resolved only advisor.provider. Every enabled-advisor turn therefore ran the 256-token critique on the provider's default_model: the main, expensive model. Fixed by copying the provider and setting default_model, the same shape thinking.resolveClassifier already uses.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. review copies the provider and sets default_model from cfg.advisor.model; pinned by a mock-server wire-capture test with the empty-model control, and live-verified against deepseek-v4-flash.

## Status

Resolved on 2026-08-23. review copies the provider and sets default_model from cfg.advisor.model; pinned by a mock-server wire-capture test with the empty-model control, and live-verified against deepseek-v4-flash.

## Symptom and impact

`[advisor] model` is the whole reason the key exists. `docs/configuration.md`
lists it under `[advisor]` as "Model name on that provider", and PRD 0015's
example config annotates it `model = "gpt-4o-mini"  # cheap fast model;
billing separate from main agent`. It parses (`src/config.zig:3008`), it is
range-checked, and it is in `warnUnknownKeys`' allowlist (`src/config.zig:3005`)
so setting it produces no warning at all.

Nothing read it. With `advisor.enabled = true`, every completed tool batch ran
a 256-completion-token critique on the *main* model, at the main model's price,
for the whole run. The one knob whose job is to keep that cheap was inert and
silent about it.

## Reproduction

Set an advisor on a provider whose `default_model` is expensive and name a
cheap model:

```toml
[advisor]
enabled = true
provider = "deepseek"
model = "deepseek-v4-flash"
```

Run any task that calls a tool, then read `state/token_stats.jsonl`: the extra
records carry the provider's `default_model`, never `deepseek-v4-flash`.

## Root cause

`src/agent/advisor.zig` resolved the provider and stopped there:

```zig
const provider = cfg.provider(if (cfg.advisor.provider.len > 0) cfg.advisor.provider else null) catch |err| { ... };
```

`Config.provider` is a plain table lookup returning `*const Provider`; nothing
downstream applies `cfg.advisor.model`. `grep -rn "advisor.model" src/` found
exactly two hits, both in `config.zig`: the declaration and its parser.

The correct pattern was already two files away in `src/agent/thinking.zig`
(`resolveClassifier`), which shallow-copies the provider and reassigns
`default_model`.

## Resolution

`src/agent/advisor.zig` `review` now copies the resolved provider and sets
`default_model` to `cfg.advisor.model` when it is non-empty. The copy is
shallow and only `default_model` is reassigned, which is the safe shape here:
`put`ting into a shallow copy's `models` map would alias the global config's
map. A model name with no `[models."<provider>/<name>"]` entry is not fatal (it
still goes on the wire, exactly as `default_model` would) but is now logged at
debug, because a typo otherwise reads as "the provider rejected the advisor".

## Verification

- New unit test `review sends advisor.model, not the provider's default model`
  in `src/agent/advisor.zig`. It stands up a loopback mock provider and asserts
  the `model` field of the body the server actually received, rather than
  reading the call chain. It carries the control on the other side too: with
  `advisor.model` empty, the provider's `default_model` is what ships.
- `clanker gate` green.
- Live, both sides of the branch, one tool-using run each against a
  `deepseek-v4-pro` main model. `state/token_stats.jsonl`, `advisor.model =
  "deepseek-v4-flash"`:

  ```
  deepseek-v4-pro    prompt=24161 compl=91
  deepseek-v4-flash  prompt=233   compl=256   <- the critique
  deepseek-v4-pro    prompt=25036 compl=3
  ```

  and the control, `advisor.model` unset:

  ```
  deepseek-v4-pro    prompt=24513 compl=72
  deepseek-v4-pro    prompt=233   compl=256   <- the critique, main model
  deepseek-v4-pro    prompt=25017 compl=3
  ```

  Same 233/256 shape in both, so the record is identifiable; only the model
  moved.

## Follow-up

`advisor.scope` / `advisor.context_turns` were not audited by this fix.

## References

- PRD: [0015-advisor.md](../../prds/0015-advisor.md)
- Docs: `docs/configuration.md` `[advisor]`
- Code: `src/agent/advisor.zig` (`review`), `src/agent/thinking.zig`
  (`resolveClassifier`, the pattern it now matches)

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
