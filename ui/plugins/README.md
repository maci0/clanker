# Web UI plugins

A web UI plugin adds a view to the page without being part of the page. Each
one is a directory here:

    ui/plugins/<name>/
      plugin.json    required — what it is and where it belongs
      app.js         required — registers the view
      app.css        optional — its own styles

`plugin.json`:

```json
{
  "name": "activity",
  "title": "Activity",
  "description": "One timeline of everything the board has recorded.",
  "group": "Watch",
  "capabilities": ["get"]
}
```

`group` is one of the rail's groups (`Work`, `Watch`, `Set up`) and decides
where the view's button appears.

`capabilities` names the `api` members the view actually uses. Known names:
`get`, `post`, `live`, `emit`, `confirm`, `prompt`, `toast`, `workspace`, `icon`,
`storage`, `render`, `session`. An unknown name is refused on write. The field is a
declaration, not a grant: the page still hands every plugin the whole
`pluginApi()`.

`app.js` runs after the page has booted and registers itself:

```js
clanker.registerView({
  id: "activity",
  title: "Activity",
  group: "Watch",
  boot: function (api) {
    // Optional. Runs when the script loads, even if the view is closed.
    // Persistent chrome (a mini-player dock) belongs here.
  },
  mount: function (container, api) {
    // container is an empty element owned by this plugin.
    // Called once, the first time the view is opened.
  },
  refresh: function (container, api) {
    // Optional. Called every later time the view is opened.
  }
});
```

From chat, the `webui_addon` tool writes these files and can enable the
addon. Ask for a view ("build me a music player") and it should call that
tool rather than edit `ui/app/`. `music` is the shipped demo; `schedule`,
`search`, and `compare` are migrated built-ins (on by default).

`api` is the small surface the page offers plugins:

| member | what it does |
|---|---|
| `api.getJSON(path)` | same-origin GET returning parsed JSON, throwing the server's own error text |
| `api.postJSON(path, body)` | same-origin POST of a JSON body, same error shape as `getJSON` |
| `api.onLive(fn)` | subscribe to `GET /api/events` (SSE). `fn` receives each `{t: ...}` event; the return value unsubscribes |
| `api.emit(data)` | POST `/api/live` as `{from: <plugin id>, data}`. Lands on the `plugin` topic as `{"t":"plugin","from":...,"data":...}` |
| `api.confirm(message, opts)` / `api.prompt(message, initial, opts)` | the page's dialogs (`uiConfirm` / `uiPrompt`) |
| `api.toast(message, kind)` | the page's toast |
| `api.workspace()` | current workspace id (empty string is the serve cwd) |
| `api.icon(name, size)` | the page's SVG icons |
| `api.storage` | `get` / `set` / `remove` against `localStorage`, namespaced `clanker.plugin.<id>.` |
| `api.el(tag, className, text)` | create an element, the way the rest of the page does |
| `api.status(message)` | announce through the live region, which also shows a toast |
| `api.fmt` | `bytes`, `int`, `cost`, `time` — the page's own formatters, so a plugin's numbers match |
| `api.openSession(id, jump)` | switch to a saved conversation and open Chat (`jump` is `{index, query}`) |
| `api.foldFind(text, needle, from)` | accent-insensitive substring, same indices as conversation search |
| `api.showView(id)` | switch to another view |
| `api.van` | the page's tag/state factory (signals-backed, VanJS-era API): `van.tags`, `van.state`, `van.derive`, `van.add` |
| `api.preact` / `api.html` | vendored [Preact](https://preactjs.com) `h`/`render`/`Fragment` and an [htm](https://github.com/developit/htm) template tag bound to `h`, for a view that wants a component tree |
| `api.signals` | vendored [@preact/signals-core](https://preactjs.com/guide/v10/signals/): `signal`, `computed`, `effect`, `batch` |

All are vendored and same-origin, so using them costs no extra request and no
policy exception. `api.van.tags` builds real DOM nodes, so the no-`innerHTML`
rule below is unchanged by it — `van.tags.p("text")` sets text as text. Prefer
it when a view has state that changes: derive the DOM from the state and there
is no second copy of "what is on screen" to keep in step.

```js
var items = van.state([]);
van.derive(function () {
  container.textContent = "";
  items.val.forEach(function (i) { van.add(container, van.tags.li({}, i.title)); });
});
```

Plugins are off until turned on in System → Web UI plugins, except Files
(the Work rail's workspace browser), Music, Schedule, Search, and Compare,
which are on when `state/webui_plugins.json` has never been written. Enabled ones are recorded
in `state/webui_plugins.json`. The registry — scan, seed, and toggle — lives
in the `webui_addon` tool; the `/api/webui/plugins` route relays to it, so
the page and the tool always see the same enabled list.

A disabled plugin's assets are not served: `GET /webui/plugins/<name>/app.js`
answers `404` with `{"ok":false,"error":"plugin is not enabled"}` before it
looks for the file. That is the intended behaviour — the page only requests
assets for plugins already enabled — but a `404` while `/api/webui/plugins`
answers `200` looks like a routing fault if you are probing by hand. Read the
body, and enable the plugin first:

```bash
curl -X POST -H 'Content-Type: application/json' \
	-d '{"name":"<name>","enabled":true}' http://127.0.0.1:<port>/api/webui/plugins
```

`clanker serve` also needs `zig build tools` before it can render any
`/webui/*` path: the page comes out of `zig-out/ui/app.wasm`, and without
it those paths return `500` while `/api/*` keeps answering `200`.

Constraints, which are the page's constraints:

- Served same-origin from `/webui/plugins/<name>/`. The Content-Security-Policy
  is `script-src 'self'`, so a plugin may not load anything from another origin,
  and may not use `eval` or `new Function`.
- Build DOM with `createElement` and `textContent`. Never assign `innerHTML`
  from data.
- Every control needs a visible label or an `aria-label`, and a target at least
  32px high. The host accent pill is `button.primary` and `#submit` only;
  a bare `button` is not a Run control.
- No build step and no dependencies: the file that ships is the file that runs.
