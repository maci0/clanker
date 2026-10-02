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

The minified web assets do **not** all carry their upstream license headers:
a minifier strips comments, so what actually reaches the binary is measured,
not assumed. Of the eight committed files, five carry a grant in their own
bytes (`mermaid.min.js` a `Bundled license information` block covering its
transitive lodash/DOMPurify/js-yaml, `hljs.min.js` a `License: BSD-3-Clause`
banner, `d3-dag.min.js` an ISC comment, and both `three` files an
`SPDX-License-Identifier` that names a license without reproducing it) and
three carry none at all. For those three the grant ships beside the file, in
`ui/vendor/licenses/`, as the verbatim `LICENSE` of the pinned release
(`ui/vendor/licenses/UPSTREAM.md` records which, and why). `scripts/sbom.py`
fails when a vendored file has neither a notice in its bytes nor a copy
shipped, and checks each copy against the LICENSE of the pinned
`devDependency`, so a version bump cannot leave a stale grant behind;
`scripts/test_sbom.py` covers the same ground. The SBOM names each copy as a
`clanker:license-path` property on the component it covers, with its digest
as `clanker:license-sha256`.

Apache-2.0 (htm) and BSD-3-Clause (highlight.js) both carry attribution and
patent/prose conditions that survive redistribution, which is why they are
named individually rather than folded into a "MIT and friends" line.

## Resolved at build time by the package manager (not vendored)

`package.json` and `tools/ts/package.json` declare only `devDependencies`
(`@oxlint/plugins`, `@preact/signals-core`, `@rikalabs/oxlint-standards`,
`@shadcn/lint`, `@tailwindcss/cli`, `@types/bun`, `htm`, `oxlint`,
`oxlint-tsgolint`, `preact`, `tailwindcss`, `typescript`, `zod` in the root;
`assemblyscript` in `tools/ts`), each pinned to an exact version, with
`bun.lock` and `tools/ts/bun.lock` committed so `bun install
--frozen-lockfile` resolves the same tree with the same integrity digests
(CI, `scripts/verify.sh` and `tools/ts/verify.sh` all pass that flag). Two
of those carry conditions that survive into a release: `typescript` and
`htm` are Apache-2.0, the latter named individually in the vendored table
above because the same bytes are both a declared devDependency and a
vendored file. `preact` and `@preact/signals-core` are the other two names on
both lists (MIT, types only: `tsconfig.json` maps the `/webui/vendor/*`
specifiers at them and the vendored copies are what ships). `bun.lock`
records no license field, so the release SBOM is the per-package inventory
and this file the summary.

### Transitive grants no manifest names

`bun.lock` resolves 157 packages from the 14 devDependencies above, and a
dependency's license is the license of what it pulls in, not only of what a
manifest declares. Two grants in that closure are worth naming here because
nothing in the tree named them before:

| Package | Reached through | License | Why it matters |
|---|---|---|---|
| `lightningcss` (12 platform packages) | `@tailwindcss/cli` -> `@tailwindcss/node` | **MPL-2.0** | The only weak-copyleft grant anywhere in either lockfile. MPL-2.0 is file-level weak copyleft, so it is compatible with distribution and asks no source disclosure of a build-time tool, but it is the one obligation a downstream policy has to be able to *see*. Dev-only: nothing it compiles reaches a release. |
| `binaryen` | `assemblyscript` (in `tools/ts`) | Apache-2.0 | The pinned `131.0.0-nightly.20260721` pre-release named at the end of this section. |
| `@eslint/core`, `detect-libc` | `@shadcn/lint`, `@parcel/watcher` | Apache-2.0 | Ordinary permissive grants, carried by the tail of the closure. |

Of the 157 packages either lockfile names, 12 are MPL-2.0 (the `lightningcss`
row above), 27 are Apache-2.0 (three of them in the table above, the other 24
the tail of the closure), 114 are MIT, 2 ISC, 1 BSD-3-Clause and 1 0BSD
(`tslib`). Every package, with the identifier its own `package.json` declares,
is recorded in `tools/deps/npm-licenses.json`, which `scripts/sbom.py` reads
so every component in the release SBOM carries a CycloneDX `licenses` field;
`scripts/test_sbom.py` fails when a lockfile gains a package that table does
not cover.

No package installs a post-install script: neither manifest grants a
`trustedDependencies` entry, and bun runs lifecycle scripts only for
packages listed there. Both lockfiles are read by `scripts/sbom.py`, so the
release SBOM names every one of these packages with the digest the lockfile
pins it to. Both manifests pin the package manager (`bun@1.4.2`), since
`tools/ts/dist/` is committed and `tools/ts/verify.sh` rebuilds and diffs it
with whatever bun the runner has. Each manifest's `devDependencies` must
equal its lockfile's workspace block, so a manifest edited without re-locking
fails `scripts/test_sbom.py` instead of resolving a different tree at the
next install.

One entry there is a pre-release build: `tools/ts/bun.lock` pins
`binaryen@131.0.0-nightly.20260721`, the exact transitive version
`assemblyscript@0.28.20` asks for. It only reaches `tools/ts/dist/`, and
`tools/ts/verify.sh` rebuilds and diffs that output in CI, so a nightly that
regressed would show up there rather than ship silently. It moves only with an
AssemblyScript upgrade.
