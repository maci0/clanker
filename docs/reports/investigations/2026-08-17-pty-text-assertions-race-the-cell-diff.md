# Investigation — pty e2e text assertions race vaxis's cell diff

## TL;DR

- **Question:** Can a pty e2e journey assert a string was drawn by searching the escape-stripped byte stream?
- **Finding:** Not on a repainted row: vaxis diffs cell-by-cell, so a row whose content replaces another reaches the stream as fragments (only the changed cells are written — 'serch <query> ech savedcnversations'), and blank cells may be cursor-jumped rather than written, dropping word gaps unpredictably.
- **Resolution:** Resolved on 2026-08-17. Resize-then-despaced-match pattern shipped in tests/e2e/pty_preview_test.zig with shared plumbing in tests/e2e/pty.zig; verified by zig build e2e exit 0 (26/26, including the new journey)

## Status

Resolved on 2026-08-17. Resize-then-despaced-match pattern shipped in tests/e2e/pty_preview_test.zig with shared plumbing in tests/e2e/pty.zig; verified by zig build e2e exit 0 (26/26, including the new journey)

## Trigger and scope

Writing tests/e2e/pty_preview_test.zig (inline slash-command preview journey): the third step retypes the draft so a different command's preview row replaces the one already drawn, and the assertion on 'search saved conversations' timed out despite the row being visibly correct in a live terminal.

## Evidence

Reproduced outside the test with a python pty harness: after Ctrl-U + '/search embedded cache' over a screen already showing the /goal row, the stripped stream contains only 'serch <query> ech savedcnversations (resume with --session)' — exactly the cells that differ from '/goal <completion condition> start a goal loop until achieved or blocked' at the same columns. Earlier steps passed only because their rows were previously empty (full non-blank repaint). A separate run showed 'Typeatasktobegin' — blank cells skipped via cursor jumps, so word gaps are not reliably in the stream either.

## Hypotheses and tests

Not a preview defect: the same build renders correctly on a live terminal, and the fragment is a strict positional diff of old vs new row text. Forcing a repaint (TIOCSWINSZ one row larger) makes the full row text arrive; despaced matching survives the blank-cell skips. Both applied, the journey passes deterministically (zig build e2e green).

## Finding

Asserting drawn text against a pty byte stream is only sound immediately after a full repaint, and only with spaces stripped from both sides; a diffed frame carries fragments of changed cells, not rows.

## Resolution or handoff

tests/e2e/pty.zig now carries the shared pty plumbing (openPty, spawnRepl, answerQueries, pump); pty_preview_test.zig demonstrates the resize-then-despaced-match pattern, and AGENTS.md's Build & test section records the rule.

## References

- Related bug: none yet
