//! gauntlet: cycles through review prompts from two sources -- this
//! project's own docs/prompts/*-review.md, and a local mirror of
//! github.com/maci0/gauntlet's prompts/*-review.md -- entirely inside
//! clanker's own agent loop, replacing that repo's own review-loop.py as
//! the driver. Nothing here shells out to Python, or to any AI CLI
//! besides clanker itself.
//!
//! Actions:
//!   sync              mirror gauntlet's prompts/*-review.md into
//!                     state/gauntlet/ (verbatim)
//!   list              the merged, sorted rotation: local + synced stems
//!   next              advance state/gauntlet_state.json to the next stem
//!                     in rotation and return its {name, source, prompt}
//!   current           the current stem and its prompt, without advancing
//!
//! `next`/`current` return the raw prompt text; running it is the caller's
//! job (a `clanker run` with that text as the instruction) -- this tool
//! only owns which review is next, not the run itself. Wire repetition
//! through `clanker schedule`, same as everything else: nothing here loops
//! on its own.

const std = @import("std");
const lib = @import("lib.zig");
const agency = @import("agency_sync_logic.zig");
const logic = @import("gauntlet_logic.zig");

const repo = "maci0/gauntlet";
// The prompts moved to src/gauntlet/prompts/ when the repo was reorganized
// into an installable Python package (pyproject.toml, src/, tests/) around
// the same time it was renamed from review-prompts.
const prompts_path = "src/gauntlet/prompts";
const raw_base = "https://raw.githubusercontent.com/" ++ repo ++ "/main/" ++ prompts_path ++ "/";
const api_base = "https://api.github.com/repos/" ++ repo ++ "/contents/" ++ prompts_path;
const gh_headers = "{\"User-Agent\":\"clanker-gauntlet\",\"Accept\":\"application/vnd.github+json\"}";

const local_dir = "docs/prompts";
const synced_dir = "state/gauntlet";
const state_path = "state/gauntlet_state.json";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const arena = lib.alloc;
    var action: []const u8 = "next";
    if (input.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch null;
        if (parsed) |v| {
            if (v == .object) {
                if (v.object.get("action")) |a| {
                    if (a == .string) action = a.string;
                }
            }
        }
    }

    if (std.mem.eql(u8, action, "sync")) return doSync(arena, out);
    if (std.mem.eql(u8, action, "list")) return doList(arena, out);
    if (std.mem.eql(u8, action, "current")) return doPick(arena, out, false);
    if (std.mem.eql(u8, action, "next")) return doPick(arena, out, true);
    return lib.fail(out, "action must be sync, list, next, or current");
}

fn doSync(arena: std.mem.Allocator, out: *lib.Out) !void {
    const listing_json = lib.httpGetHdr(api_base, gh_headers) catch |err|
        return lib.failErr(out, err, "listing gauntlet's prompts/ directory");
    const files = agency.mdFileNames(arena, listing_json) catch &.{};
    var synced: usize = 0;
    var errors: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        if (!std.mem.endsWith(u8, file, "-review.md")) continue;
        const raw_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ raw_base, file });
        const raw = lib.httpGet(raw_url) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: fetch failed ({s})", .{ file, @errorName(err) }));
            continue;
        };
        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ synced_dir, file });
        lib.fsWrite(dest, raw) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: write failed ({s})", .{ dest, @errorName(err) }));
            continue;
        };
        synced += 1;
    }
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("synced");
    try s.write(synced);
    try s.objectField("errors");
    try s.beginArray();
    for (errors.items) |e| try s.write(e);
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn rotation(arena: std.mem.Allocator) ![]const []const u8 {
    const local_json = lib.fsList(local_dir) catch "[]";
    const local_stems = logic.reviewStems(arena, local_json) catch &.{};
    const synced_json = lib.fsList(synced_dir) catch "[]";
    const synced_stems = logic.reviewStems(arena, synced_json) catch &.{};
    return logic.mergeStems(arena, local_stems, synced_stems);
}

/// Resolves `stem` to whichever source actually has it: local
/// docs/prompts/ takes precedence, since a project-specific review of the
/// same name is deliberately more relevant here than the generic one.
fn resolve(arena: std.mem.Allocator, stem: []const u8) !struct { path: []const u8, source: []const u8 } {
    const local_path = try std.fmt.allocPrint(arena, "{s}/{s}-review.md", .{ local_dir, stem });
    if (lib.fsRead(local_path)) |_| {
        return .{ .path = local_path, .source = "local" };
    } else |_| {}
    const synced_path = try std.fmt.allocPrint(arena, "{s}/{s}-review.md", .{ synced_dir, stem });
    return .{ .path = synced_path, .source = "synced" };
}

fn doList(arena: std.mem.Allocator, out: *lib.Out) !void {
    const names = try rotation(arena);
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("reviews");
    try s.beginArray();
    for (names) |n| try s.write(n);
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn doPick(arena: std.mem.Allocator, out: *lib.Out, advance: bool) !void {
    const names = try rotation(arena);
    if (names.len == 0) return lib.fail(out, "no reviews found in docs/prompts/ or the synced state/gauntlet/ -- run action:sync first, or add a *-review.md file");

    const state_raw = lib.fsRead(state_path) catch "";
    const state = logic.parseState(arena, state_raw);

    const stem = if (advance)
        logic.nextInRotation(names, state.last) orelse names[0]
    else if (state.last.len > 0 and blk: {
        for (names) |n| if (std.mem.eql(u8, n, state.last)) break :blk true;
        break :blk false;
    })
        state.last
    else
        names[0];

    const found = try resolve(arena, stem);
    const prompt = lib.fsRead(found.path) catch |err|
        return lib.failErr(out, err, "reading the resolved review prompt");

    if (advance) {
        const next_state = try logic.buildState(arena, stem);
        lib.fsWrite(state_path, next_state) catch |err|
            return lib.failErr(out, err, "saving gauntlet state");
    }

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("name");
    try s.write(stem);
    try s.objectField("source");
    try s.write(found.source);
    try s.objectField("path");
    try s.write(found.path);
    try s.objectField("prompt");
    try s.write(prompt);
    try s.endObject();
    lib.commit(out, &w);
}
