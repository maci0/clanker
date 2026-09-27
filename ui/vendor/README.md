# Vendored web UI dependencies

Third-party JavaScript committed here and embedded by `ui/vendor.zig` for
offline serving from `/webui/vendor/*` (`src/cli.zig`). Do not hand-edit minified
files; replace from upstream releases and update this table.

The whole tree's third-party inventory, this directory included, is
`THIRD_PARTY_LICENSES.md` at the repository root.

| File | Upstream | Version | License | SHA-256 (committed bytes) |
|------|----------|---------|---------|---------------------------|
| `preact.module.js` | [preact](https://www.npmjs.com/package/preact) `dist/preact.module.js` | 10.x ESM | MIT | `a1cefabf06ec626adcb92731537e1e04fd09a7908e22551bab50540106dc950d` |
| `htm.module.js` | [htm](https://www.npmjs.com/package/htm) `dist/htm.module.js` | 3.x ESM | Apache-2.0 | `ab33dd3f38059b9be4d5f5350128eefb2356639c4e0bbe9d9e8b3ba75847e9e4` |
| `signals-core.module.js` | [@preact/signals-core](https://www.npmjs.com/package/@preact/signals-core) | 1.x ESM | MIT | `a2261b3791bb800e7b268783e459a362f5da84f9c038be9b9509f3a6c632ad34` |
| `d3-dag.min.js` | [d3-dag](https://www.npmjs.com/package/d3-dag) | 1.x | ISC | `c646048f14fc222189f8acb683b574625c1cf48e3eaf594b34722f51b18cf3c0` |
| `hljs.min.js` | [highlight.js](https://www.npmjs.com/package/highlight.js) | 11.12.0 | BSD-3-Clause | `8ab71eb09c51f501e5e25157d9cff100e46cc29bcbfc744d0b746d451fca7f53` |
| `mermaid.min.js` | [mermaid](https://www.npmjs.com/package/mermaid) UMD `dist/mermaid.min.js` | 11.16.1 | MIT | `18327bef70d96fb505fe7287d9f6a7362ebf07ff6576ddfaffb1a06f3e1a2954` |
| `three.module.min.js` | [three](https://www.npmjs.com/package/three) | r180 module | MIT | `e2b5ee6bccd38fd6d8a2428546b83c5f2426d84b152ef82be8055556e3b40eb6` |
| `three.core.min.js` | [three](https://www.npmjs.com/package/three) | r180 core split | MIT | `61ba0df005b05991361d040d8ff670e1aadfd0ce7aeebd1fdb0725957a8957de` |

The SHA-256 column is the integrity reference for the committed bytes: after
re-copying or subsetting a file from upstream, `sha256sum ui/vendor/*` must
reproduce the recorded digest before the README table is updated alongside it.
It is what ties "the file clanker serves" to "the upstream release named in the
Version column" without trusting the git history alone.

`patternfly.min.css` was removed with the Tailwind port: every `pf-v6-u-*`
utility and every `pf-v6-c-*` component rule became a utility or a hand-written
rule in `ui/app/tailwind.src.css`, so the sheet was unlinked first and then deleted from
the tree and the host wiring (`ui/vendor.zig`, `cli.zig`, `webui_assets.zig`,
the size gate). Its subset script (`scripts/subset-patternfly.py`) and the
`@font-face` caveat went with it. A few `pf-v6-*` class names survive in
`ui/app/app.js` and `ui/app/core/plugins.js` as DOM query hooks and class
labels; no shipped stylesheet matches them, and the `--pf-t--global--*` aliases
in `tailwind.src.css` are kept only so any rule naming a token directly still resolves
onto the cabinet scale.

`patternfly-addons.css` was removed 2026-08-26: it stayed unlinked from
`index.html`, no view or plugin used any `pf-v6-u-*` utility class, and serving
the ~180KB sheet for nothing only widened the network surface. Re-add it from
npm (and register it in `webui_assets.zig` + `cli.zig`) if a utility class is
ever actually needed.

`three.module.min.js` imports `./three.core.min.js`; both must be updated
together from the same Three.js release.

Zig host dependencies live in `build.zig.zon` (zwasm, vaxis) and
`vendor/toml/` (zig-toml, MIT). AssemblyScript build tooling is
`tools/ts/package.json` only (`assemblyscript`, dev-only).
