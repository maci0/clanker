# Vendored SQLite (amalgamation)

SQLite 3.53.4.0 amalgamation, fetched from
<https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip> on 2026-08-20
(Public Domain, per sqlite.org's licensing).

Two files, used only by the host binary and the host test build:

- `sqlite3.c` — the amalgamated implementation, compiled into the clanker
  exe and the test binary via build.zig with
  `-DSQLITE_ENABLE_FTS5` (future session full-text index),
  `-DSQLITE_OMIT_LOAD_EXTENSION` (no runtime code loading — the sandbox
  invariant), `-DSQLITE_DQS=0`, `-DSQLITE_OMIT_DEPRECATED`, and
  `-DSQLITE_DEFAULT_MEMSTATUS=0`.
- `sqlite3.h` — the header, reached by src/util/sqlite.zig through
  `@cImport`.

The shell (`shell.c`) and extension headers are not vendored; nothing here
needs them. WASM guests never link SQLite: the store is host-side, and guests
reach it through the harness the way they reach every other native surface.
