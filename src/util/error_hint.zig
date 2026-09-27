//! One table of "what a provider error means and what to do about it", shared
//! by the surfaces that render a failed turn.
//!
//! The same failure reaches a person three ways, and each used to carry its own
//! copy of the substring table: `cli.zig`'s `enrichRunError` (which serves
//! `clanker run` and the web UI's `POST /api/run`) and the REPL's
//! `errorRecoveryHint`. They had already drifted. The TUI half knew nothing
//! about a quota refusal, a `no such model`, or an unreachable endpoint, so
//! `clanker run` and `clanker repl` named different repairs for one 429, and a
//! fix applied to one table silently failed to reach the other.
//!
//! The diagnosis is therefore shared. Only the *next action* differs, and only
//! where the medium genuinely differs: the REPL has a `/model` picker one
//! keypress away and a person reading a scrollback line, while the CLI and the
//! web UI are handed a command they can copy. `Medium` makes that the only
//! thing a caller chooses, so a row cannot be added without deciding who says
//! it. Every arm is a literal, so the whole table is comptime and nothing here
//! allocates.

const std = @import("std");

/// Where the sentence is going to be read. Decides the action wording only.
pub const Medium = enum {
    /// A terminal the person types into (`clanker run`, and the web UI, whose
    /// error body is written for the same reader).
    cli,
    /// A scrollback line in the REPL, where a picker is already open-able.
    tui,
};

/// The failure classes a provider's own error text maps onto. `none` is the
/// honest "nothing here is worth guessing at" answer, not a catch-all failure.
pub const Kind = enum {
    /// Credential rejected, or absent.
    auth,
    /// The provider is shedding load.
    rate_limit,
    /// The endpoint answered, and refused the request itself.
    rejected,
    /// The model name does not exist on that provider.
    model_missing,
    /// The request ran past its budget.
    timeout,
    /// Nothing answered on the other end.
    unreachable_host,
    /// Nothing classifiable. An error string nobody can read a repair out of
    /// is better shown short than padded with a guess.
    none,

    /// Classifies a provider's own error string. Substring matching, because
    /// the text is whatever the endpoint said, and the order is the priority
    /// order: a 401 body that also contains "not found" is an auth problem.
    pub fn classify(detail: []const u8) Kind {
        const find = std.ascii.findIgnoreCase;
        if (find(detail, "401") != null or
            find(detail, "unauthorized") != null or
            find(detail, "invalid_api_key") != null or
            find(detail, "authentication") != null) return .auth;
        if (find(detail, "429") != null or
            find(detail, "rate limit") != null or
            find(detail, "rate_limit") != null or
            find(detail, "too many requests") != null or
            find(detail, "quota") != null) return .rate_limit;
        if (find(detail, "http 400") != null or
            find(detail, "bad request") != null or
            find(detail, "invalid request") != null) return .rejected;
        if (find(detail, "model_not_found") != null or
            find(detail, "no such model") != null or
            find(detail, "does not exist") != null or
            find(detail, "not found") != null) return .model_missing;
        if (find(detail, "timeout") != null or
            find(detail, "timed out") != null or
            find(detail, "deadline") != null) return .timeout;
        if (find(detail, "onnection refused") != null or
            find(detail, "onnection reset") != null or
            find(detail, "unreachable") != null) return .unreachable_host;
        return .none;
    }
};

/// The sentence to append to an error line, already wrapped the way the
/// surface it is read on delimits asides: a semicolon after the CLI's provider
/// text, parentheses inside the REPL's. Empty for `.none`, so a caller can
/// concatenate unconditionally.
pub fn suffix(kind: Kind, medium: Medium) []const u8 {
    return switch (kind) {
        .auth => switch (medium) {
            .cli => "; check that the API key is set and valid (`clanker doctor`)",
            .tui => " (check the API key, or run `clanker doctor`)",
        },
        .rate_limit => switch (medium) {
            .cli => "; rate limited, wait a moment or switch model (`clanker providers models`)",
            .tui => " (rate limited; wait a moment, or /model to switch)",
        },
        .rejected => switch (medium) {
            .cli => "; provider rejected the request; the model name may be wrong for this provider (try `clanker providers models`), or the request body is invalid",
            .tui => " (provider rejected the request; the model may not exist here, or the request body is invalid; /model to switch)",
        },
        .model_missing => switch (medium) {
            .cli => "; the model may not exist on this provider; try `clanker providers models`",
            .tui => " (model not found; /model to pick another)",
        },
        .timeout => switch (medium) {
            .cli => "; the request timed out; the provider may be slow or unreachable, check it with `clanker providers check`",
            .tui => " (the request timed out; the provider may be slow or unreachable; `clanker providers check` measures it)",
        },
        .unreachable_host => switch (medium) {
            .cli => "; cannot reach the provider; check the network and base_url in config, or measure it with `clanker providers check`",
            .tui => " (cannot reach the provider; check the network and base_url in config; `clanker providers check` measures it)",
        },
        .none => "",
    };
}

test "one 429 classifies the same for every surface" {
    for ([_][]const u8{
        "HTTP 429: too many requests",
        "rate_limit exceeded",
        "Error: rate limit reached for gpt-4",
        "quota exhausted for this key",
    }) |detail| {
        try std.testing.expectEqual(Kind.rate_limit, Kind.classify(detail));
    }
}

test "a credential failure outranks a model name in the same body" {
    // The endpoint's own text can hold both; the credential is the one to fix.
    try std.testing.expectEqual(Kind.auth, Kind.classify("HTTP 401: invalid_api_key (model not found)"));
    try std.testing.expectEqual(Kind.auth, Kind.classify("Unauthorized"));
    try std.testing.expectEqual(Kind.auth, Kind.classify("authentication failed"));
}

test "model_missing matches the phrasings providers actually return" {
    try std.testing.expectEqual(Kind.model_missing, Kind.classify("HTTP 404: model_not_found"));
    try std.testing.expectEqual(Kind.model_missing, Kind.classify("The model `gpt-9` does not exist"));
    try std.testing.expectEqual(Kind.model_missing, Kind.classify("no such model: gpt-9"));
    try std.testing.expectEqual(Kind.model_missing, Kind.classify("model not found"));
}

test "transport failures are told apart from endpoint failures" {
    try std.testing.expectEqual(Kind.unreachable_host, Kind.classify("Connection refused"));
    try std.testing.expectEqual(Kind.unreachable_host, Kind.classify("connection reset by peer"));
    try std.testing.expectEqual(Kind.unreachable_host, Kind.classify("host unreachable"));
    try std.testing.expectEqual(Kind.timeout, Kind.classify("read: timeout"));
    try std.testing.expectEqual(Kind.rejected, Kind.classify("HTTP 400: bad request"));
}

test "an unclassifiable error says nothing rather than guessing" {
    try std.testing.expectEqual(Kind.none, Kind.classify("something went sideways"));
    try std.testing.expectEqualStrings("", suffix(.none, .cli));
    try std.testing.expectEqualStrings("", suffix(.none, .tui));
}

test "every class carries a next action, and the CLI's is a runnable command" {
    for (std.enums.values(Kind)) |kind| {
        const cli = suffix(kind, .cli);
        const tui = suffix(kind, .tui);
        if (kind == .none) {
            try std.testing.expectEqualStrings("", cli);
            try std.testing.expectEqualStrings("", tui);
            continue;
        }
        try std.testing.expect(cli.len > 0);
        try std.testing.expect(tui.len > 0);
        // Each medium's reader is handed something that medium can act on: a
        // command to copy, or a picker keypress away.
        try std.testing.expect(std.mem.indexOf(u8, cli, "clanker ") != null);
        try std.testing.expect(std.mem.startsWith(u8, tui, " ("));
    }
}

test "the same error reaches all three surfaces naming the same repair" {
    // The cross-surface property the table exists for: `clanker run` and the
    // web UI (`.cli`) and the REPL (`.tui`) classify one string identically, so
    // the wording difference is the medium's alone, not a second opinion.
    const detail = "HTTP 429: rate limit reached";
    const kind = Kind.classify(detail);
    try std.testing.expectEqualStrings(suffix(Kind.rate_limit, .cli), suffix(kind, .cli));
    try std.testing.expectEqualStrings(suffix(Kind.rate_limit, .tui), suffix(kind, .tui));
}
