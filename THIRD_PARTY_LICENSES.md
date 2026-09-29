# Third-party components

Every third-party code this repository ships, bundles, or fetches at build
time, with the license it carries and where its full text lives. Nothing is
redistributed here without a row in this table; adding a dependency means
adding a row in the same change.

Two things are deliberately not claimed. clanker's own license is not declared
in this repository, and the JS build toolchain (`assemblyscript`,
`binaryen`, `long`, `oxlint`, `tailwindcss`, `@tailwindcss/cli` and the lint
packages listed below) is not vendored, so its licenses are not recorded in-tree either. Both are gaps a
redistributor has to close, not facts this file can assert.

## Fetched at build time (`build.zig.zon`)

| Component | Version | License | Source |
|---|---|---|---|
| zwasm | v2.5.0 | Apache-2.0 | <https://github.com/zwasm/zwasm> (tarball, hash-pinned in `build.zig.zon`) |
| libvaxis | commit `82cec0db` | MIT | <https://github.com/rockorager/libvaxis> (git URL, hash-pinned in `build.zig.zon`) |

Both are patched in place by `patches/*.patch` (see `patches/README.md`).
`zig-pkg/` is gitignored, so the extracted copies and their `LICENSE` files
are not in the tree; the license text ships with the upstream release named
above.

## Fetched and compiled by a script (developer toolchain)

| Component | Version | License | Source |
|---|---|---|---|
| tree-sitter-zig | commit `6479aa13` | MIT | <https://github.com/tree-sitter-grammars/tree-sitter-zig> (cloned by `grammars/build.sh`, detached at the full commit id in `REF_ZIG`, then patched with `grammars/0001-zig-0.17-dev-support.patch`) |

ast-grep ships no Zig parser, so structural search over this repository's own
source needs this one compiled into `grammars/zig.so`, which is gitignored and
rebuilt by the script. It reaches no release artifact; `scripts/sbom.py` names
it with the commit that pins it.

## Vendored in-tree

| Component | Version | License | Where | Provenance |
|---|---|---|---|---|
| zig-toml | v0.3.0 | MIT | `vendor/toml/` | `vendor/toml/README.md`, full text in `vendor/toml/LICENSE` |
| SQLite amalgamation | 3.53.4.0 | Public Domain | `vendor/sqlite/` | `vendor/sqlite/README.md` (source URL, fetch date, sha256 of both files) |
| preact | 10.x | MIT | `ui/vendor/preact.module.js` | `ui/vendor/README.md` (upstream path, sha256) |
| htm | 3.x | Apache-2.0 | `ui/vendor/htm.module.js` | `ui/vendor/README.md` |
| @preact/signals-core | 1.x | MIT | `ui/vendor/signals-core.module.js` | `ui/vendor/README.md` |
| d3-dag | 1.x | ISC | `ui/vendor/d3-dag.min.js` | `ui/vendor/README.md` |
| highlight.js | 11.12.0 | BSD-3-Clause | `ui/vendor/hljs.min.js` | `ui/vendor/README.md` |
| mermaid | 11.16.1 | MIT | `ui/vendor/mermaid.min.js` | `ui/vendor/README.md` |
| three.js | r180 | MIT | `ui/vendor/three.module.min.js`, `ui/vendor/three.core.min.js` | `ui/vendor/README.md` |
| anti-slop | commit `c44ef22c` | MIT | `tools/oxlint/anti-slop/` | `tools/oxlint/anti-slop/UPSTREAM.md` (source path, blob-hash check); its `vendor/eslint-stylistic/` carries its own MIT `LICENSE` and `UPSTREAM.md` |

The `ui/vendor/` rows share one provenance and digest table, which names the
upstream release each file came from and the sha256 of the committed bytes.
`sha256sum ui/vendor/*` must reproduce it.

The minified web assets carry their upstream license headers where the
bundler emitted them; the per-file `LICENSE` texts of the npm packages are
not vendored. Apache-2.0 (htm) and BSD-3-Clause (highlight.js) both carry
attribution and patent/prose conditions that survive redistribution, which
is why they are named individually rather than folded into a "MIT and
friends" line.

## Resolved at build time by the package manager (not vendored)

`package.json` and `tools/ts/package.json` declare only `devDependencies`
(`oxlint`, `oxlint-tsgolint`, `@oxlint/plugins`, `@rikalabs/oxlint-standards`,
`@shadcn/lint`, `typescript`, `zod`, `@types/bun`, `tailwindcss`, `@tailwindcss/cli` in the
root, MIT except `typescript` which is Apache-2.0; `assemblyscript` in `tools/ts`), each pinned to an exact version, with `bun.lock` and
`tools/ts/bun.lock` committed so `bun install --frozen-lockfile` resolves the
same tree with the same integrity digests (CI, `scripts/verify.sh` and
`tools/ts/verify.sh` all pass that flag). No package installs a post-install
script: neither manifest grants a `trustedDependencies` entry, and bun runs
lifecycle scripts only for packages listed there. Both lockfiles are read by
`scripts/sbom.py`, so the release SBOM names every one of these packages with
the digest the lockfile pins it to. Both manifests pin the package manager
(`bun@1.4.2`), since `tools/ts/dist/` is committed and `tools/ts/verify.sh`
rebuilds and diffs it with whatever bun the runner has. Each manifest's
`devDependencies` must equal its lockfile's workspace block, so a manifest
edited without re-locking fails `scripts/test_sbom.py` instead of resolving a
different tree at the next install.

One entry there is a pre-release build: `tools/ts/bun.lock` pins
`binaryen@131.0.0-nightly.20260721`, the exact transitive version
`assemblyscript@0.28.20` asks for. It only reaches `tools/ts/dist/`, and
`tools/ts/verify.sh` rebuilds and diffs that output in CI, so a nightly that
regressed would show up there rather than ship silently. It moves only with an
AssemblyScript upgrade.
