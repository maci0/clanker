// ck.h — shared host ABI for clanker tools written in C or C++.
//
// Same role as tools/zig/lib.zig and tools/ts/lib.ts: the scratch/host_arena/
// out buffer plumbing and the ck_* host imports, once, so a tool file is just
// its own logic. wasm32-freestanding, no libc: <stdint.h>/<stddef.h> are
// compiler-provided typedef headers with no linkage requirement, but nothing
// here calls into an actual C library (memcpy, strlen, malloc) — those are
// hand-rolled below, the same discipline the Zig and AssemblyScript tools
// already follow, so a build with no libc present still links.
//
// A tool file does:
//   #include "../c/ck.h"
//   u32 scratch(u32 need) { return ck_scratch(need); }
//   u32 host_arena(void) { return ck_host_arena(); }
//   u64 run(u32 ptr, u32 len) { ... return ck_ok_text("..."); }

#ifndef CLANKER_CK_H
#define CLANKER_CK_H

#include <stdint.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uintptr_t uptr;

// ---- host function imports (provided by the harness) -----------------------
__attribute__((import_module("env"), import_name("ck_log")))
extern void ck_log_raw(u32 level, u32 ptr, u32 len);

__attribute__((import_module("env"), import_name("ck_now")))
extern u64 ck_now(void);

__attribute__((import_module("env"), import_name("ck_random")))
extern u64 ck_random(void);

// ---- tiny freestanding replacements for the libc calls C would reach for --
static inline u32 ck_strlen(const char *s) {
  u32 n = 0;
  while (s[n]) n++;
  return n;
}

static inline void ck_memcpy(void *dst, const void *src, u32 n) {
  u8 *d = (u8 *)dst;
  const u8 *s = (const u8 *)src;
  for (u32 i = 0; i < n; i++) d[i] = s[i];
}

// ---- buffers -----------------------------------------------------------------
#define CK_BUF 65536

static u8 ck_scratch_buf[CK_BUF];
static u8 ck_arena_buf[CK_BUF];
static u8 ck_out_buf[CK_BUF];

/// Called from the tool file's own `scratch` export.
static inline u32 ck_scratch(u32 need) {
  if (need > CK_BUF) return 0;
  return (u32)(uptr)ck_scratch_buf;
}

/// Called from the tool file's own `host_arena` export.
static inline u32 ck_host_arena(void) {
  return (u32)(uptr)ck_arena_buf;
}

static inline void ck_log(u32 level, const char *msg) {
  ck_log_raw(level, (u32)(uptr)msg, ck_strlen(msg));
}

/// Reads the tool's raw input bytes. `ptr`/`len` are exactly `run`'s
/// arguments — the bytes already live in this module's own linear memory
/// (the host wrote them via `scratch`), so this is just a cast, not a copy.
static inline const u8 *ck_input(u32 ptr) {
  return (const u8 *)(uptr)ptr;
}

/// Copies `len` bytes into the out buffer and returns the packed
/// (ptr << 32 | len) result every tool's run() must return. Output over
/// CK_BUF is truncated, not trapped: a tool returning too much is a bug to
/// see and fix, not a crash for the caller.
static inline u64 ck_write_result(const void *bytes, u32 len) {
  u32 n = len > CK_BUF ? CK_BUF : len;
  ck_memcpy(ck_out_buf, bytes, n);
  return ((u64)(u32)(uptr)ck_out_buf << 32) | (u64)n;
}

static inline u64 ck_write_str(const char *s) {
  return ck_write_result(s, ck_strlen(s));
}

// ---- minimal JSON string escaping + ok/fail envelopes -----------------------
// Enough for the flat `text`/`error` fields every tool here returns — not a
// general JSON writer. A tool that needs to build a nested JSON document
// writes its own bytes into a stack buffer and calls ck_write_result once.

/// Appends the JSON-escaped form of `s` (length `len`) to `out`, advancing
/// `*pos`. `cap` bounds `out`; a `s` that would overflow it is truncated.
static inline void ck_json_escape_into(char *out, u32 cap, u32 *pos, const char *s, u32 len) {
  for (u32 i = 0; i < len && *pos < cap; i++) {
    u8 c = (u8)s[i];
    if (c == '"' || c == '\\') {
      if (*pos + 2 > cap) break;
      out[(*pos)++] = '\\';
      out[(*pos)++] = (char)c;
    } else if (c == '\n') {
      if (*pos + 2 > cap) break;
      out[(*pos)++] = '\\';
      out[(*pos)++] = 'n';
    } else if (c == '\r') {
      if (*pos + 2 > cap) break;
      out[(*pos)++] = '\\';
      out[(*pos)++] = 'r';
    } else if (c == '\t') {
      if (*pos + 2 > cap) break;
      out[(*pos)++] = '\\';
      out[(*pos)++] = 't';
    } else if (c < 0x20) {
      // Rare in tool output; skipped rather than \u-escaped to keep this
      // helper small — every caller here emits printable ASCII/UTF-8.
      continue;
    } else {
      out[(*pos)++] = (char)c;
    }
  }
}

/// `{"ok":true,"text":"<escaped text>"}`.
static inline u64 ck_ok_text(const char *text) {
  static char buf[CK_BUF];
  u32 pos = 0;
  const char *head = "{\"ok\":true,\"text\":\"";
  u32 hn = ck_strlen(head);
  ck_memcpy(buf, head, hn);
  pos = hn;
  ck_json_escape_into(buf, CK_BUF - 2, &pos, text, ck_strlen(text));
  buf[pos++] = '"';
  buf[pos++] = '}';
  return ck_write_result(buf, pos);
}

/// `{"ok":false,"error":"<escaped msg>"}`. Also logged at error level, the
/// same convention lib.zig's `fail` and lib.ts's `fail` follow.
static inline u64 ck_fail(const char *msg) {
  ck_log(3, msg);
  static char buf[CK_BUF];
  u32 pos = 0;
  const char *head = "{\"ok\":false,\"error\":\"";
  u32 hn = ck_strlen(head);
  ck_memcpy(buf, head, hn);
  pos = hn;
  ck_json_escape_into(buf, CK_BUF - 2, &pos, msg, ck_strlen(msg));
  buf[pos++] = '"';
  buf[pos++] = '}';
  return ck_write_result(buf, pos);
}

#endif // CLANKER_CK_H
