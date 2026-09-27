# Contributing to clanker

clanker is a self-improving AI agent harness written in Zig 0.16. It improves
its own source through a gated loop, and the same gates guard human changes:
a change that cannot pass them does not land.

## Getting started

```sh
scripts/setup.sh
```

That is the whole bootstrap: it checks the toolchain, runs
`zig build --fetch=all` and `scripts/apply-patches.sh` (re-applying
`patches/*.patch` to the fetched dependencies — the SIGWINCH patch is
load-bearing for `clanker repl` and the pty e2e journeys, and `build.zig`
refuses to compile against an unpatched tree), then `zig build` and
`zig build tools`. The order is the whole trap: `--fetch=all` extracts
without compiling, and the patch script cannot patch a tree that is not on
disk yet. It prints the remaining steps when it finishes: `zig build test`,
`./zig-out/bin/clanker init`, `./zig-out/bin/clanker gate`, and the
repository hooks:

```sh
git config core.hooksPath .githooks
```

Requirements are Zig 0.16.x (pinned in `build.zig.zon`, enforced by
`build.zig`), Git, Bash, and patch. Tests also need Bun for the JS suites
and Python 3 for the process fixtures. Full verification additionally needs
shellcheck and ruff; `scripts/verify.sh` installs the declared JS dependencies
locally.

## The edit-test loop

Three speeds, slowest last:

- `zig build quick-check`: `zig fmt --check` plus a compile of the host binary,
  no tests. Seconds; enough to know a patch builds before spending a test run
  on it. It does **not** compile the WASM guests under `tools/zig/` (the
  dependency runs the other way round: `zig build tools` depends on the host,
  not the reverse), so an edit there needs `zig build tools` (or `zig build
  test`, which depends on it) to show a green compile.
- `zig build test -Dtest-filter="<substring>"`: only tests whose name
  contains the substring are compiled in. A filter that matches nothing passes
  with 0 tests; the JS suites still run.
- `zig build test` — the full suite (Zig + JS), which takes minutes.

`zig build fmt-fix` fixes what `quick-check` reports. Also:

- One JS suite: `bun test ui/app/core/scroll.test.mjs` (or whichever
  `.test.mjs` you changed).
- Every JS suite, without the Zig half: `bun test ui/app` (bun walks the
  directory itself).
- The e2e journeys (`zig build e2e`) spawn the real `clanker repl` on a pty,
  so they need the dependency patches applied: run `scripts/apply-patches.sh`
  once after `zig build --fetch=all` (idempotent; `scripts/verify.sh` does it
  for you).
- Before pushing: `scripts/verify.sh` — mirrors everything CI's verify job
  runs (shellcheck, oxlint, ruff, SBOM generation,
  AssemblyScript rebuild-and-diff, `clanker gate`, e2e), so a red CI run is
  not the first place you hear about it.

## What must pass

- `clanker gate` — build, test, tools, fmt, lint, and the self-integrity
  gates (provider-kind, test-root-coverage, js-suite-coverage, tool-helper-coverage,
  webui-budget,
  sandbox-abi, tools-ts-toolchain, release-contract, reports-inventory,
  skills-inventory, dep-patches). This is what the self-improvement loop
  demands of its own proposals, so a human change must clear the same bar.
  `dep-patches` is about your checkout rather than your diff: run
  `zig build --fetch=all` and then `scripts/apply-patches.sh` before compiling
  in each new worktree.
- CI — the workflow in `.github/workflows/ci.yml` additionally checks shell
  scripts with shellcheck, `ui/` and `tools/ts` with oxlint, every tracked
  `.py` with ruff (`ruff.toml`), the SBOM generation, and that
  `tools/ts/dist/*.wasm` matches a clean rebuild (`tools/ts/verify.sh`).
  `scripts/verify.sh` reproduces all of it locally.
- The pre-commit hook (fast checks over staged files only). Its JavaScript
  check needs `bun install` once per clone; without it the hook says it
  skipped and CI still runs oxlint. Bypass for WIP
  with `git commit --no-verify`.

## Committing

- Manual changes use a `area: summary` subject line (`agent: ...`, `docs:
  ...`, `ci: ...`).
- Self-improvement promotions are committed as `clanker: <summary>
  [imp-<id>]` by the loop; leave that form to it.
- Consumer-visible changes get an entry under `[Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md) (Keep a Changelog style). Release notes are
  extracted from the changelog, so a shipped change without an entry never
  reaches the release notes. This obligation is convention, not mechanism:
  the `release-contract` gate checks release-file structure only and never
  reads the diff, so a missing entry ships green — authors and reviewers are
  what enforce it. Records-only and internal-docs-only changes are not
  consumer-visible and need no entry. See
  [the investigation](docs/reports/investigations/2026-08-24-release-contract-never-reads-the-diff.md).

## Generated files

- `tools/ts/dist/*.wasm` is committed. After editing `tools/ts/*.ts`, run
  `bun run build:all` in `tools/ts/` and commit the result —
  `tools/ts/verify.sh` fails on drift otherwise.
- `ui/app/tailwind.css` is generated from `ui/app/tailwind.src.css` by
  `bun run css:build` and is committed, because `clanker serve` embeds the
  file in the tree and has no build step. A utility class written into
  `ui/app/` or `ui/plugins/` styles nothing until that runs, and
  `ui/app/tailwind.test.mjs` fails on the stale sheet.
- `ui/vendor/` is vendored third-party JS; do not hand-edit.
- `src/tui/mascot/mascot_frames.zig` and the mascot PNGs are generated by
  `src/tui/mascot/gen_frames.py`; do not hand-edit.

## Project conventions

[AGENTS.md](AGENTS.md) is the architecture and convention reference: module
layout, WASM-by-default, the sandbox/tool ABI, record stores, and the
self-improvement loop. Follow it for anything that touches those surfaces.
New `src/` modules with `test` blocks must be referenced from the comptime
block in `src/main.zig` or their tests never run (`clanker gate` enforces
this; it is not optional).

## Where to ask

Open a PR against `main`; the CI workflow runs on every push and PR. If a
change ships a fix for a recurring operational failure, record it with
`clanker reports` per the runbook convention in
[docs/runbooks/](docs/runbooks/).
