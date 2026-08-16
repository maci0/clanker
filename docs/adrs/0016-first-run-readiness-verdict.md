# ADR 0016: First-run is one doctor verdict on existing empty surfaces

## Status

Accepted. Records the choice in
[RFC 0005](../rfcs/0005-first-run-onboarding.md).

## Context

First-run (binary exists, no successful turn yet) is split across
`clanker init`, `clanker setup`, `clanker doctor`, a `serve` URL, a
blank REPL, and four Chat chips that assume this checkout is the
clanker source tree. `setup` already diagnoses the real failure
(default provider has no credential, another one does) but only on
stdout. Chat is a co-equal surface (PRD 0006) and never sees that
sentence.

RFC 0005 compared a shared readiness verdict on existing empty
plates (A), an interactive wizard that collects a key (B), status
quo (C), and retargeting the chips with no new contract (D). B
fights the env-var key policy. D leaves the missing-key case as a
toast after the operator has already committed a turn. C keeps
lying chips on every other folder.

## Decision

Option A. Doctor's offline checks become one structured verdict
(`ready` / `blocked`, blockers with a next action). `setup` and
`doctor` keep printing it. `GET /api/status` grows those fields
additively (omit when ready). Chat's empty plate, the REPL first
paint, and the serve banner consume the first blocker or, when
ready, folder-generic first-turn chips.

First-run ends when identity exists, the default provider is
usable, guest wasm is present, and any surface has completed a
turn that returned model content. That write is
`state/onboarding.json`. A failed turn (401, missing wasm) does
not dismiss. A quiet skip is allowed. Serve still starts when
blocked; the URL is how the operator sees the plate.

The composer stays enabled. No new command, rail tab, wizard, or
key paste. `local_template`'s DeepSeek default is unchanged.
`providers check` stays a separate, network-using command.

The chip rewrite (D) is the first patch of A, not a substitute.

## Consequences

A serve user sees the same next action `setup` already prints,
without leaving Chat. Suggestions work in any folder. After one
successful turn the plate is gone; later empty chats are "New
conversation" only.

`/api/status` gains a readiness meaning. Clients must treat
`ready` / `blockers` as optional. Deleting `state/onboarding.json`
brings first-run back.

A later Models or System view can reuse the verdict. It must not
grow a second doctor. Changing the committed default provider is
a different decision.
