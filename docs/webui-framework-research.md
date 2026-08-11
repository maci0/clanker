# Web UI framework research

Status: recommendation. The decision below is **stay on vanilla JS**; this
document records the options that were weighed and the constraints that force
the outcome, so the next person who asks "why no framework?" can read this
instead of redoing the survey.

Date of research: 2026-08. Sources cited inline; star counts from the GitHub
API (`api.github.com/repos/...`), sizes from each project's own README/docs.

## 1. What the page is today

`tools/zig/webui/index.html` + `app.css` + `app.js`, embedded at comptime by
`tools/zig/webui.zig` and served from the sandbox. No framework, no bundler,
no build step beyond `zig build tools`. Third-party JS (`d3-dag`,
`highlight.js`) is vendored and served from `/webui/vendor/` with gzip and
immutable caching.

Current sizes (raw, before gzip):

| File | Bytes |
|---|---|
| `index.html` | ~20 KB |
| `app.css` | ~49 KB |
| `app.js` | ~178 KB (~4,300 lines) |

`app.js` is already the size of a small framework's runtime. The question is
not "add a framework?" but "is the hand-rolled framework in `app.js` worse
than a real one?"

## 2. Constraints a framework must satisfy

These are build or product constraints (from `docs/webui-plan.md` §3), not
preferences:

1. **No build step for the web UI.** The page is `@embedFile`'d by a WASM
   tool. Introducing a bundler (Vite, esbuild, rollup) adds an npm toolchain
   to a repo whose only build is `zig build`. Anything adopted must ship as a
   single static file vendored like `d3-dag`.
2. **Strict CSP, `script-src 'self'`.** No eval, no new third-party origin.
   Any library with a runtime template compiler that uses `new Function`
   (Alpine's expression evaluator, petite-vue's expressions) works under CSP
   only because it evaluates in-page — that is allowed — but it means every
   binding is parsed at runtime, on every page load.
3. **No sockets; one streaming channel.** Live state arrives as
   `\x01`-prefixed events on the `/api/run` stream, plus polling elsewhere.
   Server-driven swap models (htmx's core loop) fit poorly: the server
   returns JSON and events, not HTML fragments.
4. **The improve loop edits these files.** Smaller, dumber, greppable code
   survives automated rewriting better than framework idioms.
5. **Single page, ~7 views.** Chat, Runs, Rooms, Goals, Tools, System,
   plugins — hash-routed. This is well below the complexity where a component
   model pays for itself.

## 3. Candidates

| Candidate | Size (min+gzip, claimed) | License | Stars (2026-08) | Build-free? | Verdict |
|---|---|---|---|---|---|
| **Vanilla (status quo)** | 0 KB | — | — | yes | **Keep** |
| **[VanJS](https://vanjs.org) + VanUI** | **~1.0 KB (core); VanUI is copy-in, per component** | MIT | 4.4k | yes (single file, or inline) | **Best fit if we ever adopt one** — see below |
| [Alpine.js](https://alpinejs.dev) | ~15 KB (v3 core) | MIT | 31.8k | yes (CDN file) | Wrong direction: logic into markup |
| [petite-vue](https://github.com/vuejs/petite-vue) | ~6 KB | MIT | 9.7k | yes | Nice, but unmaintained (last push 2024-07) |
| [htmx](https://htmx.org) | ~14 KB (v2) | BSD-0-Clause | 48.9k | yes | Wrong model: swaps server HTML; our server speaks JSON |
| [Preact](https://preactjs.com) | ~3–4 KB core | MIT | 38.8k | **no** — JSX needs a compile step | Real option only if we accept a build step |
| React/Vue/Svelte/Solid | 40 KB+ and a toolchain | — | — | no | Fails constraints 1 and 5 outright |

Notes on the serious ones:

- **VanJS** deserves a longer note because it survives every constraint in
  §2 where the others fail one:

  - **1.0 KB min+gzip, MIT, zero dependencies, no transpile** — it is plain
    functions over the real DOM (`van.tags`, `van.state`, `van.derive`,
    `van.add`, `van.hydrate`). No virtual DOM, no expression evaluator, so
    nothing for our CSP to trip over and no runtime template parsing.
  - **Vendorable to the point of inlinability.** At ~1 KB compressed it could
    even ride inside the embedded page budget, though the right home is
    `/webui/vendor/` like `d3-dag`.
  - **Actively maintained** (v1.6.1, commits through July 2026), unlike
    petite-vue.
  - **VanUI** (in the same repo under `components/`) is not a package but a
    grab-and-go *collection* of components (modal, tabs, message box, option
    panel…) meant to be copied into your tree — which matches our "own every
    byte, improve loop edits these files" reality better than any npm
    dependency. VanX (1.2 KB) adds reactive lists and derived state if the
    fleet views need them.
  - The catch: it is a **model for new code, not a migration target**.
    Rewriting the existing 4,300-line `app.js` to `van.state`/`van.tags`
    buys nothing over the same rewrite in vanilla — the DOM surgery that is
    painful today stays painful either way until it is decomposed. And at
    4.4k stars with a single core maintainer it is the smallest community on
    this list; at 1 KB that is a readable-every-line risk, not a black-box
    one.

  Verdict: if a future view (fleet, pixel floor, or a from-scratch composer)
  wants reactive binding, **VanJS is the pre-approved choice alongside
  Preact+htm** — VanJS when the view is small and state-driven, Preact when
  it wants a real component tree. Neither justifies rewriting what already
  works.

- **Alpine** is the closest philosophical fit (behaviour in markup, no build).
  But it solves the problem we *don't* have — sprinkling interactivity on
  server-rendered pages — not the one we do: a 4,300-line stateful app with
  streaming events, graph rendering and drag-drop. Moving that into
  `x-data`/`x-on` attributes would scatter logic through HTML and make the
  improve loop's exact-match patches *harder*, not easier.
- **petite-vue** is the right size and model for progressive enhancement, but
  the repo has not been pushed since July 2024; adopting a dormant runtime
  for a page that is a co-equal product surface is a poor trade.
- **htmx** assumes the server returns HTML fragments. Ours returns JSON and a
  binary-flagged event stream; the page would still need a client-side
  renderer for everything that matters (run graph, transcript, live events).
  Adopting htmx would change the *server*, which is out of scope for a UI
  question.
- **Preact** is the only candidate that would genuinely scale the component
  model, and 3–4 KB gzipped vendored is affordable. But JSX/htm patterns want
  a compile step, and constraint 1 rules that out. If the page ever grows
  past what vanilla can carry, Preact + `htm` (no JSX, tagged templates) is
  the pre-chosen escape hatch — both vendorable, both MIT.

## 4. Recommendation

**Stay on vanilla JS. Spend the effort on structure, not a runtime.**

The real problem is that `app.js` is one 178 KB file, not that it lacks a
framework. Concretely, in rough priority order:

1. **Split `app.js` into ES modules** served from `/webui/` the way
   `app.css` and `app.js` already are (`webui.zig`'s `assetFor` is a
   lookup table; adding per-module entries is mechanical). Native
   `<script type="module">` needs no build step, no vendoring, and keeps one
   file per concern (chat, graph, rooms, plugins…). This is the single change
   that most improves editability for both humans and the improve loop.
2. **Keep the d3-dag / highlight.js pattern** as the *only* way third-party
   JS enters: vendored, immutable-cached, lazy-loaded. Any future library
   (e.g. the Phase 4 sprite renderer) follows it.
3. **Escape hatch, pre-decided:** if a future phase (fleet views, pixel
   floor) makes DOM diffing genuinely painful, adopt **VanJS** (1 KB, MIT,
   vendorable, VanUI components copy in) for a small state-driven view, or
   **Preact + htm** when the view wants a real component tree — all
   vendorable under `/webui/vendor/`, scoped to that view only, not a
   page-wide rewrite.

What not to do: add a bundler, adopt htmx (wrong server model), adopt
Alpine/petite-vue (runtime template evaluation under our CSP buys little and
scatters logic into markup), or rewrite working vanilla views to VanJS just
to use it.

## 5. Sources

- htmx repo metadata: `https://api.github.com/repos/bigskysoftware/htmx` (48.9k stars, BSD-0-Clause via htmx.org)
- Alpine repo metadata: `https://api.github.com/repos/alpinejs/alpine` (31.8k stars, MIT)
- petite-vue repo metadata: `https://api.github.com/repos/vuejs/petite-vue` (9.7k stars, MIT, last push 2024-07-13)
- Preact repo metadata: `https://api.github.com/repos/preactjs/preact` (38.8k stars, MIT, "Fast 3kB React alternative")
- VanJS repo metadata + README: `https://api.github.com/repos/vanjs-org/van`, `https://raw.githubusercontent.com/vanjs-org/van/main/README.md` (4.4k stars, MIT, 1.0 kB min+gzip claim, v1.6.1 / commits to 2026-07; VanUI lives in-repo under `components/`)
- Project constraints: `docs/webui-plan.md` §3; build embedding in `tools/zig/webui.zig`
