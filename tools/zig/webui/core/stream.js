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

if (typeof window !== "undefined") window.ckStream = { makeLineSplitter: makeLineSplitter };
