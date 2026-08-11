# Web UI plugins

A web UI plugin adds a view to the page without being part of the page. Each
one is a directory here:

    tools/webui-plugins/<name>/
      plugin.json    required — what it is and where it belongs
      app.js         required — registers the view
      app.css        optional — its own styles

`plugin.json`:

```json
{
  "name": "activity",
  "title": "Activity",
  "description": "One timeline of everything the board has recorded.",
  "group": "Watch"
}
```

`group` is one of the rail's groups (`Work`, `Watch`, `Set up`) and decides
where the view's button appears.

`app.js` runs after the page has booted and registers itself:

```js
clanker.registerView({
  id: "activity",
  title: "Activity",
  group: "Watch",
  mount: function (container, api) {
    // container is an empty element owned by this plugin.
    // Called once, the first time the view is opened.
  },
  refresh: function (container, api) {
    // Optional. Called every later time the view is opened.
  }
});
```

`api` is the small surface the page offers plugins:

| member | what it does |
|---|---|
| `api.getJSON(path)` | same-origin fetch returning parsed JSON, throwing the server's own error text |
| `api.el(tag, className, text)` | create an element, the way the rest of the page does |
| `api.status(message)` | announce through the live region, which also shows a toast |
| `api.fmt` | `bytes`, `int`, `cost`, `time` — the page's own formatters, so a plugin's numbers match |
| `api.showView(id)` | switch to another view |
| `api.van` | [VanJS](https://vanjs.org): `van.tags`, `van.state`, `van.derive`, `van.add` |
| `api.ui` | VanUI components: `Modal`, `Tabs`, `Banner`, `Tooltip`, `Toggle`, `Await`, `MessageBoard`, `OptionGroup`, `choose` |

Both are vendored and same-origin, so using them costs no extra request and no
policy exception. VanJS builds real DOM nodes, so the no-`innerHTML` rule below
is unchanged by it — `van.tags.p("text")` sets text as text. Prefer it when a
view has state that changes: derive the DOM from the state and there is no
second copy of "what is on screen" to keep in step.

```js
var items = van.state([]);
van.derive(function () {
  container.textContent = "";
  items.val.forEach(function (i) { van.add(container, van.tags.li({}, i.title)); });
});
```

Plugins are off until turned on in System → Web UI plugins. Enabled ones are
recorded in `state/webui_plugins.json`.

Constraints, which are the page's constraints:

- Served same-origin from `/webui/plugins/<name>/`. The Content-Security-Policy
  is `script-src 'self'`, so a plugin may not load anything from another origin,
  and may not use `eval` or `new Function`.
- Build DOM with `createElement` and `textContent`. Never assign `innerHTML`
  from data.
- Every control needs a visible label or an `aria-label`, and a target at least
  32px high.
- No build step and no dependencies: the file that ships is the file that runs.
