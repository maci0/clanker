/* music: local-file / URL player with a persistent dock.
 *
 * Nothing leaves this browser: files stay as object URLs, the playlist of
 * remote URLs is the only thing written to localStorage. The System → Web UI
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

  try {
    collapsed = window.localStorage.getItem("clanker.music.dock") === "hide";
    var saved = JSON.parse(window.localStorage.getItem("clanker.music.urls") || "[]");
    if (Array.isArray(saved)) {
      saved.forEach(function (u) {
        if (typeof u === "string" && u) tracks.push({ title: titleFromUrl(u), src: u, kind: "url" });
      });
    }
  } catch (e) {}

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
    try { window.localStorage.setItem("clanker.music.urls", JSON.stringify(urls)); } catch (e) {}
  }

  function current() { return index >= 0 ? tracks[index] : null; }

  function load(i, play) {
    if (i < 0 || i >= tracks.length) return;
    index = i;
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
    draw();
  }

  function step(delta) {
    if (!tracks.length) return;
    var next = index < 0 ? 0 : (index + delta + tracks.length) % tracks.length;
    load(next, true);
  }

  function addFiles(files) {
    Array.prototype.forEach.call(files || [], function (f) {
      if (!f || !f.type || f.type.indexOf("audio/") !== 0) return;
      tracks.push({ title: f.name, src: URL.createObjectURL(f), kind: "file" });
    });
    if (index < 0 && tracks.length) load(0, false);
    draw();
  }

  function addUrl(raw) {
    var u = (raw || "").trim();
    if (!u) return;
    tracks.push({ title: titleFromUrl(u), src: u, kind: "url" });
    persistUrls();
    if (index < 0) load(tracks.length - 1, false);
    draw();
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
    try { window.localStorage.setItem("clanker.music.dock", collapsed ? "hide" : "show"); } catch (e) {}
    draw();
  }

  function btn(label, aria, onclick) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "music-btn";
    b.textContent = label;
    b.setAttribute("aria-label", aria);
    b.addEventListener("click", onclick);
    return b;
  }

  function transport(into) {
    into.appendChild(btn("⏮", "Previous", function () { step(-1); }));
    var play = btn(audio.paused ? "▶" : "❚❚", audio.paused ? "Play" : "Pause", playPause);
    play.className += " music-btn-play";
    into.appendChild(play);
    into.appendChild(btn("⏭", "Next", function () { step(1); }));
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
    bar.addEventListener("input", function () {
      if (!isFinite(audio.duration) || audio.duration <= 0) return;
      audio.currentTime = (Number(bar.value) / 1000) * audio.duration;
    });
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
    var mute = btn(audio.muted || audio.volume === 0 ? "🔇" : "🔊", audio.muted ? "Unmute" : "Mute", function () {
      audio.muted = !audio.muted;
      draw();
    });
    var vol = document.createElement("input");
    vol.type = "range";
    vol.min = "0";
    vol.max = "100";
    vol.value = String(Math.round((audio.muted ? 0 : audio.volume) * 100));
    vol.setAttribute("aria-label", "Volume");
    vol.addEventListener("input", function () {
      audio.muted = false;
      audio.volume = Number(vol.value) / 100;
      draw();
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
      var open = btn("♪", "Show music player", function () { setCollapsed(false); });
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
    var hide = btn("▾", "Hide music player", function () { setCollapsed(true); });
    var openView = btn("☰", "Open music view", function () { if (api) api.showView("music"); });
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
    file.accept = "audio/*";
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
      addUrl(url.value);
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
      empty.textContent = "Playlist is empty.";
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
      var drop = btn("×", "Remove " + t.title, function () { removeAt(i); });
      row.appendChild(pick);
      row.appendChild(drop);
      list.appendChild(row);
    });
    viewRoot.appendChild(list);

    var hint = document.createElement("p");
    hint.className = "meta";
    hint.textContent = "Turn the player off in System → Web UI plugins. Files never leave this browser.";
    viewRoot.appendChild(hint);
  }

  function draw() {
    drawDock();
    drawView();
  }

  audio.addEventListener("timeupdate", draw);
  audio.addEventListener("play", draw);
  audio.addEventListener("pause", draw);
  audio.addEventListener("ended", function () { step(1); });
  audio.addEventListener("loadedmetadata", draw);

  return {
    ensure: function (nextApi) {
      if (nextApi) api = nextApi;
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
