# PRD — Automatic sampling profiles (temperature / top_p / reasoning_effort by use case)

## Status

Draft. Nothing in this PRD is built yet. Sources of truth once built:
`src/config.zig` (`Model.temperature`/`top_p`/`reasoning_effort`),
`src/llm/providers/common.zig` (`writeSamplingParams`, the only place these
are put on the wire), `src/agent/loop.zig` (where a turn is actually
dispatched, and the one place that knows whether the current turn is a plain
answer or a tool-calling step), `tools/zig/webui/core/modelpicker.js` (today's
manual temperature/top_p controls, `~L175-177`).

## Problem

Sampling parameters have exactly one source today, in this priority order:
a per-run override (`RunRequest.temperature`/`top_p`, set from the webui
model picker's manual fields, `src/cli.zig:9681-9682`) beats the model's
configured default (`Model.temperature`/`top_p` in `config.toml`), which
beats sending nothing at all (`writeSamplingParams`,
`src/llm/providers/common.zig:50-62`, only writes a field when one of those
two is non-null — otherwise the provider's own wire default applies,
whatever that happens to be for that vendor).

Nothing varies by what the turn is actually doing. A model configured with no
`temperature` sends none, whether the current turn is free-form chat or a
tool-calling step deciding which function to invoke and with what
arguments — two situations most providers' own documentation recommends
opposite settings for (low/zero temperature for reliable tool-argument
generation and code edits, higher for open-ended conversation). The only
lever a user has today is hand-setting one fixed `temperature`/`top_p` per
model in `config.toml`, which is a compromise value good for neither case, or
the webui's manual per-run fields (`modelpicker.js`), which puts a
provider-API-level control in front of every user for every run regardless of
whether they have an opinion about it.

`top_k` does not exist anywhere in the codebase today — not in `Model`, not
in `RequestParams` (`src/llm/providers/api.zig:20-29`), not written by any
provider's `buildRequest`. Any design that includes it is new surface, not a
wiring gap.

## Goals

1. A small table of per-use-case sampling recommendations (temperature,
   top_p, reasoning_effort where applicable), keyed by provider/model
   capability class, used as the harness's own default — filling the same
   slot `writeSamplingParams` currently leaves empty when nothing is
   configured, never overriding an explicit `Model.temperature`/`top_p` a
   user set in `config.toml` (goal: strictly additive to the existing
   precedence chain, not a replacement of it).
2. The use case is inferred automatically from the turn being dispatched, not
   asked of the user: a turn with tool definitions in play and a pending tool
   decision is "tool_use"/"coding"; a turn with no tools available or none
   offered is "chat". No new user-facing setting for "which use case am I
   in".
3. The manual temperature/top_p fields currently in the webui model picker
   (`modelpicker.js:175-177`) move out of the default chat flow — available
   somewhere for the user who wants to hand-tune, but not a control every
   user sees on every run.
4. `top_k` is explicitly scoped: added only where a configured provider's
   wire codec actually accepts it (see Design — this varies by vendor), not
   assumed universal.

## Non-goals

- A per-turn UI for picking temperature/top_p at all in the primary chat
  flow. The whole point is these stop being something a normal user
  interacts with per message.
- Overriding a user's explicit `config.toml` `temperature`/`top_p`. The
  existing precedence (per-run override > model config > provider default)
  gains one more tier at the bottom (use-case default), it does not reorder
  the top two.
- A third-party-sourced "recommended settings" feed (e.g. pulling
  temperature recommendations from models.dev the way `providers fill`
  pulls context window and cost). models.dev's schema does not carry
  per-use-case sampling recommendations today; this PRD's table is
  clanker-authored, not fetched. Revisit if that ever changes.
- Per-request use-case override via the API. If `agent.loop.zig` already
  knows the use case from the turn it is building, there is nothing for a
  caller to override; a caller who wants a specific temperature still has
  the existing `RunRequest.temperature`/`top_p` per-run override available
  (Goal 1's "never overrides explicit config" applies here identically — an
  explicit per-run value still wins over the automatic default).

## Design

**Where the use case comes from.** `src/agent/loop.zig` builds every
`client.chat`/`chatStream` call (four call sites: `~L544`, `~L549`, `~L568`,
`~L1303`, plus `~L2333` elsewhere) and already has `self.tool_defs`/whatever
governs whether tools are offered this turn. The signal is binary and already
computed, not new information the harness has to go infer: tools offered
this turn -> `.tool_use`; none offered -> `.chat`. A finer split ("coding"
vs generic "tool_use") needs a real signal to key off — see Open questions;
this PRD's Design section only commits to the two-way split the loop already
has for free.

**The table.** A small `sampling_profiles.zig` (or similar), mapping
`(use_case, model.capabilities)` to a `{temperature: ?f64, top_p: ?f64,
reasoning_effort: ?[]const u8}` recommendation. Keyed off `capabilities`
(already on every `Model`, e.g. `"thinking"`, `"tool_use"`,
`src/config.zig:78-81`) rather than provider/model name, so the same three or
four rows cover every configured model without a per-model entry: a
`"thinking"` model gets no explicit temperature (most reasoning-model APIs
reject or ignore it) and a use-case-appropriate `reasoning_effort` instead; a
plain chat-completions model gets a use-case-appropriate temperature/top_p
pair.

**Precedence, extended.** `writeSamplingParams`'s existing two-tier check
(`params.temperature orelse params.provider.activeModel().temperature`)
gains a third `orelse`: the use-case table's recommendation for this model's
capabilities. Still: if a user wrote `temperature = 0.2` in `config.toml`,
that value is what ships, exactly as today — the table only fires into the
gap that currently sends nothing.

**`top_k`.** Not every wire codec has a slot for it — needs a per-provider
check (does `buildRequest` for this vendor's kind accept `top_k`?) before it
can be part of the recommendation table, or it silently has nowhere to go for
providers whose codec doesn't write it (matching how `temperature`/`top_p`
already silently drop when null, but this would be "drops even when set" for
an unsupported vendor, a different and worse failure mode — see Failure
modes). Scoping this precisely (which of the configured wire kinds actually
accept `top_k`) is real work this PRD defers to Open questions rather than
assuming it slots in beside temperature/top_p for free.

**Manual controls (Goal 3).** `modelpicker.js`'s temperature/top_p fields
move out of the picker's default view into wherever the web UI's advanced/
power-user surface already lives (e.g. behind a details/disclosure toggle),
rather than being deleted — a user who wants to override a specific run
still can, through the same `RunRequest.temperature`/`top_p` path that
already exists and already wins over any config default.

## Known issues

None — draft, nothing built yet.

## Failure modes

| Condition | Behavior |
|---|---|
| Model has an explicit `config.toml` `temperature`/`top_p` | Unchanged: that value ships, the use-case table never consulted |
| Model has neither, tools offered this turn | Use-case table's `.tool_use` row for this model's capabilities ships |
| Model has neither, no tools offered | Use-case table's `.chat` row ships |
| Model declares `"thinking"` capability | Table sends `reasoning_effort` (if the row has one), not `temperature` — matches existing DeepSeek-style handling (`common.zig`'s own doc comment: temperature and top_p narrow the same distribution, adjust one) |
| `top_k` requested for a provider whose codec doesn't write it | Silently has no effect (matches how an unsupported/unwritten field already behaves for other params) — must not be mistaken for "was applied"; UI/logging should not claim it took effect if it can't verify the wire codec accepts it |
| Per-run override set (`RunRequest.temperature`) | Unchanged: still wins over everything, including the use-case table |

## Acceptance criteria

- [ ] A model with no configured `temperature`/`top_p` gets a use-case-
      appropriate default when tools are offered vs. not, verified by
      inspecting the built request body in a unit test (mirrors how
      `common.zig`'s existing sampling-param tests work today).
- [ ] A model with an explicit `config.toml` `temperature` ships that value
      unchanged regardless of use case.
- [ ] A `"thinking"`-capability model never gets an automatic `temperature`,
      only (optionally) `reasoning_effort`.
- [ ] `top_k` is only ever written for a provider wire kind whose codec
      declares support for it; a test enumerates the configured kinds and
      confirms which do.
- [ ] The webui default chat/composer flow no longer shows manual
      temperature/top_p fields; they remain reachable from an explicit
      advanced control.

## Open questions / future work

- **"Coding" as a third use case, distinct from generic "tool_use".** The
  loop already knows "tools are offered this turn" for free; it does not
  currently know "this is a coding-flavored session" as opposed to, say, a
  research subagent that also happens to call tools. Needs a real signal
  (which tools are in play? a session-level tag? the presence of
  file-editing tools specifically?) before a three-way split is honest
  rather than guessed. Two-way (`chat` / `tool_use`) ships first; revisit
  once a concrete signal exists.
- **Where do the table's actual numbers come from?** This PRD proposes the
  mechanism (a capability-keyed table, consulted as the last tier of
  existing precedence) but not the specific recommended values — those
  should be sourced from each vendor's own documented guidance at
  implementation time, not invented here, and will need periodic revisiting
  as vendors change their own recommendations.
- **Should the use-case table itself be `config.toml`-overridable** (a user
  who disagrees with the shipped defaults can tune the table, not just
  disable it)? Left open; the simplest version of this PRD ships a
  hardcoded table with no config surface, which is enough to test whether
  the mechanism helps before deciding it needs to be user-tunable too.
