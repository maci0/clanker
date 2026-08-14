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
      buffer = buffer.replace(/([^\n])\u0001/g, "$1\n\u0001");
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

// Same-origin SSE watch of GET /api/events. Commands stay on fetch POST.
var _liveEs = null;
var _liveOk = false;
var _liveFns = [];

export function liveOk() { return _liveOk; }

export function onLive(fn) {
  if (typeof fn === "function") _liveFns.push(fn);
  ensureLive();
  return function () {
    _liveFns = _liveFns.filter(function (f) { return f !== fn; });
  };
}

function ensureLive() {
  if (_liveEs || typeof EventSource === "undefined") return;
  try { _liveEs = new EventSource("/api/events"); } catch (_) { return; }
  _liveEs.addEventListener("live", function (ev) {
    _liveOk = true;
    var data;
    try { data = JSON.parse(ev.data); } catch (_) { return; }
    for (var i = 0; i < _liveFns.length; i++) {
      try { _liveFns[i](data); } catch (_) {}
    }
  });
  _liveEs.onopen = function () { _liveOk = true; };
  _liveEs.onerror = function () { _liveOk = false; };
}

