---
title: Web UI addons
description: When the operator asks to add something to the web UI (a music player, a timer, a scratch pad, a dashboard), create an addon with the webui_addon tool instead of editing ui/app/.
enabled: true
---

# Web UI addons

When the operator asks to add something to the web UI (a music player, a
timer, a scratch pad, a dashboard), do not edit `ui/app/`. Create an addon
with the `webui_addon` tool.

An addon is `ui/plugins/<name>/plugin.json` + `app.js` (+ optional `app.css`).
The page discovers it at request time. No host rebuild.

## How

1. `webui_addon` `action=create` with `name` (slug), `title`, `group` (`Work`,
   `Watch`, or `Set up`), and `js`. Default `enable` is true.
2. Tell them to open System → Web UI plugins and click Refresh, or reload.
   The new rail tab appears once the script loads. They toggle the addon
   there, or you call `enable` / `disable`.
3. To change it later, `put` the file or `create` again with `overwrite:true`.

## app.js contract

```js
clanker.registerView({
  id: "name",
  title: "Title",
  group: "Work",
  boot: function (api) {
    // Optional. Runs when the script loads, even if the view is closed.
    // Use for a persistent dock (mini-player, status chip).
  },
  mount: function (container, api) {
    // Called the first time the view opens. Build DOM with api.el / createElement.
  },
  refresh: function (container, api) {}
});
```

The tool rejects app.js that skips `clanker.registerView` or uses
`innerHTML`, `eval(`, `new Function`, or `document.write`. The page's CSP
is `script-src 'self'`, so no CDNs. Follow in the app.js you ship: every
control needs a visible label or `aria-label` and a 32px target.

`api`: `el`, `getJSON`, `status`, `fmt`, `showView`, `van`, `preact`, `html`,
`signals`, `render.markdown` / `render.code`.

## Music player (shipped)

`ui/plugins/music/` is the reference: file/URL playlist, play/pause/seek/
volume, a dock that stays up while the addon is enabled, and the System
checkbox to turn the whole thing off.
