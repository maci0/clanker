Vendored from [sam701/zig-toml](https://github.com/sam701/zig-toml) at commit
`c661327bd9f02f774426c4fe78f60621411b7173` (v0.3.0), MIT licensed (see
`LICENSE`).

Vendored instead of fetched via `build.zig.zon` because `zig fetch` has no
way to carry a local patch forward: `src/struct_mapping.zig`'s enum-from-string
decoding used `@fromBackingInt`, a builtin Zig 0.16 no longer has. Patched to
`@enumFromInt` (the current builtin for the same "construct an enum value
from its backing integer" operation) — the only change from upstream.

To pick up a newer upstream release: re-fetch the commit, diff it against
this directory to find anything else that needs the same treatment, and
re-apply the `@enumFromInt` patch if `struct_mapping.zig` still needs it.

`examples/`, the build tooling for building `zig-toml` standalone
(`build.zig`, `build.zig.zon`, `flake.nix`, `gyro.zzz`, `zigmod.yml`), and CI
config are dropped — clanker imports `src/root.zig` directly as a local
module (see `build.zig`), so none of that applies here.
