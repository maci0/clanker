# Vendored web UI dependencies

Third-party JavaScript committed here and embedded by `ui/vendor.zig` for
offline serving from `/webui/vendor/*` (`src/cli.zig`). Do not hand-edit minified
files; replace from upstream releases and update this table.

| File | Upstream | Version | License |
|------|----------|---------|---------|
| `preact.module.js` | [preact](https://www.npmjs.com/package/preact) `dist/preact.module.js` | 10.x ESM | MIT |
| `htm.module.js` | [htm](https://www.npmjs.com/package/htm) `dist/htm.module.js` | 3.x ESM | Apache-2.0 |
| `signals-core.module.js` | [@preact/signals-core](https://www.npmjs.com/package/@preact/signals-core) | 1.x ESM | MIT |
| `d3-dag.min.js` | [d3-dag](https://www.npmjs.com/package/d3-dag) | 1.x | ISC |
| `hljs.min.js` | [highlight.js](https://www.npmjs.com/package/highlight.js) | 11.10.0 | BSD-3-Clause |
| `mermaid.min.js` | [mermaid](https://www.npmjs.com/package/mermaid) UMD `dist/mermaid.min.js` | 11.16.1 | MIT |
| `three.module.min.js` | [three](https://www.npmjs.com/package/three) | r180 module | MIT |
| `three.core.min.js` | [three](https://www.npmjs.com/package/three) | r180 core split | MIT |
| `patternfly.min.css` | [@patternfly/patternfly](https://www.npmjs.com/package/@patternfly/patternfly) `patternfly.min.css` | 6.6.1 | MIT |
| `patternfly-addons.css` | [@patternfly/patternfly](https://www.npmjs.com/package/@patternfly/patternfly) `patternfly-addons.css` | 6.6.1 | MIT |

`three.module.min.js` imports `./three.core.min.js`; both must be updated
together from the same Three.js release.

Zig host dependencies live in `build.zig.zon` (zwasm, vaxis) and
`vendor/toml/` (zig-toml, MIT). AssemblyScript build tooling is
`tools/ts/package.json` only (`assemblyscript`, dev-only).
