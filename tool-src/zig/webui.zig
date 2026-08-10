//! webui: serves the clanker web UI — a single-file htmx + Alpine.js page —
//! from the sandbox. Internal tool: it is never offered to the LLM; the
//! `clanker serve` HTTP server calls it to render GET / and /webui.
//! Input:  {"path": "/"}
//! Output: {"ok": true, "content_type": "text/html", "body": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;
    // Any path serves the single-page app (client-side routing is handled in JS).
    var buf: [128 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("content_type");
    try s.write("text/html");
    try s.objectField("body");
    try s.write(page);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

const page =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>clanker</title>
    \\<script src="https://unpkg.com/htmx.org@1.9.12/dist/htmx.min.js"></script>
    \\<script src="https://unpkg.com/htmx.org@1.9.12/dist/ext/json-enc.js"></script>
    \\<script defer src="https://unpkg.com/alpinejs@3.14.1/dist/cdn.min.js"></script>
    \\<style>
    \\  :root { color-scheme: dark; }
    \\  * { box-sizing: border-box; }
    \\  body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 0;
    \\         background: #0d1117; color: #e6edf3; }
    \\  header { display: flex; align-items: center; gap: 0.75rem; padding: 1rem 1.5rem;
    \\           border-bottom: 1px solid #21262d; }
    \\  h1 { font-size: 1.25rem; margin: 0; color: #58a6ff; }
    \\  .badge { font-size: 0.75rem; padding: 0.15rem 0.5rem; border-radius: 999px;
    \\           background: #21262d; color: #8b949e; }
    \\  main { max-width: 56rem; margin: 0 auto; padding: 1.5rem; }
    \\  textarea { width: 100%; min-height: 6rem; padding: 0.75rem; font: inherit;
    \\             background: #161b22; color: #e6edf3; border: 1px solid #30363d;
    \\             border-radius: 6px; resize: vertical; }
    \\  button { padding: 0.5rem 1.25rem; font: inherit; font-weight: 600; color: #0d1117;
    \\           background: #58a6ff; border: 0; border-radius: 6px; cursor: pointer; }
    \\  button:disabled { opacity: 0.5; cursor: wait; }
    \\  .result { white-space: pre-wrap; background: #161b22; border: 1px solid #30363d;
    \\            border-radius: 6px; padding: 1rem; margin-top: 1rem; min-height: 2rem; }
    \\  section { margin-top: 2rem; border-top: 1px solid #21262d; padding-top: 1rem; }
    \\  h2 { font-size: 1rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; }
    \\  dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 1rem; }
    \\  dt { color: #8b949e; }
    \\  ul { margin: 0; padding-left: 1.25rem; }
    \\</style>
    \\</head>
    \\<body x-data="app()" x-init="init()">
    \\<header>
    \\  <h1>clanker</h1>
    \\  <span class="badge" x-text="status ? status.instance.name : 'connecting…'"></span>
    \\</header>
    \\<main>
    \\  <form hx-post="/api/run" hx-ext="json-enc" hx-swap="none"
    \\        x-on:htmx:before-request="busy = true"
    \\        x-on:htmx:after-request="onRun($event)">
    \\    <textarea name="task" x-model="task" placeholder="Task for clanker…"
    \\              :disabled="busy"></textarea>
    \\    <p><button type="submit" :disabled="busy || !task.trim()" x-text="busy ? 'running…' : 'Run'"></button></p>
    \\  </form>
    \\  <pre class="result" x-show="result" x-text="result"></pre>
    \\  <section>
    \\    <h2>Status</h2>
    \\    <dl>
    \\      <dt>instance</dt><dd x-text="status ? status.instance.name + ' (' + status.instance.id + ')' : '—'"></dd>
    \\      <dt>peers</dt>
    \\      <dd>
    \\        <ul x-show="status && status.peers.length">
    \\          <template x-for="p in status ? status.peers : []" :key="p.name">
    \\            <li><b x-text="p.name"></b> — <span x-text="p.url"></span></li>
    \\          </template>
    \\        </ul>
    \\        <span x-show="status && !status.peers.length">no peers configured</span>
    \\      </dd>
    \\    </dl>
    \\  </section>
    \\</main>
    \\<script>
    \\function app() {
    \\  return {
    \\    task: "",
    \\    busy: false,
    \\    result: "",
    \\    status: null,
    \\    init() {
    \\      const self = this;
    \\      fetch("/api/status").then(r => r.json()).then(j => { self.status = j; })
    \\        .catch(() => { self.status = { instance: { name: "offline", id: "?" }, peers: [] }; });
    \\    },
    \\    onRun(evt) {
    \\      this.busy = false;
    \\      try {
    \\        const j = JSON.parse(evt.detail.xhr.responseText);
    \\        this.result = j.ok ? j.content : "error: " + (j.error || "unknown");
    \\      } catch (e) {
    \\        this.result = "bad response: " + evt.detail.xhr.responseText;
    \\      }
    \\    }
    \\  };
    \\}
    \\</script>
    \\</body>
    \\</html>
;
