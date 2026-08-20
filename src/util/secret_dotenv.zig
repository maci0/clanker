//! The one definition of which dotenv files are secret, shared by the two
//! surfaces that must agree on it:
//!
//! - the sandbox (`sandbox/host.zig` `safeJoin`) refuses dotenv names so a
//!   guest's `fs_prefixes` grant can never hand over the file that holds the
//!   process API keys (`env_allow` exists to keep those values out of guest
//!   memory; reading the file through `ck_fs_*` with `fs_prefixes ["."]`
//!   would be the same leak by another door), and
//! - the HTTP file browser (`cli.zig` `GET /api/files`) refuses the same
//!   names so a listing or preview cannot hand every configured key to
//!   whoever can reach the port.
//!
//! The rule operates on a single path component (a basename), so both callers
//! state it the same way: the browser checks each component of the requested
//! path, the sandbox checks each component of the sub_path. A name that
//! carries a `/` cannot match (`.envrc.example` and `.envrc.local` stay
//! servable on purpose: the rule is `.env`/`.envrc` exactly, or `.env.`
//! prefix).

const std = @import("std");

/// True when `name` (one path component, no `/`) is a dotenv file the sandbox
/// and the file browser must refuse: `.env`, `.envrc`, and every `.env.`
/// prefixed variant (`.env.local`, `.env.production`, ...).
pub fn isSecretDotenvName(name: []const u8) bool {
    if (std.mem.eql(u8, name, ".env") or std.mem.eql(u8, name, ".envrc")) return true;
    if (std.mem.startsWith(u8, name, ".env.")) return true;
    return false;
}

/// True when any component of `sub_path` (a `/`-separated relative path) is a
/// secret dotenv name. Equivalent to checking every component separately, so
/// a name is refused at any depth and in any position: `dir/.env`,
/// `.env/x`, `a/.env/b`, and `a/.envrc/b` all refuse.
pub fn isSecretDotenvPath(sub_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |c| {
        if (isSecretDotenvName(c)) return true;
    }
    return false;
}

// ----------------------------------------------------------------- tests --

const testing = std.testing;

test "isSecretDotenvName refuses every dotenv spelling the sandbox refuses" {
    try testing.expect(isSecretDotenvName(".env"));
    try testing.expect(isSecretDotenvName(".envrc"));
    try testing.expect(isSecretDotenvName(".env.local"));
    try testing.expect(isSecretDotenvName(".env.production"));
    // Ordinary dotfiles and real files stay servable. `.envrc.local` stays
    // servable too: the rule refuses only `.env`/`.envrc` exactly and
    // `.env.`-prefixed names, and parity with the sandbox is its point.
    try testing.expect(!isSecretDotenvName(".gitignore"));
    try testing.expect(!isSecretDotenvName(".envrc.example"));
    try testing.expect(!isSecretDotenvName(".envrc.local"));
    try testing.expect(!isSecretDotenvName("src/main.zig"));
    try testing.expect(!isSecretDotenvName("README.md"));
}

test "isSecretDotenvPath refuses a secret name at any depth and position" {
    // Exact and prefixed names at depth 0.
    try testing.expect(isSecretDotenvPath(".env"));
    try testing.expect(isSecretDotenvPath(".envrc"));
    try testing.expect(isSecretDotenvPath(".env.local"));
    // As a final component.
    try testing.expect(isSecretDotenvPath("dir/.env"));
    try testing.expect(isSecretDotenvPath("dir/sub/.envrc"));
    try testing.expect(isSecretDotenvPath("dir/.env.production"));
    // As a leading component with children, and mid-path. `.envrc` mid-path
    // is refused here too: the old full-path spellings checked `/.env/` and
    // `/.env.` but only `/.envrc` at the end, so a `dir/.envrc/x` grant
    // slipped past while its `.env` sibling was refused.
    try testing.expect(isSecretDotenvPath(".env/x"));
    try testing.expect(isSecretDotenvPath(".envrc/x"));
    try testing.expect(isSecretDotenvPath("a/.env/b"));
    try testing.expect(isSecretDotenvPath("a/.envrc/b"));
    // Absolute spellings the sandbox's absolute branch checks.
    try testing.expect(isSecretDotenvPath("/.env"));
    try testing.expect(isSecretDotenvPath("/a/.envrc"));
    // Non-secret neighbors stay servable.
    try testing.expect(!isSecretDotenvPath("a/.envrc.example"));
    try testing.expect(!isSecretDotenvPath("a/.envrc.local"));
    try testing.expect(!isSecretDotenvPath("a/.envy/b"));
    try testing.expect(!isSecretDotenvPath("a/.envrcs"));
    try testing.expect(!isSecretDotenvPath("a/README.md"));
    try testing.expect(!isSecretDotenvPath(""));
}
