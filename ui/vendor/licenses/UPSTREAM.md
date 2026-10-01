# License texts for vendored web UI bundles

Each file here is the verbatim `LICENSE` from the npm release named in
[`../README.md`](../README.md), copied out of the pinned `devDependencies` in
`package.json` (`preact` 10.27.3, `htm` 3.1.1, `@preact/signals-core` 1.12.2).

## Why these exist

Every file in `ui/vendor/` is minified or bundled, so the license header its
source carried is either gone or reduced to a bare `SPDX-License-Identifier`.
Measured over the committed bytes:

| File | License text in the bundle |
|---|---|
| `preact.module.js` | none |
| `htm.module.js` | none |
| `signals-core.module.js` | none |
| `mermaid.min.js` | a `Bundled license information:` block, covering its transitive lodash/DOMPurify/js-yaml, not mermaid itself |
| `d3-dag.min.js` | one hand-written `ISC License` comment |
| `hljs.min.js` | `License: BSD-3-Clause` banner |
| `three.module.min.js`, `three.core.min.js` | `SPDX-License-Identifier: MIT` |

MIT requires the copyright notice and permission text to travel with the
software; Apache-2.0 (`htm`) additionally requires §4's license copy on
distribution, and carries a patent grant whose attribution is worth keeping
whole. A bare `SPDX-License-Identifier` is an identifier, not the grant it names,
so it does not satisfy either. These three copies are what makes the grant
traceable from a redistributed binary back to its origin.

`THIRD_PARTY_LICENSES.md` used to claim the minified assets all carry their
upstream headers. That was true for four of eight and false for these three.

## Naming

`htm-LICENSE`, `preact-LICENSE`, `signals-core-LICENSE` — upstream package name
plus the file's own name, so a future vendor tree keeps the pairing obvious.
These files are not served: `ui/vendor.zig` embeds the `.js` files by explicit
`@embedFile`, and the test in `src/cli.zig` ("no vendored JS file exists that
the vendor routes have never heard of") enumerates `ui/vendor/` but not this
subdirectory, so nothing routes them and nothing can 404 on them.

`scripts/test_sbom.py` fails when a vendored `.js` has neither a notice in the
bundle nor a copy in this directory, and checks each copy against the LICENSE
of the pinned devDependency, so a version bump cannot leave a stale grant here.
