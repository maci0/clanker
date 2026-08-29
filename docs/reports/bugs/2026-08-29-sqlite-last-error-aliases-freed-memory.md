# Bug — sqlite last_error aliased freed memory, so a fresh session database failed to open

## TL;DR

- **What failed:** `Connection.exec` (`src/util/sqlite.zig`) stored `last_error` as a slice of the `sqlite3_exec` error message and then `sqlite3_free`d that message on return. The one reader that matters — `openDb`'s duplicate-column check (`src/agent/session.zig`) — matched "duplicate column name" against freed memory.
- **Impact:** On a fresh database the `steered` column is both in `schema`'s CREATE TABLE and in `added_message_columns`' ALTER, so the ALTER always raises the duplicate-column error the check exists to wave through; with the text gone, every `saveSession` on a fresh checkout failed. Ten `agent.session` tests red on macOS, `clanker gate` red on an untouched tree.
- **Resolution:** Fixed. Error text is copied into a buffer owned by the `Connection` (`setErr`) at every capture site: `exec`, `open` (which read `sqlite3_errmsg` of a handle it closes on the next line), and `prepare` (whose buffer is only valid until the next call on the handle).

## Status

Resolved.

## Symptom and impact

`zig build test` on `origin/main` (c43c291f) failed 10 `agent.session` tests on
macOS, all through `openDb` → `exec` → `Error.ExecFailed`, blocking every gated
change on this machine.

## Reproduction

`zig build test -Dtest-filter="a session database opens in WAL journal mode"`
on c43c291f.

## Root cause

`exec` set `self.last_error = std.mem.span(err_msg)` under a
`defer sqlite3_free(err_msg)`, so the slice dangled the moment `exec` returned.
Whether the caller's `std.mem.find(u8, conn.last_error, "duplicate column
name")` still matched was allocator behaviour, which is why the same code could
pass elsewhere and fail deterministically here. The trap was armed when
`steered` was added to both the CREATE TABLE and the migration ALTER list: from
then on the duplicate-column path runs on every fresh database, not only on
migrated ones.

## Verification

The filtered test above passes with the fix; the full gate on the branch
carrying it is green (see PR).

## Follow-up

## References

- Investigation: none yet
