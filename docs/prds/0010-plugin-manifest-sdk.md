# PRD — Plugin manifest SDK (`clanker plugins`)

## Status

Shipped. Sources of truth: `src/toolhost/manifest.zig` (the schema, the validator,
the scaffold templates) and `src/toolhost/registry.zig` (the loader, which is what
the schema is derived from). Surfaces: CLI `clanker plugins list|validate|new`
(`Command.plugins`, `cmdPlugins` in `src/cli.zig`), REPL `/plugins` and
`GET/POST /api/plugins` (both unchanged, both still the `plugins` guest).
Reference doc: `docs/manifest.md`. Scope decision on distribution:
`docs/adrs/0007-plugin-manifests-are-declarative-and-unsigned.md`.

Distribution is deliberately *not* here: no fetch, no install, no signing, no
registry. See Non-goals, and the ADR for why a half version of trust was worse
than none.

## Problem

The manifest format already existed and was already enforced — `registry.zig`
loads `*.tool.json`, `sandboxFor` turns the grants into the policy the host
checks on every call, and two conformance tests refuse a schema no provider
would accept and a model-calling guest that does not declare itself. What did
not exist was any of the things that make a format a format:

- **No written spec.** `docs/README.md` had a ten-row table of "descriptor
  keys" against a loader that reads twenty-six of them. Two of those ten rows
  were wrong (see Design → Bugs fixed).
- **No version.** Nothing in a manifest said which schema it was written
  against, so there was no way to add one later without either breaking every
  existing file or guessing.
- **No way to check one.** The loader is deliberately forgiving: a bad
  descriptor is warned about and skipped so it cannot take the other ninety
  down with it, and an *unknown key* is not even a bad descriptor — it is
  ignored outright. So `"fs_prefix"` for `"fs_prefixes"`, a `fuel` above the
  ceiling, or a `tool_allow` with no `tool_call` all load clean and quietly do
  nothing. The author finds out when the tool fails to do its job.
- **No way to start one.** Writing a plugin meant copying an existing pair of
  files and deleting the parts that did not apply.
- **No way to ship one.** `wasm` resolves against the process's working
  directory, which is right for `zig-out/tools/x.wasm` in this repo and unusable
  for a directory someone unpacked somewhere: a portable package cannot know
  what clanker's cwd will be.

The cost of that last gap was not hypothetical. `4fadb86` renamed the ten
`board_*` manifests to `kanban_*` and left two things behind it: an eval still
naming `board_list` (caught, loudly, by `src/evals/scorers.zig`) and
`host.zig`'s `chatAccessAllowed`, which granted the board guest its chat ops by
matching the string `"board"`, and after the rename matched nothing. Per that
function's own doc comment the board *ignores* a failed chat call, so cards
stopped replicating into their room with no error anywhere; the host test that
should have caught it iterated a hardcoded list of the eleven old names, so the
rename went green. Both halves have since been fixed: commit `3402a2c` taught
`chatAccessAllowed` the new names (it now matches `"board"` or the `kanban_`
prefix, `src/sandbox/host.zig:1785-1794`), and commit `0d424f4` replaced the
hardcoded eleven-name test with one that derives its names from the shipped
manifests. The lesson stands: nothing in the tree connects a manifest's `name`
to the places that depend on it, and at the time nothing checked a manifest
against anything. A validator does not by itself close that specific hole (the
derived test is what did), but "the manifest is the contract and nothing
verifies it" is the same sentence in both cases.

The constraint that shaped all of it: the loader must not get stricter.
Ninety-three manifests ship in this repo and an unknown number exist in
checkouts; the format had to be written down as it *is*, not as it might have
been designed, and the strictness had to go somewhere that is opt-in to run.

## Goals

1. A versioned schema: `manifest_version`, with absence meaning v1, so today's
   manifests keep loading byte-for-byte unchanged.
2. A written reference for every key the harness actually honors, derived from
   the code, with the drift between the old docs and the code fixed.
3. A pure, unit-tested validator that reports the file and the offending key,
   including the combinations that load and do nothing.
4. A CLI a third party can use: check a manifest or a directory, and scaffold a
   new tool that builds and validates as it stands.
5. One packaging affordance: a `{manifest, wasm}` directory that clanker can be
   pointed at without knowing where it was unpacked.

## Non-goals

- **Fetching, installing, signing, publisher identity, a registry index.** All
  four, and the reasoning, are in
  [ADR 0007](../adrs/0007-plugin-manifests-are-declarative-and-unsigned.md).
  The short version: the manifest is already the security boundary and it is
  already enforced, so signing answers a question the sandbox does not ask,
  while a fetch path without signing makes running someone else's code easier
  without making it safer.
- **A stricter loader.** Everything new is opt-in (`clanker plugins validate`)
  or forward-facing (an unsupported `manifest_version`, which no existing file
  has). A manifest that loaded before this change loads after it.
- **`agent.tools_dir` as a list.** Pointing it at a plugin package still
  *replaces* the built-in tools rather than adding to them. Multi-directory tool
  discovery is a real feature and a separate one; it touches every caller of
  `Registry.load`, not the manifest format.
- **A schema for the guest ABI.** `scratch`/`host_arena`/`run` and the `env.ck_*`
  imports are the module's contract with the host and are documented in
  `docs/README.md`. This is the manifest's contract, which is a different file.
- **Validating what a manifest *should* grant.** The validator says
  `"fs_prefixes": ["."]` is well-formed. Whether a tool ought to have the whole
  tree is a review question, not a lint.

## Design

**`manifest_version`, and why absence is not an error.** Version 1 is the
format as it stood. A manifest without the key is v1 — every file written
before the key existed is a valid v1 file, and that has to stay true forever or
introducing the key breaks ninety-three manifests at once. A version this build
does not understand is *refused*, not read under v1 rules: `parseDescriptor`
returns `error.UnsupportedManifestVersion` and the loader's existing warn-and-
skip path handles it with no new code. Reading a v2 file with v1 rules would
mean registering a tool whose sandbox policy is not the one its author wrote,
which is the failure the key exists to prevent.

**The validator is pure.** `src/toolhost/manifest.zig` takes a filename and bytes
and returns a `Report` of `Finding{severity, key, message}`. No I/O, no
dependency past `std`, so every rule is a unit test over a string literal. A
malformed manifest is a finding and never an error return, so one bad file in a
directory does not stop the other ninety being checked. All findings are
collected in one pass: a validator that stops at the first is a validator you
run four times.

Errors are things the loader will refuse, or accept while doing something other
than what the file says. Warnings are things that load and do nothing. That
split is what makes the exit code usable — `validate` exits non-zero on errors
only, so it can guard a script without failing over a note.

The rules are derived, not invented, and the evidence is that all 93 shipped
manifests produce zero errors *and zero warnings*. A new test in `registry.zig`
pins that.

**Two checks need more than the bytes,** so they live in the CLI rather than
the pure module: whether the `wasm` exists on disk (a warning — the module is
usually just unbuilt), and whether a guest source file that calls the model
declares `llm`. The second is the rule `registry.zig`'s conformance test has
enforced for this repo since `compare` landed; the marker list moved into
`manifest.zig` so the test and the CLI cannot drift, which was already a stated
hazard in that test's comment.

**Where the module lives.** `Registry.resolveWasmPath` runs on every descriptor
at load: a `wasm` containing `/` is left alone and read from the working
directory, exactly as before; a bare filename resolves against the manifest's
own directory. Every shipped manifest names a path with a separator, so this is
a no-op for all of them — the bare form is new surface, not a change of meaning
for the existing one. It is the whole of the packaging slice: it makes
`{name.tool.json, name.wasm}` in one directory work wherever it was unpacked.

**The CLI is one noun.** `plugins` was already the name of this surface in the
REPL (`/plugins`) and over HTTP (`/api/plugins`), so `clanker plugins list`
delegates to the same `plugins` guest rather than becoming a second
listing. `validate` and `new` are the new verbs. There is no `clanker manifest`
or `clanker tool` competing for the same idea.

**The scaffolder generates a pair that passes.** `plugins new <name>` writes
`tools/manifests/<name>.tool.json` and `tools/zig/<name>.zig`, refusing to
overwrite either. A unit test validates the generated manifest and asserts the
two agree on the name — a scaffolder whose output the validator rejects would be
worse than no scaffolder.

### Field reference

The full table is `docs/manifest.md`, mirrored from `parseDescriptor` and
`manifest.zig`'s `known_keys`. Treating a mismatch between the two as a bug in
the doc is the standing rule; `known_keys` is the list to update when the loader
learns a key, or `validate` starts calling it unknown.

**Bugs fixed.** Found by writing the reference against the code rather than against the
existing docs:

- **`exec_allow` empty did not mean what three places said it meant.**
  `registry.zig`'s field comment ("Empty means the harness default set"),
  `docs/README.md`'s key table ("replaces the harness default set") and its
  prose ("replaces the harness's default `ck_exec` set (`git`, `rg`,
  `ast-grep`, `semcode`, `zig`)") all described a default allowlist that does
  not exist. `host.execAllowed` compares `argv[0]` against the manifest's list
  and nothing else, and `host.zig`'s own test ("a tool may run only the commands
  its manifest names") pins that an empty list allows nothing. Three docs
  described a tool as having exec authority it has never had. All three docs
  are fixed; a fourth copy survives in code (see Known issues):
  `src/sandbox/host.zig:209-210`'s field comment still reads "Empty falls back
  to the harness default set below" while `host.execAllowed` in the same file
  allows nothing for an empty list.
- **`wasm` is not "relative to the tools directory".** The field comment said
  it was; it has always been read relative to the process's working directory
  (`loop.zig`'s `wasmBytes`, `cli.zig`, `host.zig`). Comment corrected, and the
  bare-filename form now makes the "beside the manifest" reading true for the
  case that wanted it.
- **`category` was undocumented.** Present in 82 of 93 manifests and read by the
  `tools` and `plugins` guests for grouping, but absent from every
  reference and from `registry.zig` entirely. Documented, including the part
  that surprises: the registry does not parse it.

## Known issues

- **(Fixed) `src/sandbox/host.zig` carried a stale `exec_allow` comment.**
  The field comment read "Empty falls back to the harness default set below"
  while `host.execAllowed` in the same file allows nothing for an empty list
  (pinned by the test "a tool may run only the commands its manifest names").
  Docs and `registry.zig` were corrected in Bugs fixed above; the surviving
  code comment now states the empty-allows-nothing contract too, closing the
  last copy of the drift.
- **(Fixed) `plugins new` used to refuse colliding files, not colliding
  registered tool ids.** Failure modes below state the contract: a name that
  already identifies a registered tool is refused before write. `pluginsNew`
  only `statFile`d the destination manifest/guest paths (`src/cli.zig`), so an
  id loaded from another directory (especially once PRD 0022 lands) could
  still be scaffolded. It now loads the registry over every configured
  `tools_dir` first and refuses a name `reg.tools` already knows, naming the
  directories it checked; a registry that will not load logs a warning and
  falls back to the file checks, so scaffolding never depends on validate-time
  cleanliness.

## Failure modes

| Condition | Behaviour |
|---|---|
| Manifest has no `manifest_version` | Treated as v1; loads unchanged |
| `manifest_version` above what the build knows | `error.UnsupportedManifestVersion`; loader warns naming the file and does not register the tool |
| `manifest_version` is not an integer | `error.ManifestVersionNotInteger`; same warn-and-skip |
| Unknown top-level key | Loads and is ignored (unchanged). `validate` warns |
| `wasm` is a bare filename | Resolved against the manifest's directory |
| `wasm` contains `/` | Resolved against the working directory (unchanged) |
| `validate` on a path that is not a directory | Treated as a single manifest |
| `validate` finds errors | Prints each with file and key, prints a count, exits 1 |
| `validate` finds only warnings | Prints them, exits 0 |
| `validate` on a directory with no `*.tool.json` | Usage error, exit 2 |
| `plugins new` on an existing name (scaffold files already on disk) | Refuses both writes, exit 2; nothing is clobbered |
| `plugins new` with a name that already identifies a registered tool id | Refused before write, exit 2, naming the colliding id; the scaffolder never creates a second descriptor for an id the registry already owns |
| `plugins new` with a name outside `[a-z0-9_]` | Usage error, exit 2 |
| `plugins <unknown-sub>` | Usage error naming the three subcommands, exit 2 |
| Guest source calls the model without `llm`/`sequential` | `validate` error (and, in this repo, a red `registry.zig` conformance test) |
| Manifest names a `wasm` that is not built | `validate` warning; the loader still registers the tool and the call fails at execution as before |

## Acceptance criteria

- [x] `manifest_version` parsed; absent means 1; unsupported is refused, not downgraded
- [x] All 93 shipped manifests load unchanged and validate with zero errors and zero warnings, pinned by a test
- [x] Pure validator in `src/toolhost/manifest.zig`, 11 unit tests, no I/O
- [x] Findings carry the file and the offending key, and say what the key does or fails to do
- [x] Fuel ceiling, `network_allow`/`fs_prefixes`/`exec_allow` shape, and the model-call declaration rule are all checked
- [x] `clanker plugins list|validate|new`, with `list` delegating to the existing `plugins` guest
- [x] `validate` exits non-zero on errors, zero on warnings
- [x] `plugins new` output builds under `zig build tools` and validates clean
- [x] Bare `wasm` resolves beside its manifest; a path with a separator does not move
- [x] `docs/manifest.md` written from the loader; three inaccurate claims in the old docs fixed
- [x] Live-verified: a scaffolded tool was built, discovered through the lazy catalog, and called correctly by a real model run
- [x] `zig build` / `zig build tools` / `zig build test` green
- [x] Out-of-tree loading verified end to end through `agent.tools_dir` (list form shipped in [PRD 0022](0022-out-of-tree-tools.md); unit-tested at `Registry.load`)

## Open questions / future work

- **`agent.tools_dir` as a list: Shipped in PRD 0022.** A string or an array;
  later-listed wins on a name collision. See
  [PRD 0022 (out-of-tree tools)](0022-out-of-tree-tools.md).
- **Should the validator run as part of `clanker gate`?** It is cheap and the
  tree is clean, so it would stay green — but it would also make the loader's
  forgiveness irrelevant inside this repo, which may be the point or may be a
  strictness nobody asked for.
- **Should one helper own "walk a directory of `*.tool.json`"?** Three places
  now inline that loop: `Registry.load`, the two conformance tests beside it
  (plus the one this change adds), and `cmdPlugins`' `pluginsValidate`. The
  validator genuinely cannot go through `Registry.load` — it needs the raw
  bytes and the filename of a manifest that *fails* to parse, which the loader
  drops — but the walk itself is the same three lines each time, and a second
  reader of the same directory is how two answers about the same tool set start
  to disagree.
- **Does `category` belong in the registry?** It is a manifest field two guests
  read by parsing the manifest themselves. Either it is real metadata and
  `Tool` should carry it, or it is guest-private and the reference should say so
  more loudly than it currently does.
