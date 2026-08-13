// Arena v2: the same judged debate as features/arena.js, staged in 3D.
//
// Same contract as the 2D canvas: purely decorative (aria-hidden), carries
// nothing the transcript and #arena-status do not carry in words, honours
// reduced motion by rendering one still frame with no loop, reads its whole
// palette from the active theme's tokens, and never leaves a rAF running
// while the view is hidden. three.js is vendored (script-src 'self') and
// loaded lazily on first toggle, so sessions that never open 3D never pay
// for it.
//
// The scene: a ringed disc floating in fog. One geometric avatar per
// combatant — a different platonic-ish solid per index, hue from the same
// hash the 2D view and Fleet use, so a combatant keeps its colour across
// every view. HP is a depleting arc under each avatar. Moves play as
// effects: attack/counter fire a glowing bolt along an arc, block flashes a
// shield shell, final_stand raises a light pillar, a concession sinks the
// avatar, and an elimination shatters it into particles that drain into the
// centre — the compactor's job, done as a vortex.

var THREE = null;
var S = null; // live scene state, null when unmounted

function reducedMotion() {
  return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
}

function _hash(s) { var h = 0; for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0; return h >>> 0; }
function hueFor(name) { return (_hash(name || "") % 360) / 360; }

function themeVar(name) {
  var root = document.documentElement;
  if (!root) return "";
  var v = (getComputedStyle(root).getPropertyValue(name) || "").trim();
  var m = /^var\(\s*([--A-Za-z0-9_]+)\s*\)$/.exec(v);
  return m ? themeVar(m[1]) : v;
}
function colOr(name, fallback) {
  var v = themeVar(name);
  return v || fallback;
}
function pal() {
  return {
    bg: colOr("--surface-2", "#1d2225"),
    fg: colOr("--fg", "#ffffff"),
    rule: colOr("--rule", "#343b3f"),
    ok: colOr("--ok", "#2fae4d"),
    warn: colOr("--warn", "#e5b54a"),
    danger: colOr("--danger", "#dc4c3f"),
    accent: colOr("--accent", "#7aa2f7")
  };
}

export function loadThree() {
  if (THREE) return Promise.resolve(THREE);
  return import("/webui/vendor/three.module.min.js").then(function (mod) {
    THREE = mod;
    return THREE;
  });
}

/* ------------------------------------------------------------- avatar text */

// Label sprites are canvas textures: three has no text, and HTML overlays
// would fight the WebGL canvas for layout. 128px canvas, theme fg.
function labelSprite(text, color) {
  var cv = document.createElement("canvas");
  cv.width = 256; cv.height = 64;
  var ctx = cv.getContext("2d");
  ctx.font = "600 28px ui-monospace, monospace";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = color;
  ctx.fillText(String(text).slice(0, 16), 128, 32);
  var tex = new THREE.CanvasTexture(cv);
  tex.colorSpace = THREE.SRGBColorSpace;
  var mat = new THREE.SpriteMaterial({ map: tex, transparent: true, depthWrite: false });
  var sp = new THREE.Sprite(mat);
  sp.scale.set(2.4, 0.6, 1);
  return sp;
}

// One solid per slot: the shape is identity the way the hue is.
function avatarGeometry(i) {
  switch (i % 6) {
    case 0: return new THREE.IcosahedronGeometry(0.55, 0);
    case 1: return new THREE.OctahedronGeometry(0.62, 0);
    case 2: return new THREE.TorusKnotGeometry(0.34, 0.12, 64, 8);
    case 3: return new THREE.DodecahedronGeometry(0.55, 0);
    case 4: return new THREE.ConeGeometry(0.5, 0.9, 6);
    default: return new THREE.TetrahedronGeometry(0.66, 0);
  }
}

/* ------------------------------------------------------------------ mount */

export function mountArena3D(host) {
  if (S) return Promise.resolve();
  return loadThree().then(function () {
    var w = host.clientWidth || 640;
    var h = Math.max(240, Math.round(w * 0.45));
    var renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(w, h);
    renderer.domElement.style.width = "100%";
    renderer.domElement.style.height = "auto";
    renderer.domElement.style.borderRadius = "var(--radius)";
    renderer.domElement.style.border = "1px solid var(--rule)";
    host.appendChild(renderer.domElement);

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(42, w / h, 0.1, 100);

    S = {
      host: host, renderer: renderer, scene: scene, camera: camera,
      avatars: [], effects: [], raf: null, clock: 0, last: 0,
      orbit: { az: 0.9, el: 0.42, r: 9, drag: null, auto: true },
      match: null, lastMoveKey: "", shattered: {}, disposables: []
    };

    buildStage();
    bindPointer();
    applyTheme();
    return S;
  });
}

function track(obj) { S.disposables.push(obj); return obj; }

function buildStage() {
  var floor = new THREE.Group();
  // The disc, its ring, and radial spokes: the 2D view's tiled ground as a
  // dais. Materials are re-tinted in applyTheme, not rebuilt.
  var disc = new THREE.Mesh(
    track(new THREE.CylinderGeometry(4.4, 4.6, 0.22, 64)),
    track(new THREE.MeshStandardMaterial({ roughness: 0.85, metalness: 0.1 }))
  );
  disc.name = "disc";
  floor.add(disc);
  var ring = new THREE.Mesh(
    track(new THREE.TorusGeometry(4.5, 0.045, 12, 96)),
    track(new THREE.MeshBasicMaterial())
  );
  ring.rotation.x = Math.PI / 2;
  ring.position.y = 0.12;
  ring.name = "ring";
  floor.add(ring);
  var spokes = new THREE.Group();
  spokes.name = "spokes";
  for (var i = 0; i < 12; i++) {
    var sp = new THREE.Mesh(
      track(new THREE.BoxGeometry(4.1, 0.012, 0.02)),
      track(new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.25 }))
    );
    sp.position.y = 0.115;
    sp.rotation.y = (i / 12) * Math.PI;
    spokes.add(sp);
  }
  floor.add(spokes);
  S.scene.add(floor);
  S.floor = floor;

  S.amb = new THREE.AmbientLight(0xffffff, 0.55);
  S.key = new THREE.DirectionalLight(0xffffff, 1.4);
  S.key.position.set(3, 7, 4);
  S.rim = new THREE.PointLight(0xffffff, 8, 30);
  S.rim.position.set(-5, 3, -5);
  S.scene.add(S.amb, S.key, S.rim);
}

function applyTheme() {
  if (!S) return;
  var p = pal();
  var bg = new THREE.Color(p.bg);
  S.scene.background = bg;
  S.scene.fog = new THREE.Fog(bg, 10, 26);
  S.floor.getObjectByName("disc").material.color.set(p.rule);
  S.floor.getObjectByName("ring").material.color.set(p.accent);
  S.floor.getObjectByName("spokes").children.forEach(function (sp) { sp.material.color.set(p.fg); });
}

/* --------------------------------------------------------------- avatars */

function placeFor(i, n) {
  // Pairwise faces the two across the centre, like the 2D stage; a royale
  // spreads the circle.
  var a = n <= 2 ? (i === 0 ? Math.PI : 0) : (i / n) * Math.PI * 2 - Math.PI / 2;
  var r = n <= 2 ? 2.6 : 3.1;
  return new THREE.Vector3(Math.cos(a) * r, 0.95, Math.sin(a) * r);
}

function buildAvatars(m) {
  S.avatars.forEach(function (a) { S.scene.remove(a.group); });
  S.avatars = [];
  var cs = m.combatants || [];
  cs.forEach(function (c, i) {
    var hue = hueFor(c.label || String(i));
    var color = new THREE.Color().setHSL(hue, 0.5, 0.6);
    var group = new THREE.Group();
    var body = new THREE.Mesh(
      track(avatarGeometry(i)),
      track(new THREE.MeshStandardMaterial({
        color: color, roughness: 0.35, metalness: 0.25,
        emissive: color.clone().multiplyScalar(0.25)
      }))
    );
    body.name = "body";
    group.add(body);

    // HP arc: a flat ring sector on the floor under the avatar, rebuilt only
    // when hp changes (cheap: 1 small geometry).
    var hpArc = new THREE.Mesh(hpGeometry(1), track(new THREE.MeshBasicMaterial({ side: THREE.DoubleSide })));
    hpArc.rotation.x = -Math.PI / 2;
    hpArc.position.y = -0.78;
    hpArc.name = "hp";
    group.add(hpArc);

    var label = labelSprite(c.label || ("#" + (i + 1)), pal().fg);
    label.position.y = 1.15;
    group.add(label);

    group.position.copy(placeFor(i, cs.length));
    S.scene.add(group);
    S.avatars.push({ group: group, body: body, hp: hpArc, base: group.position.clone(), hue: hue, hpFrac: 1, out: false });
  });
}

function hpGeometry(frac) {
  return new THREE.RingGeometry(0.62, 0.78, 40, 1, Math.PI / 2, Math.max(0.02, frac) * Math.PI * 2);
}

function hpColorOf(frac, p) {
  return frac > 0.5 ? p.ok : (frac > 0.2 ? p.warn : p.danger);
}

/* ---------------------------------------------------------------- effects */

function lastMove(m) {
  var rounds = m.rounds || [];
  for (var i = rounds.length - 1; i >= 0; i--) {
    var mv = rounds[i].moves || [];
    if (mv.length) return mv[mv.length - 1];
  }
  return null;
}

// A move effect is a closure advanced per-frame until it returns false.
function addBolt(fromI, toI, color) {
  var a = S.avatars[fromI], b = S.avatars[toI];
  if (!a || !b) return;
  var mat = track(new THREE.MeshBasicMaterial({ color: color }));
  var bolt = new THREE.Mesh(track(new THREE.SphereGeometry(0.12, 12, 12)), mat);
  var trail = new THREE.PointLight(color, 12, 6);
  bolt.add(trail);
  S.scene.add(bolt);
  var t0 = S.clock;
  S.effects.push(function () {
    var t = (S.clock - t0) / 0.55;
    if (t >= 1) {
      S.scene.remove(bolt);
      addFlash(b.group.position, color);
      return false;
    }
    var p0 = a.group.position, p1 = b.group.position;
    bolt.position.lerpVectors(p0, p1, t);
    bolt.position.y += Math.sin(t * Math.PI) * 1.5; // the arc
    return true;
  });
}

function addFlash(at, color) {
  var light = new THREE.PointLight(color, 30, 8);
  light.position.copy(at);
  S.scene.add(light);
  var t0 = S.clock;
  S.effects.push(function () {
    var t = (S.clock - t0) / 0.35;
    if (t >= 1) { S.scene.remove(light); return false; }
    light.intensity = 30 * (1 - t);
    return true;
  });
}

function addShield(i, color) {
  var a = S.avatars[i];
  if (!a) return;
  var shell = new THREE.Mesh(
    track(new THREE.SphereGeometry(0.9, 24, 16)),
    track(new THREE.MeshBasicMaterial({ color: color, transparent: true, opacity: 0.35, side: THREE.DoubleSide }))
  );
  shell.position.copy(a.group.position);
  S.scene.add(shell);
  var t0 = S.clock;
  S.effects.push(function () {
    var t = (S.clock - t0) / 0.8;
    if (t >= 1) { S.scene.remove(shell); return false; }
    shell.scale.setScalar(1 + t * 0.35);
    shell.material.opacity = 0.35 * (1 - t);
    return true;
  });
}

function addPillar(i, color) {
  var a = S.avatars[i];
  if (!a) return;
  var beam = new THREE.Mesh(
    track(new THREE.CylinderGeometry(0.5, 0.7, 9, 24, 1, true)),
    track(new THREE.MeshBasicMaterial({ color: color, transparent: true, opacity: 0.3, side: THREE.DoubleSide }))
  );
  beam.position.copy(a.group.position);
  beam.position.y = 4.4;
  S.scene.add(beam);
  var t0 = S.clock;
  S.effects.push(function () {
    var t = (S.clock - t0) / 1.4;
    if (t >= 1) { S.scene.remove(beam); return false; }
    beam.material.opacity = 0.3 * (1 - t);
    beam.rotation.y = t * 2;
    return true;
  });
}

// Elimination: the avatar shatters into its own vertices, and the shards
// spiral into the centre and down — the compactor as a vortex.
function addShatter(i) {
  var a = S.avatars[i];
  if (!a || a.shattered) return;
  a.shattered = true;
  a.body.visible = false;
  var color = new THREE.Color().setHSL(a.hue, 0.5, 0.6);
  var count = 90;
  var geo = track(new THREE.BufferGeometry());
  var pos = new Float32Array(count * 3);
  var seed = [];
  for (var k = 0; k < count; k++) {
    var v = new THREE.Vector3().randomDirection().multiplyScalar(0.4 + Math.random() * 0.3).add(a.group.position);
    pos[k * 3] = v.x; pos[k * 3 + 1] = v.y; pos[k * 3 + 2] = v.z;
    seed.push({ p: v, ang: Math.atan2(v.z, v.x), r: Math.hypot(v.x, v.z), y: v.y, spin: 1.5 + Math.random() * 2 });
  }
  geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
  var pts = new THREE.Points(geo, track(new THREE.PointsMaterial({ color: color, size: 0.07, transparent: true })));
  S.scene.add(pts);
  var t0 = S.clock;
  S.effects.push(function () {
    var t = (S.clock - t0) / 2.6;
    if (t >= 1) { S.scene.remove(pts); return false; }
    var arr = pts.geometry.attributes.position.array;
    for (var k2 = 0; k2 < seed.length; k2++) {
      var s = seed[k2];
      var r = s.r * (1 - t);
      var ang = s.ang + s.spin * t * 3;
      arr[k2 * 3] = Math.cos(ang) * r;
      arr[k2 * 3 + 1] = s.y * (1 - t) - t * 1.2;
      arr[k2 * 3 + 2] = Math.sin(ang) * r;
    }
    pts.geometry.attributes.position.needsUpdate = true;
    pts.material.opacity = 1 - t * 0.7;
    return true;
  });
}

function addCrown(i) {
  var a = S.avatars[i];
  if (!a || a.crowned) return;
  a.crowned = true;
  var p = pal();
  var halo = new THREE.Mesh(
    track(new THREE.TorusGeometry(0.5, 0.035, 10, 48)),
    track(new THREE.MeshBasicMaterial({ color: p.ok }))
  );
  halo.rotation.x = Math.PI / 2;
  halo.position.y = 0.95;
  halo.name = "halo";
  a.group.add(halo);
}

/* ------------------------------------------------------------------ update */

// Called by arena.js on every renderMatch while 3D is active. Diffs the
// match into scene changes; the frame loop only animates what this queued.
export function updateArena3D(m) {
  if (!S || !m) return;
  var rebuild = !S.match || (S.match.id !== m.id) ||
    ((S.match.combatants || []).length !== (m.combatants || []).length);
  S.match = m;
  if (rebuild) {
    S.lastMoveKey = "";
    buildAvatars(m);
    applyTheme();
  }

  var p = pal();
  (m.combatants || []).forEach(function (c, i) {
    var a = S.avatars[i];
    if (!a) return;
    var frac = c.max_hp ? Math.max(0, c.hp / c.max_hp) : 0;
    if (frac !== a.hpFrac) {
      a.hpFrac = frac;
      a.hp.geometry.dispose();
      a.hp.geometry = hpGeometry(frac);
    }
    a.hp.material.color.set(hpColorOf(frac, p));
    var gone = c.eliminated || c.conceded;
    if (gone && !a.out) {
      a.out = true;
      if (c.eliminated && !reducedMotion()) addShatter(i);
    }
    a.body.material.opacity = 1;
    if (m.verdict && m.verdict.winner === i) addCrown(i);
  });

  // Play the newest move exactly once, keyed the same way the 2D view keys
  // its pose clock.
  var last = lastMove(m);
  var key = last ? (last.round + ":" + last.combatant + ":" + last.move) : "";
  if (last && key !== S.lastMoveKey) {
    S.lastMoveKey = key;
    if (!reducedMotion()) {
      var actor = last.combatant;
      var target = typeof last.target === "number" ? last.target : (actor === 0 ? 1 : 0);
      var hue = S.avatars[actor] ? S.avatars[actor].hue : 0;
      var color = new THREE.Color().setHSL(hue, 0.7, 0.6);
      if (last.move === "attack" || last.move === "counter") addBolt(actor, target, color);
      else if (last.move === "block") addShield(actor, color);
      else if (last.move === "final_stand") { addPillar(actor, color); addBolt(actor, target, color); }
    }
  }

  if (reducedMotion()) {
    stopLoop();
    stepScene(0);
    S.renderer.render(S.scene, S.camera);
    return;
  }
  startLoop();
}

/* ------------------------------------------------------------- frame loop */

function startLoop() {
  if (S.raf) return;
  S.last = performance.now();
  S.raf = window.requestAnimationFrame(tick);
}
function stopLoop() {
  if (S && S.raf) { window.cancelAnimationFrame(S.raf); S.raf = null; }
}

function tick(now) {
  if (!S) return;
  S.raf = null;
  // Same no-background-timer rule as the 2D canvas: a hidden view stops.
  var view = document.getElementById("view-arena");
  if (!document.body.contains(S.renderer.domElement) || (view && view.hidden)) return;
  var dt = Math.min(0.05, (now - S.last) / 1000);
  S.last = now;
  S.clock += dt;
  stepScene(dt);
  S.renderer.render(S.scene, S.camera);
  S.raf = window.requestAnimationFrame(tick);
}

function stepScene(dt) {
  var t = S.clock;
  if (S.orbit.auto && dt > 0) S.orbit.az += dt * 0.12;
  var o = S.orbit;
  S.camera.position.set(
    Math.cos(o.az) * Math.cos(o.el) * o.r,
    Math.sin(o.el) * o.r,
    Math.sin(o.az) * Math.cos(o.el) * o.r
  );
  S.camera.lookAt(0, 0.6, 0);

  S.avatars.forEach(function (a, i) {
    var gone = a.out;
    var bob = gone ? 0 : Math.sin(t * 1.5 + i * 1.1) * 0.08;
    a.group.position.y = a.base.y + bob + (a.sink || 0);
    if (!gone) {
      a.body.rotation.y += dt * (0.4 + i * 0.07);
      a.body.rotation.x = Math.sin(t * 0.7 + i) * 0.12;
    } else if (S.match && S.match.combatants[i] && S.match.combatants[i].conceded && !S.match.combatants[i].eliminated) {
      // A concession sinks to half-height and dims, but stays on stage.
      a.sink = Math.max(-0.5, (a.sink || 0) - dt * 0.3);
      a.body.material.transparent = true;
      a.body.material.opacity = Math.max(0.35, a.body.material.opacity - dt * 0.5);
    }
    var halo = a.group.getObjectByName("halo");
    if (halo) { halo.rotation.z += dt * 1.2; halo.position.y = 0.95 + Math.sin(t * 2) * 0.05; }
  });

  S.effects = S.effects.filter(function (fx) { return fx(); });
}

/* ---------------------------------------------------------------- pointer */

function bindPointer() {
  var el = S.renderer.domElement;
  el.style.touchAction = "none";
  el.addEventListener("pointerdown", function (e) {
    S.orbit.drag = { x: e.clientX, y: e.clientY, az: S.orbit.az, el: S.orbit.el };
    S.orbit.auto = false;
    el.setPointerCapture(e.pointerId);
  });
  el.addEventListener("pointermove", function (e) {
    var d = S && S.orbit.drag;
    if (!d) return;
    S.orbit.az = d.az + (e.clientX - d.x) * 0.008;
    S.orbit.el = Math.max(0.12, Math.min(1.2, d.el + (e.clientY - d.y) * 0.006));
    if (reducedMotion()) { stepScene(0); S.renderer.render(S.scene, S.camera); }
  });
  el.addEventListener("pointerup", function () {
    if (S) { S.orbit.drag = null; S.orbit.auto = true; }
  });
  el.addEventListener("wheel", function (e) {
    e.preventDefault();
    S.orbit.r = Math.max(5, Math.min(16, S.orbit.r + e.deltaY * 0.01));
    if (reducedMotion()) { stepScene(0); S.renderer.render(S.scene, S.camera); }
  }, { passive: false });
}

/* ---------------------------------------------------------------- theming */

export function retheme() {
  if (!S) return;
  applyTheme();
  var p = pal();
  S.avatars.forEach(function (a) { a.hp.material.color.set(hpColorOf(a.hpFrac, p)); });
  if (reducedMotion()) { stepScene(0); S.renderer.render(S.scene, S.camera); }
}

/* ---------------------------------------------------------------- unmount */

export function unmountArena3D() {
  if (!S) return;
  stopLoop();
  // Dispose GPU resources, not just the DOM node: a toggled-off stage must
  // not keep buffers alive for a view nobody is looking at.
  S.disposables.forEach(function (d) { if (d && d.dispose) d.dispose(); });
  S.renderer.dispose();
  if (S.renderer.domElement.parentNode) S.renderer.domElement.parentNode.removeChild(S.renderer.domElement);
  S = null;
}

export function arena3dActive() { return !!S; }
