// Vanilla, no bundler. Stream line splitter extracted from app.js.
// Pure: no DOM, no el — splits streamed bytes on "\n" and handles the
// \x01 control prefix that the /api/run stream uses for out-of-band events.
export function makeLineSplitter(onLine) {
  var buffer = "";
  return {
    push: function (chunk) {
      buffer += chunk;
      // A control event is introduced by \x01 and terminated by a newline,
      // but the answer text before it need not end in one. Without this the
      // two share a line, the \x01 test fails because it is not at index 0,
      // and the raw {"type":"done"} JSON lands in the answer while the
      // turn's stats never render. JSON escapes control characters, so a
      // literal \x01 only ever appears as this marker.
      buffer = buffer.replace(/([^\n])\u0001/g, "$1\n\u0001"); // eslint-disable-line no-control-regex -- \u0001 is the /api/run stream marker
      var lines = buffer.split("\n");
      buffer = lines.pop();
      for (var i = 0; i < lines.length; i++) onLine(lines[i], true);
    },
    flush: function () {
      if (buffer) onLine(buffer, false);
      buffer = "";
    }
  };
}

// Drain a fetch body into a splitter. The caller flushes once this resolves.
export function pumpInto(body, splitter) {
  var reader = body.getReader();
  var decoder = new TextDecoder();
  return (function pump() {
    return reader.read().then(function (chunk) {
      if (chunk.done) return;
      splitter.push(decoder.decode(chunk.value, { stream: true }));
      return pump();
    });
  })();
}

// Same-origin SSE watch of GET /api/events. Commands stay on fetch POST.
// Absent endpoint (404) is soft-fail: probe once, never leave EventSource
// reconnecting into console noise.
var _liveEs = null;
var _liveOk = false;
var _liveFns = [];
var _liveProbe = null;
var _liveDisabled = false;

export function liveOk() { return _liveOk; }

export function onLive(fn) {
  if (typeof fn === "function") _liveFns.push(fn);
  ensureLive();
  return function () {
    _liveFns = _liveFns.filter(function (f) { return f !== fn; });
  };
}

function killLive() {
  _liveOk = false;
  if (_liveEs) {
    try { _liveEs.close(); } catch (_) {}
    _liveEs = null;
  }
}

function attachLive() {
  if (_liveEs || _liveDisabled || typeof EventSource === "undefined") return;
  try { _liveEs = new EventSource("/api/events"); } catch (_) {
    _liveDisabled = true;
    return;
  }
  _liveEs.addEventListener("live", function (ev) {
    _liveOk = true;
    var data;
    try { data = JSON.parse(ev.data); } catch (_) { return; }
    for (var i = 0; i < _liveFns.length; i++) {
      try { _liveFns[i](data); } catch (_) {}
    }
  });
  _liveEs.onopen = function () { _liveOk = true; };
  _liveEs.onerror = function () {
    _liveOk = false;
    // First failure with CONNECTING/CLOSED after open attempt: stop retrying
    // when the server has no live bus (404) or dropped the stream permanently.
    if (!_liveEs) return;
    if (_liveEs.readyState === EventSource.CLOSED) {
      _liveDisabled = true;
      killLive();
    }
  };
}

function ensureLive() {
  if (_liveEs || _liveDisabled || typeof EventSource === "undefined") return;
  if (_liveProbe) return;
  _liveProbe = fetch("/api/events", {
    method: "GET",
    headers: { Accept: "text/event-stream" },
    cache: "no-store",
  }).then(function (res) {
    _liveProbe = null;
    if (!res.ok) {
      _liveDisabled = true;
      try { res.body && res.body.cancel && res.body.cancel(); } catch (_) {}
      return;
    }
    // Abort the probe body; EventSource owns the real stream.
    try { res.body && res.body.cancel && res.body.cancel(); } catch (_) {}
    attachLive();
  }).catch(function () {
    _liveProbe = null;
    _liveDisabled = true;
  });
}

