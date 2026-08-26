/* music: local-file / URL player with a persistent dock.
 *
 * Nothing leaves this browser: files stay as object URLs, the playlist of
 * remote URLs is the only persisted state, written through the plugin's
 * namespaced storage (api.storage). The pre-migration localStorage keys are
 * read once as a fallback so existing playlists survive; nothing is written
 * back to them. The System → Web UI
 * plugins checkbox is the on/off for the whole addon; the dock chevron only
 * tucks the chrome away. */

clanker.registerView({
  id: "music",
  title: "Music",
  group: "Work",

  boot: function (api) {
    Music.ensure(api);
  },

  mount: function (container, api) {
    Music.ensure(api);
    Music.mountView(container);
  },

  refresh: function () {
    Music.draw();
  }
});

var Music = window.clankerMusic || (window.clankerMusic = (function () {
  var audio = new Audio();
  audio.preload = "metadata";
  var tracks = [];
  var index = -1;
  var api = null;
  var viewRoot = null;
  var dock = null;
  var collapsed = false;
  var savedLoaded = false;

  function titleFromUrl(u) {
    try {
      var path = decodeURIComponent((u.split("?")[0] || "").split("/").pop() || u);
      return path || u;
    } catch (e2) {
      return u;
    }
  }

  function fmtTime(sec) {
    if (!isFinite(sec) || sec < 0) return "0:00";
    var s = Math.floor(sec);
    var m = Math.floor(s / 60);
    var r = s % 60;
    return m + ":" + (r < 10 ? "0" : "") + r;
  }

  function persistUrls() {
    var urls = [];
    tracks.forEach(function (t) { if (t.kind === "url") urls.push(t.src); });
    if (api && api.storage) api.storage.set("urls", JSON.stringify(urls));
  }

  function loadSaved() {
    if (savedLoaded || !api || !api.storage) return;
    savedLoaded = true;
    try {
      var dockVal = api.storage.get("dock");
      if (dockVal == null) dockVal = window.localStorage.getItem("clanker.music.dock");
      collapsed = dockVal === "hide";
      var raw = api.storage.get("urls");
      if (raw == null) raw = window.localStorage.getItem("clanker.music.urls");
      var saved = JSON.parse(raw || "[]");
      if (Array.isArray(saved)) {
        saved.forEach(function (u) {
          if (typeof u === "string" && u) tracks.push({ title: titleFromUrl(u), src: u, kind: "url" });
        });
      }
    } catch (e) {}
  }

  function current() { return index >= 0 ? tracks[index] : null; }

  /* timeupdate used to call draw(), which wiped the dock and the Music view
     several times a second. Seeking snapped back, a half-typed URL vanished,
     and the volume slider rebuilt under the pointer. Live chrome is patched
     in place; only add/remove/load/collapse rebuilds the tree. */
  var scrubbing = false;
  var lastError = "";

  function setLastError(msg) {
    lastError = msg || "";
    var notes = document.querySelectorAll(".music-note");
    for (var i = 0; i < notes.length; i++) {
      notes[i].textContent = lastError;
      notes[i].hidden = !lastError;
    }
  }

  function seekRatio() {
    var dur = audio.duration;
    if (!isFinite(dur) || dur <= 0) return 0;
    return audio.currentTime / dur;
  }

  function syncChrome() {
    var paused = audio.paused;
    document.querySelectorAll(".music-btn-play").forEach(function (b) {
      setGlyph(b, paused ? "play" : "pause");
      b.setAttribute("aria-label", paused ? "Play" : "Pause");
    });
    var muted = audio.muted || audio.volume === 0;
    document.querySelectorAll(".music-mute").forEach(function (b) {
      setGlyph(b, muted ? "mute" : "volume");
      b.setAttribute("aria-label", audio.muted ? "Unmute" : "Mute");
    });
    var title = current() ? current().title : "No track";
    document.querySelectorAll(".music-dock-title").forEach(function (el) {
      el.textContent = title;
    });
    var now = current() ? ("Now playing: " + current().title) : "Add a file or a URL to start.";
    document.querySelectorAll(".music-now").forEach(function (el) {
      el.textContent = now;
    });
    if (!scrubbing) {
      var ratio = seekRatio();
      var nowTxt = fmtTime(audio.currentTime);
      var endTxt = fmtTime(isFinite(audio.duration) ? audio.duration : 0);
      document.querySelectorAll(".music-seek").forEach(function (wrap) {
        var bar = wrap.querySelector("input[type=range]");
        var times = wrap.querySelectorAll(".music-time");
        if (bar) bar.value = String(Math.round(ratio * 1000));
        // Position as time, not as 0–1000: a screen reader reading the bare
        // value says "500" where "1:23 of 3:45" is what the sighted times
        // beside it say.
        if (bar) bar.setAttribute("aria-valuetext", nowTxt + " of " + endTxt);
        if (times[0]) times[0].textContent = nowTxt;
        if (times[1]) times[1].textContent = endTxt;
      });
    }
    document.querySelectorAll(".music-vol input[type=range]").forEach(function (vol) {
      if (document.activeElement === vol) return;
    vol.value = String(Math.round((audio.muted ? 0 : audio.volume) * 100));
    vol.setAttribute("aria-valuetext", vol.value + "%");
      vol.setAttribute("aria-valuetext", vol.value + "%");
    });
  }

  function load(i, play) {
    if (i < 0 || i >= tracks.length) return;
    index = i;
    lastError = "";
    audio.src = tracks[i].src;
    if (play) audio.play().catch(function () {});
    draw();
  }

  function playPause() {
    if (!current()) {
      if (tracks.length) load(0, true);
      return;
    }
    if (audio.paused) audio.play().catch(function () {});
    else audio.pause();
    syncChrome();
  }

  function step(delta) {
    if (!tracks.length) return;
    var next = index < 0 ? 0 : (index + delta + tracks.length) % tracks.length;
    load(next, true);
  }

  /* Some desktops report "" as the MIME type for .ogg/.oga/.opus (and
     occasionally mp3), which used to reject them; a few type ogg as
     application/*. Fall back to the file extension when the type is
     empty, and accept the application/ogg aliases. Local files stay
     object URLs in this browser — nothing is uploaded. */
  var AUDIO_EXTS = { mp3: 1, wav: 1, ogg: 1, oga: 1, opus: 1, flac: 1, m4a: 1, aac: 1, weba: 1, webm: 1 };

  function audioExt(name) {
    var m = /\.([a-z0-9]+)$/i.exec(name || "");
    return !!(m && AUDIO_EXTS[m[1].toLowerCase()]);
  }

  function typedAudio(type) {
    return type.indexOf("audio/") === 0 || type === "application/ogg" || type === "application/opus";
  }

  function addFiles(files) {
    var added = 0;
    var skipped = 0;
    Array.prototype.forEach.call(files || [], function (f) {
      if (!f || (f.type ? !typedAudio(f.type) : !audioExt(f.name))) { skipped += 1; return; }
      tracks.push({ title: f.name, src: URL.createObjectURL(f), kind: "file" });
      added += 1;
    });
    if (index < 0 && tracks.length) load(0, false);
    else draw();
    if (!added && skipped) setLastError("Those files are not audio. Pick mp3, ogg, or another audio type.");
    else if (added) setLastError("");
  }

  function addUrl(raw) {
    var u = (raw || "").trim();
    if (!u) return false;
    if (!/^https?:\/\//i.test(u)) {
      setLastError("Need a full http(s) URL, for example https://example.com/track.mp3");
      return false;
    }
    lastError = "";
    tracks.push({ title: titleFromUrl(u), src: u, kind: "url" });
    persistUrls();
    if (index < 0) load(tracks.length - 1, false);
    else draw();
    return true;
  }

  function removeAt(i) {
    if (i < 0 || i >= tracks.length) return;
    var gone = tracks.splice(i, 1)[0];
    if (gone.kind === "file") URL.revokeObjectURL(gone.src);
    persistUrls();
    if (!tracks.length) {
      index = -1;
      audio.removeAttribute("src");
      audio.load();
    } else if (i < index) {
      index -= 1;
    } else if (i === index) {
      load(Math.min(i, tracks.length - 1), !audio.paused);
    }
    draw();
  }

  function setCollapsed(on) {
    collapsed = !!on;
    if (api && api.storage) api.storage.set("dock", collapsed ? "hide" : "show");
    draw();
  }

  // The dock's controls are drawn from the host's one icon grid rather than
  // typed: the glyphs it used came from three Unicode blocks and two of them
  // (the speakers) were emoji, which a browser paints in its own colours next
  // to monochrome siblings. Falls back to the label text where a host predates
  // api.icon so the dock is never a row of blank buttons.
  function setGlyph(b, name) {
    // syncChrome runs on every timeupdate; rebuilding an SVG four times a
    // second for a glyph that did not change is work nobody asked for.
    if (b.dataset.glyph === name) return;
    b.dataset.glyph = name;
    b.textContent = "";
    if (api && api.icon) b.appendChild(api.icon(name, 16));
    else b.textContent = name;
  }

  function btn(name, aria, onclick) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "music-btn";
    setGlyph(b, name);
    b.setAttribute("aria-label", aria);
    b.addEventListener("click", onclick);
    return b;
  }

  function transport(into) {
    into.appendChild(btn("prev", "Previous", function () { step(-1); }));
    var play = btn(audio.paused ? "play" : "pause", audio.paused ? "Play" : "Pause", playPause);
    play.className += " music-btn-play";
    into.appendChild(play);
    into.appendChild(btn("next", "Next", function () { step(1); }));
  }

  function seekBlock() {
    var wrap = document.createElement("div");
    wrap.className = "music-seek";
    var now = document.createElement("span");
    now.className = "music-time";
    now.textContent = fmtTime(audio.currentTime);
    var bar = document.createElement("input");
    bar.type = "range";
    bar.min = "0";
    bar.max = "1000";
    bar.value = "0";
    bar.setAttribute("aria-label", "Seek");
    var dur = audio.duration;
    if (isFinite(dur) && dur > 0) bar.value = String(Math.round((audio.currentTime / dur) * 1000));
    bar.setAttribute("aria-valuetext", fmtTime(audio.currentTime) + " of " + fmtTime(isFinite(dur) ? dur : 0));
    bar.addEventListener("pointerdown", function () { scrubbing = true; });
    bar.addEventListener("pointerup", function () { scrubbing = false; });
    bar.addEventListener("pointercancel", function () { scrubbing = false; });
    bar.addEventListener("input", function () {
      scrubbing = true;
      // Announced while scrubbing: syncChrome skips the bar mid-drag.
      if (isFinite(audio.duration) && audio.duration > 0) {
        bar.setAttribute("aria-valuetext", fmtTime((Number(bar.value) / 1000) * audio.duration) + " of " + fmtTime(audio.duration));
      }
      if (!isFinite(audio.duration) || audio.duration <= 0) return;
      audio.currentTime = (Number(bar.value) / 1000) * audio.duration;
    });
    bar.addEventListener("change", function () { scrubbing = false; syncChrome(); });
    var end = document.createElement("span");
    end.className = "music-time";
    end.textContent = fmtTime(isFinite(dur) ? dur : 0);
    wrap.appendChild(now);
    wrap.appendChild(bar);
    wrap.appendChild(end);
    return wrap;
  }

  function volumeBlock() {
    var wrap = document.createElement("div");
    wrap.className = "music-vol";
    var mute = btn(audio.muted || audio.volume === 0 ? "mute" : "volume", audio.muted ? "Unmute" : "Mute", function () {
      audio.muted = !audio.muted;
      syncChrome();
    });
    mute.className += " music-mute";
    var vol = document.createElement("input");
    vol.type = "range";
    vol.min = "0";
    vol.max = "100";
    vol.value = String(Math.round((audio.muted ? 0 : audio.volume) * 100));
    vol.setAttribute("aria-label", "Volume");
    vol.addEventListener("input", function () {
      audio.muted = false;
      audio.volume = Number(vol.value) / 100;
      vol.setAttribute("aria-valuetext", vol.value + "%");
      syncChrome();
    });
    wrap.appendChild(mute);
    wrap.appendChild(vol);
    return wrap;
  }

  function ensureDock() {
    if (dock && dock.isConnected) return;
    dock = document.createElement("div");
    dock.id = "music-dock";
    dock.className = "music-dock";
    document.body.appendChild(dock);
  }

  function drawDock() {
    ensureDock();
    dock.textContent = "";
    dock.setAttribute("data-collapsed", String(collapsed));
    if (collapsed) {
      var open = btn("note", "Show music player", function () { setCollapsed(false); });
      open.className += " music-fab";
      dock.appendChild(open);
      return;
    }
    var title = document.createElement("span");
    title.className = "music-dock-title";
    title.textContent = current() ? current().title : "No track";
    var transportRow = document.createElement("div");
    transportRow.className = "music-transport";
    transport(transportRow);
    var hide = btn("chevronDown", "Hide music player", function () { setCollapsed(true); });
    var openView = btn("list", "Open music view", function () { if (api) api.showView("music"); });
    dock.appendChild(hide);
    dock.appendChild(title);
    dock.appendChild(transportRow);
    dock.appendChild(seekBlock());
    dock.appendChild(volumeBlock());
    dock.appendChild(openView);
  }

  function drawView() {
    if (!viewRoot) return;
    viewRoot.textContent = "";
    var head = document.createElement("div");
    head.className = "section-head";
    var h = document.createElement("h2");
    h.textContent = "Music";
    head.appendChild(h);
    viewRoot.appendChild(head);

    var now = document.createElement("p");
    now.className = "music-now";
    now.textContent = current() ? ("Now playing: " + current().title) : "Add a file or a URL to start.";
    viewRoot.appendChild(now);

    var controls = document.createElement("div");
    controls.className = "music-panel";
    var transportRow = document.createElement("div");
    transportRow.className = "music-transport";
    transport(transportRow);
    controls.appendChild(transportRow);
    controls.appendChild(seekBlock());
    controls.appendChild(volumeBlock());
    viewRoot.appendChild(controls);

    var add = document.createElement("div");
    add.className = "music-add";
    var fileLab = document.createElement("label");
    fileLab.className = "music-file";
    fileLab.textContent = "Add files";
    var file = document.createElement("input");
    file.type = "file";
    file.accept = "audio/*,.mp3,.wav,.ogg,.oga,.opus,.flac,.m4a,.aac,.webm";
    file.multiple = true;
    file.setAttribute("aria-label", "Add audio files");
    file.addEventListener("change", function () {
      addFiles(file.files);
      file.value = "";
    });
    fileLab.appendChild(file);
    var form = document.createElement("form");
    form.className = "music-url";
    var urlLab = document.createElement("label");
    urlLab.className = "sr-only";
    urlLab.htmlFor = "music-url";
    urlLab.textContent = "Audio URL";
    var url = document.createElement("input");
    url.id = "music-url";
    url.type = "url";
    url.placeholder = "https://…/track.mp3";
    url.autocomplete = "off";
    var go = document.createElement("button");
    go.type = "submit";
    go.className = "secondary";
    go.textContent = "Add URL";
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (!addUrl(url.value)) {
        url.setCustomValidity("Need a full http(s) URL.");
        url.reportValidity();
        url.setCustomValidity("");
        return;
      }
      url.value = "";
    });
    form.appendChild(urlLab);
    form.appendChild(url);
    form.appendChild(go);
    add.appendChild(fileLab);
    add.appendChild(form);
    viewRoot.appendChild(add);

    var list = document.createElement("ul");
    list.className = "music-list";
    list.setAttribute("aria-label", "Playlist");
    if (!tracks.length) {
      var empty = document.createElement("li");
      empty.className = "music-empty";
      empty.textContent = "No tracks yet. Add audio files or a URL above to start.";
      list.appendChild(empty);
    }
    tracks.forEach(function (t, i) {
      var row = document.createElement("li");
      row.className = "music-track" + (i === index ? " is-current" : "");
      var pick = document.createElement("button");
      pick.type = "button";
      pick.className = "music-track-name";
      pick.textContent = t.title;
      pick.addEventListener("click", function () { load(i, true); });
      // A name from the host's icon grid, not a glyph: api.icon returns an
      // empty <span> for anything it does not know, so "×" drew a blank
      // button. The dock's own controls were migrated to the grid; this row
      // was missed.
      var drop = btn("close", "Remove " + t.title, function () { removeAt(i); });
      row.appendChild(pick);
      row.appendChild(drop);
      list.appendChild(row);
    });
    viewRoot.appendChild(list);

    var note = document.createElement("p");
    note.className = "music-note";
    note.setAttribute("role", "status");
    note.hidden = !lastError;
    note.textContent = lastError;
    viewRoot.appendChild(note);

    var hint = document.createElement("p");
    hint.className = "meta";
    hint.textContent = "Turn the player off in System → Web UI plugins. Files never leave this browser.";
    viewRoot.appendChild(hint);
  }

  function draw() {
    drawDock();
    drawView();
  }

  audio.addEventListener("timeupdate", syncChrome);
  audio.addEventListener("play", syncChrome);
  audio.addEventListener("pause", syncChrome);
  audio.addEventListener("ended", function () { step(1); });
  audio.addEventListener("loadedmetadata", syncChrome);
  audio.addEventListener("error", function () {
    var t = current();
    setLastError(t
      ? ("Could not play “" + t.title + "”. Check the file or URL.")
      : "Could not play this track.");
  });

  return {
    ensure: function (nextApi) {
      if (nextApi) api = nextApi;
      loadSaved();
      ensureDock();
      drawDock();
    },
    mountView: function (container) {
      viewRoot = container;
      drawView();
    },
    draw: draw
  };
})());
