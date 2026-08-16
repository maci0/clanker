# PRD — Automatic sampling profiles (temperature / top_p / reasoning_effort by use case)

## Status

Shipped. `src/llm/sampling_profiles.zig` holds the v1 table. 
`writeSamplingParams` consults it as the last `orelse` after per-run
override and model config. `reasoning_effort` is written there too, so
OpenAI no longer has a second writer. Sources of truth:
`src/llm/sampling_profiles.zig`, `src/llm/providers/common.zig`.

## Problem

Sampling parameters have exactly one source today, in this priority order:
a per-run override (`RunRequest.temperature`/`top_p`, set from the webui
model picker's manual fields, `src/cli.zig:9781-9785`) beats the model's
configured default (`Model.temperature`/`top_p` in `config.toml`), which
beats sending nothing at all (`writeSamplingParams`,
`src/llm/providers/common.zig:54-65`, only writes a field when one of those
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
wiring gap. v1 does not add it; see Non-goals / Open questions.

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
- **`top_k` in v1.** Deferred until a vendor wire-codec matrix exists
  (which configured kinds actually accept `top_k`). Not in Goals, not in
  Acceptance criteria, not in the v1 table.

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

**The table (v1 hardcoded numbers).** A small `sampling_profiles.zig` (or
similar), mapping `(use_case, model.capabilities)` to a
`{temperature: ?f64, top_p: ?f64, reasoning_effort: ?[]const u8}`
recommendation. Keyed off `capabilities` (already on every `Model`, e.g.
`"thinking"` (and `"always_thinking"`), `"tool_use"`, `src/config.zig:186`) rather than provider/model
name. v1 ships a **hardcoded** table (no `config.toml` surface for the
rows):

| use case | capability | temperature | top_p | reasoning_effort |
|---|---|---|---|---|
| chat | non-thinking | `0.7` | `null` | n/a |
| tool_use | non-thinking | `0.0` | `null` | n/a |
| chat | thinking | `null` | `null` | `"medium"` |
| tool_use | thinking | `null` | `null` | `"high"` |

A model whose capabilities include `"thinking"` or `"always_thinking"` gets no
explicit temperature (most reasoning-model APIs reject or ignore it) and a
use-case-appropriate `reasoning_effort` instead; a plain chat-completions model
gets the temperature/`top_p` pair above. The table's "thinking" capability
column includes both strings (`sampling_profiles.hasThinking` treats either as
thinking).

Boundary against [PRD 0020 (auto-thinking)](0020-auto-thinking.md): this PRD
owns writing `reasoning_effort` (the capability-keyed table is the one place
the field's automatic value comes from); 0020's classifier, if built, only
selects which row of the table applies to a turn, and never writes the field
independently.

**Precedence, extended.** `writeSamplingParams`'s existing two-tier check
(`params.temperature orelse params.provider.activeModel().temperature`)
gains a third `orelse`: the use-case table's recommendation for this model's
capabilities. Still: if a user wrote `temperature = 0.2` in `config.toml`,
that value is what ships, exactly as today — the table only fires into the
gap that currently sends nothing.

**Sequencing.** Lands **after** [PRD 0025 (fallback provider chain)](0025-fallback-provider-chain.md).
Both PRDs touch the same four `loop.zig` dispatch sites (`~L544`, `~L549`,
`~L568`, `~L1303`). 0025 owns the call-site restructure (the provider swap
around `client.chat`/`chatStream`) and lands first; this PRD only extends
`writeSamplingParams`'s `orelse` chain and touches no call site.

**`top_k`.** Deferred. Not every wire codec has a slot for it. v1 does not
add `top_k` to the table, `RequestParams`, or any `buildRequest`. Revisit
once a vendor matrix enumerates which configured kinds accept it; until
then, assuming it slots in beside temperature/`top_p` would silently drop
even when set for unsupported vendors.

**Manual controls (Goal 3).** `modelpicker.js`'s temperature/top_p fields
move out of the picker's default view into wherever the web UI's advanced/
power-user surface already lives (e.g. behind a details/disclosure toggle),
rather than being deleted — a user who wants to override a specific run
still can, through the same `RunRequest.temperature`/`top_p` path that
already exists and already wins over any config default. Surface ownership:
this PRD's webui concern is `core/modelpicker.js` (the per-run sampling
fields) only; `features/models.js` (the catalog view and any
config-file-writing surface) belongs to
[PRD 0023 (web UI model configuration)](0023-webui-model-config.md), and
relocating the picker fields must not reach into it.

**Dependencies.**

- Hard: [PRD 0025](0025-fallback-provider-chain.md) lands first (call-site
  restructure around `client.chat`/`chatStream`). This PRD must not reshape
  those sites.
- Soft: [PRD 0020](0020-auto-thinking.md) consumes the table as its
  `reasoning_effort` writer; can land after this PRD's write path exists.
- Existing: `src/llm/providers/common.zig` (`writeSamplingParams`),
  `src/config.zig` (`Model` capabilities / sampling fields),
  `src/agent/loop.zig` (use-case signal), `ui/app/core/modelpicker.js`.

**Implementation.**

1. Add `sampling_profiles.zig` with the hardcoded v1 table above
   (chat/tool_use × thinking/non-thinking).
2. Extend `writeSamplingParams` (`src/llm/providers/common.zig`) with a third
   `orelse` tier that consults the table; ensure `reasoning_effort` is written
   through the shared path (or a clearly owned companion) for thinking rows.
3. Pass use-case (`.chat` / `.tool_use`) from `src/agent/loop.zig` into the
   request params without restructuring the 0025-owned call sites.
4. Relocate webui temperature/top_p fields in `core/modelpicker.js` behind an
   advanced control; do not touch `features/models.js`.
5. Tests: no-config model gets chat vs tool_use defaults; explicit
   `config.toml` temperature unchanged; thinking model gets
   `reasoning_effort` and null temperature; per-run override still wins. No
   `top_k` coverage in v1.

## Failure modes

| Condition | Behavior |
|---|---|
| Model has an explicit `config.toml` `temperature`/`top_p` | Unchanged: that value ships, the use-case table never consulted |
| Model has neither, tools offered this turn | Use-case table's `.tool_use` row for this model's capabilities ships |
| Model has neither, no tools offered | Use-case table's `.chat` row ships |
| Model declares a thinking capability (`"thinking"` or `"always_thinking"`) | Table sends `reasoning_effort` (chat=`medium`, tool_use=`high`), not `temperature` |
| Per-run override set (`RunRequest.temperature`) | Unchanged: still wins over everything, including the use-case table |

## Acceptance criteria

- [x] A model with no configured `temperature`/`top_p` gets the v1 table
      defaults: chat non-thinking → temperature `0.7`, top_p unset; tool_use
      non-thinking → temperature `0.0`, top_p unset. Verified by inspecting
      the built request body in a unit test.
- [x] A model with an explicit `config.toml` `temperature` ships that value
      unchanged regardless of use case.
- [x] A model whose capabilities include `"thinking"` or `"always_thinking"`
      never gets an automatic `temperature`; chat gets
      `reasoning_effort = "medium"`, tool_use gets `"high"`.
- [x] The webui default chat/composer flow no longer shows manual
      temperature/top_p fields; they remain reachable from an explicit
      advanced control.
- [x] No `top_k` field is added to the v1 table, `RequestParams`, or wire
      codecs as part of this work.

## Open questions / future work

- **"Coding" as a third use case, distinct from generic "tool_use".** The
  loop already knows "tools are offered this turn" for free; it does not
  currently know "this is a coding-flavored session" as opposed to, say, a
  research subagent that also happens to call tools. Needs a real signal
  (which tools are in play? a session-level tag? the presence of
  file-editing tools specifically?) before a three-way split is honest
  rather than guessed. Two-way (`chat` / `tool_use`) ships first; revisit
  once a concrete signal exists.
- **`top_k` vendor matrix.** Build an enumeration of which configured wire
  kinds accept `top_k` before adding it to the table. Until then it stays
  out of Goals and AC.
- **Should the use-case table itself be `config.toml`-overridable** (a user
  who disagrees with the shipped defaults can tune the table, not just
  disable it)? Left open; v1 ships the hardcoded table above, which is
  enough to test whether the mechanism helps before deciding it needs to be
  user-tunable too.
- **Revisit the concrete numbers** as vendors change documented guidance.
  The mechanism is stable; the row values are not sacred.
