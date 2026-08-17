//! The record stores' search matching, in one place.
//!
//! `search` used to hand the whole query to one host grep, which is an exact
//! substring per line. That is the phrase form with no way to ask for the
//! other one, so `reports search "concurrent sessions"` answered "no report or
//! runbook mentions it" while
//! `docs/runbooks/concurrent-agent-sessions-on-one-checkout.md` sat in the
//! store saying both words on different lines, and the caller concluded the
//! runbook was missing. A search over the project's own memory that misses an
//! existing record is the expensive failure: the answer is a duplicate record,
//! not an empty result.
//!
//! So a query is a set of terms every record must contain, `"a quoted phrase"`
//! is one term, and a one-word query behaves exactly as it always did. The
//! splitting and the intersection are pure and live in `doc_scaffold.zig`
//! where `zig build test` can run them; this module is only the guest-ABI half
//! (one host grep per term), which is why it is not in the pure-tool list.

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");

/// Hits for the records under `dir` that contain every term in `query`, as the
/// same `[{"file":...,"line":...,"text":...}]` array a single grep returns.
///
/// One host call per term, each parsed before the next is issued: a host
/// response lives in the shared host arena and the following call overwrites
/// it. `error.NotFound` still means the store directory is absent, which is a
/// normal fresh checkout.
///
/// Each grep is separately capped by the host's result limit, so a term that
/// hits the cap can hide a record a rarer term would have kept. That trade is
/// deliberate: the alternative is reading every record into the guest arena.
pub fn grepAll(dir: []const u8, query: []const u8) lib.FsError!std.json.Value {
    var term_buf: [doc.max_search_terms][]const u8 = undefined;
    const terms = doc.searchTerms(query, &term_buf);
    var per_term: [doc.max_search_terms]std.json.Value = undefined;
    for (terms, 0..) |term, i| {
        const raw = try lib.fsGrep(dir, term);
        per_term[i] = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch
            return error.IoError;
    }
    return doc.intersectHits(lib.alloc, per_term[0..terms.len]) catch return error.TooLarge;
}
