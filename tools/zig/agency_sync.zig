//! agency_sync: mirrors persona files from github.com/msitarzewski/
//! agency-agents into agency/<division>/<file>.md, verbatim, plus an
//! agency/index.json summary (division, file, name, description per
//! persona) a future picker can browse without reading every file.
//!
//! These are not clanker skills and are never injected into the system
//! prompt: agency-agents ships ~150 personas across 17 divisions, and
//! auto-loading any of that as always-on context would bloat every turn.
//! This tool only mirrors the corpus locally; something else (a dedicated
//! picker tool, not this one) reads it and chooses.
//!
//! Input:  {} (every division) or {"division": "engineering"} (just one)
//! Output: {"ok": true, "synced": N, "divisions": M, "errors": [...]}
//!
//! HTTP-heavy by nature (one listing fetch per division, one raw fetch per
//! file): syncing everything is dozens of round trips and can take a
//! while. Scope to one division with the "division" input for a fast,
//! repeatable check.

const std = @import("std");
const lib = @import("lib.zig");
const skills_logic = @import("skills_logic.zig");
const agency = @import("agency_sync_logic.zig");

const repo = "msitarzewski/agency-agents";
const raw_base = "https://raw.githubusercontent.com/" ++ repo ++ "/main/";
const api_base = "https://api.github.com/repos/" ++ repo ++ "/contents/";
const gh_headers = "{\"User-Agent\":\"clanker-agency-sync\",\"Accept\":\"application/vnd.github+json\"}";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const arena = lib.alloc;
    var only_division: []const u8 = "";
    if (input.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch null;
        if (parsed) |v| {
            if (v == .object) {
                if (v.object.get("division")) |d| {
                    if (d == .string) only_division = d.string;
                }
            }
        }
    }

    var divisions: []const []const u8 = &.{};
    if (only_division.len > 0) {
        divisions = &.{only_division};
    } else {
        const divisions_url = raw_base ++ "divisions.json";
        const divisions_json = lib.httpGet(divisions_url) catch |err|
            return lib.failErr(out, err, "fetching agency-agents divisions.json");
        divisions = agency.divisionNames(arena, divisions_json) catch &.{};
        if (divisions.len == 0) return lib.fail(out, "divisions.json listed no divisions");
    }

    var synced: usize = 0;
    var errors: std.ArrayList([]const u8) = .empty;
    var index_entries: std.ArrayList(agency.IndexEntry) = .empty;
    for (divisions) |division| {
        const listing_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ api_base, division });
        const listing_json = lib.httpGetHdr(listing_url, gh_headers) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: listing failed ({s})", .{ division, @errorName(err) }));
            continue;
        };
        const files = agency.mdFileNames(arena, listing_json) catch &.{};
        for (files) |file| {
            const raw_url = try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ raw_base, division, file });
            const raw = lib.httpGet(raw_url) catch |err| {
                try errors.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}: fetch failed ({s})", .{ division, file, @errorName(err) }));
                continue;
            };
            const fm = skills_logic.splitFrontmatter(raw);
            const name = agency.extractName(raw);
            const dest = try std.fmt.allocPrint(arena, "agency/{s}/{s}", .{ division, file });
            lib.fsWrite(dest, raw) catch |err| {
                try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: write failed ({s})", .{ dest, @errorName(err) }));
                continue;
            };
            try index_entries.append(arena, .{
                .division = division,
                .path = dest,
                .name = if (name.len > 0) name else skills_logic.stemOf(file),
                .description = fm.description,
            });
            synced += 1;
        }
    }

    if (index_entries.items.len > 0) {
        // Merge onto the existing catalog: a scoped {"division": "..."} sync
        // must replace only that division's slice, not wipe out every other
        // division a prior sync already wrote.
        const prior_raw = lib.fsRead("agency/index.json") catch "";
        const prior = agency.parseIndex(arena, prior_raw);
        const kept = agency.dropDivisions(arena, prior, divisions);
        var merged: std.ArrayList(agency.IndexEntry) = .empty;
        try merged.appendSlice(arena, kept);
        try merged.appendSlice(arena, index_entries.items);
        const index_json = try agency.buildIndex(arena, merged.items);
        lib.fsWrite("agency/index.json", index_json) catch |err|
            try errors.append(arena, try std.fmt.allocPrint(arena, "agency/index.json: write failed ({s})", .{@errorName(err)}));
    }

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("synced");
    try s.write(synced);
    try s.objectField("divisions");
    try s.write(divisions.len);
    try s.objectField("errors");
    try s.beginArray();
    for (errors.items) |e| try s.write(e);
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}
