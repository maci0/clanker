# PRD — Composer @path mention expander

## Status

In progress — REPL half shipped 2026-08-21 (helper + submit expansion), mid-run steer expansion 2026-08-24; web composer and @ completion picker open. Source of truth: tools/zig/mention_expand.zig (expandAlloc) + src/tui/repl.zig (expandComposerMentions, the single pre-send transform for composer text). Decision: [ADR 0041](../adrs/0041-composer-path-mentions-expand-through-a-host-tested-helper.md). RFC: [0029](../rfcs/0029-file-mentions.md).

## Problem

The composer cannot hand a file to the model without paste or a follow-up read_file. Kimi @path does it in the message.

## Goals

1. A host-tested expander inlines whitespace-bounded @rel/path into fenced bytes.  2. secret_dotenv and out-of-prefix paths are refused.  3. A byte cap truncates with a notice.  4. REPL submit calls the expander.  5. Tests drive expandMentions.

## Design

**Parser.** expandMentions(text, readFile) walks the user text. A mention is @ then a relative path token after start-of-string or whitespace. Email-shaped tokens (alnum@alnum) are left alone. Paths with .. or absolute / are refused.

**Read.** readFile returns bytes or a refuse reason. secret_dotenv names are refused (same module as safeJoin). Missing files stay as the @token with no expansion.

**Cap.** Per mention 32 KiB, truncated on a UTF-8 boundary with a notice line. Whole expansion 256 KiB.

**Session.** The expanded text is the saved user message (ADR 0041).

**Dependencies.** Hard: ADR 0041, src/util/secret_dotenv.zig, src/tui/repl.zig submitTask. Soft: web composer.

**Implementation.**

1. implement-now: helper + tests + REPL submit. Files: tools/zig/mention_expand.zig (create), build.zig host_tested_helpers, src/tui/repl.zig (edit).
2. later: web composer. Files: ui/app/core/composer.js.
3. later: @ completion picker. Files: src/tui/repl.zig.

## Non-goals

TUI completion UI (phase 3). Image mentions (PRD 0041). Directory expansion. Forged tool results (RFC 0029 option B).

## Failure modes

| Condition | Behaviour |
|---|---|
| @user@host | left unchanged |
| @.env | refused, token stays, notice |
| missing file | token stays |
| file > 32 KiB | truncated with notice |
| message expansion > 256 KiB | the straddling mention is truncated; later mentions stay bare tokens with a notice |
| no @ tokens | text unchanged |

## Acceptance criteria

1. [x] @src/foo.zig in a message becomes a fenced block of that file (Goal 1, Goal 4)
2. [x] @.env is not inlined (Goal 2)
3. [x] a 40 KiB file is truncated (Goal 3)
4. [x] Tests call expandAlloc (Goal 5)
5. [x] Email a@b.com is unchanged (Goal 1)
6. [x] Nine 32 KiB mentions in one message inline eight and leave the
   ninth a bare token with a notice (Goal 3)
7. [x] The same `@path` line expands identically whether the composer is idle
   or acting as the mid-run steer box (PRD 0058). Criterion 1 is written about
   the composer and was read as covering this; it did not, because
   `steerWhileRunning` duped the text through with no expansion and no refuse
   rules. Both paths now go through one `expandComposerMentions`.

## Open questions / future work

Web composer and completion picker are later phases, not blockers.

## Known issues

- **(Fixed) A mention of a file over the cap used to be dropped, not
  truncated.** The Failure modes row promises "file > 32 KiB | truncated with
  notice" and acceptance criterion 3 was checked against a helper-level test
  with a synthetic reader. The REPL's own reader was
  `readFileAlloc(.limited(per_file_cap + 1))`, and that limit answers
  `error.StreamTooLong` when it is reached or exceeded, so every file at or
  over the cap read as unreadable and the mention stayed a bare `@path` token
  with no fenced block and no notice. `readMentionFile` (`src/tui/repl.zig`)
  now reads a bounded prefix with `readSliceShort` instead. Design also said
  "truncated on a UTF-8 boundary" while `expandAlloc` cut at a raw byte
  offset; `capUtf8` in `tools/zig/mention_expand.zig` backs the cut up to a
  codepoint boundary so the request body and the saved session stay valid
  UTF-8.
- **(Fixed) The whole-expansion 256 KiB cap in Design was not implemented.**
  `expandAlloc` (`tools/zig/mention_expand.zig`) enforced `per_file_cap` per
  mention and nothing across the message, so N mentions expanded to N x 32 KiB
  with no ceiling and no notice. It now carries a `spent` running total
  against `total_cap`: each mention gets `@min(per_file_cap, total_cap -
  spent)`, so the mention that straddles the ceiling is truncated with the
  usual `[truncated]` notice and everything after it stays a bare token with
  `[mention not expanded: <path>: message expansion cap reached]`. The budget
  counts inlined file bytes only; the fences, the notices and the user's own
  prose are bounded by the message itself.
