# Third-party components

Every third-party code this repository ships, bundles, or fetches at build
time, with the license it carries and where its full text lives. Nothing is
redistributed here without a row in this table; adding a dependency means
adding a row in the same change.

Two things are deliberately not claimed. clanker's own license is not declared
in this repository, and the JS build toolchain (`assemblyscript`,
`binaryen`, `long`, `oxlint`) is not vendored, so its licenses are not
recorded in-tree either. Both are gaps a redistributor has to close, not
facts this file can assert.

## Fetched at build time (`build.zig.zon`)

| Component | Version | License | Source |
|---|---|---|---|
| zwasm | v2.5.0 | Apache-2.0 | <https://github.com/zwasm/zwasm> (tarball, hash-pinned in `build.zig.zon`) |
| libvaxis | commit `82cec0db` | MIT | <https://github.com/rockorager/libvaxis> (git URL, hash-pinned in `build.zig.zon`) |

Both are patched in place by `patches/*.patch` (see `patches/README.md`).
`zig-pkg/` is gitignored, so the extracted copies and their `LICENSE` files
are not in the tree; the license text ships with the upstream release named
above.

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
| @patternfly/patternfly | 6.6.1 | MIT | `ui/vendor/patternfly.min.css` (subset, see its README) | `ui/vendor/README.md` |

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
(`oxlint`, `assemblyscript`), each pinned to an exact version, with
`bun.lock` and `tools/ts/bun.lock` committed so `bun install --frozen-lockfile`
resolves the same tree with the same integrity digests (CI, `scripts/verify.sh`
and `tools/ts/verify.sh` all pass that flag). No package installs a
post-install script: neither manifest grants a `trustedDependencies` entry, and
bun runs lifecycle scripts only for packages listed there.
