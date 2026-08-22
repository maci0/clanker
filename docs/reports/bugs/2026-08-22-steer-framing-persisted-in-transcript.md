# Bug — Steer framing sentence is persisted as the user's own words

## TL;DR

- **What failed:** handleSteer (src/cli.zig) and TUI steerWhileRunning (src/tui/repl.zig) prefix each steering message with the '[The user interjected...]' framing sentence, and the run saves that framed text verbatim as a role=user message in the session file. Every transcript consumer shows the harness's framing as user-typed text; the webui also split the turn there. Webui render side fixed 2026-08-22 via client-side detection, but the stored shape is the defect.
- **Impact:** Every transcript consumer (web UI, exports, session search, the FTS index, mesh replication) reported the harness's framing sentence as words the user typed.
- **Resolution:** Resolved on 2026-08-22. The framing moved out of both senders into agent/loop.zig applySteerFraming, applied to the request copy only; the saved message keeps the user's own words plus types.Message.steered, persisted as a new session-store column and emitted by GET /api/sessions/<id>. Verified by zig build test (exit 0, four new tests), node --test ui/app/core/steer.test.mjs, and clanker gate all PASS.

## Status

Resolved on 2026-08-22. The framing moved out of both senders into agent/loop.zig applySteerFraming, applied to the request copy only; the saved message keeps the user's own words plus types.Message.steered, persisted as a new session-store column and emitted by GET /api/sessions/<id>. Verified by zig build test (exit 0, four new tests), node --test ui/app/core/steer.test.mjs, and clanker gate all PASS.

## Symptom and impact

`POST /api/steer` (handleSteer, src/cli.zig) and the REPL composer during a
turn (steerWhileRunning, src/tui/repl.zig) each built the queued message as
the framing sentence plus the user text:

    [The user interjected while this run was in progress; take the message
    into account and adjust course.]

    <what the user typed>

The agent loop appended that string to `messages` as `role=user`, and
`messages` is what `saveSession` writes. So the harness's own sentence was
stored as the opening line of a user turn, and every transcript consumer --
the web UI transcript, `clanker session export`, session search, the FTS
index, mesh replication -- reported it as text the user typed. The web UI
additionally split the turn there, closing the real question as unanswered;
that render side was patched on 2026-08-22 by detecting the sentence
client-side, which left the stored shape as the defect.

## Reproduction

Start a streaming run, interject, and read the saved transcript back:

    clanker serve &
    curl -sX POST localhost:8080/api/run -d '{"task":"count to 200 slowly","session":"steer-demo","stream":true}' &
    curl -sX POST localhost:8080/api/steer -d '{"session":"steer-demo","message":"cite the source"}'
    curl -s localhost:8080/api/sessions/steer-demo | jq '.messages[] | select(.role=="user")'

Before the fix the last user message reads `[The user interjected ...]\n\ncite
the source`. After it, `content` is `cite the source` and the message carries
`"steered": true`.

## Root cause

The framing was applied by each sender, at enqueue time, to the message text
itself -- so it entered the transcript through the same field the user's own
words travel in, and nothing downstream could tell the two apart. It was also
duplicated verbatim in two senders plus a third copy in the web UI's detector.

## Resolution

The framing is now applied in one place, to the request copy only:

- `agent/loop.zig` owns `steer_frame_sentence` and `applySteerFraming`, which
  `requestMessages` runs over the arena copy alongside the existing tool-result
  pruning. Senders queue the user's words alone.
- `types.Message.steered` marks a message as interjected. It persists: a new
  `steered` column on the session store's `messages` table, migrated onto
  existing databases by `added_message_columns` (an ALTER on every open,
  duplicate-column error swallowed, because `CREATE TABLE IF NOT EXISTS` never
  touches a table that already exists).
- Because the flag survives a reload, the framing is re-applied identically on
  every later turn, so the bytes sent to the provider are unchanged and no
  request prefix is rewritten (the prompt-cache rule in AGENTS.md).
- `GET /api/sessions/<id>` emits `steered` on the message, and the web UI
  (`ui/app/core/steer.js` `steeredText`) reads the flag, falling back to the
  framing-sentence detection so transcripts saved before this change still
  render their interjections as interjections.

A mid-conversation `role=system` message was rejected as the alternative:
`anthropic.zig` and `gemini.zig` hoist system messages into the top-level
system field, which would detach the framing from the interjection it frames.

## Verification

- `zig build test` -- exit 0, with four new tests: framing lands on the request
  copy and not the stored message; the framed bytes are identical across a
  save/load round trip; a steered message round-trips as the user's own words
  plus the flag; a database written before the column still opens, migrates and
  saves. The migration test was checked to fail with the ALTER disabled.
- `node --test ui/app/core/steer.test.mjs` -- 9 pass, covering the flag path
  and the legacy framing-sentence path.
- `clanker gate` -- build, tests, tools, fmt, lint, provider-kind,
  test-root-coverage, sandbox-abi, tools-ts-toolchain, release-contract all
  PASS.

## Follow-up

- The token estimate in `maybeCompactMessages` counts the stored (unframed)
  text, so a steered message is under-counted by the framing sentence
  (~25 tokens, capped at 16 interjections per run). Not corrected here.

## References

- Investigation: none yet
