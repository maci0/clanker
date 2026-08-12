# Release and compatibility policy

clanker currently has no published releases. Development happens at the version
declared in `build.zig.zon`; that value alone does not make a release. A version
is published only when an immutable `vMAJOR.MINOR.PATCH` Git tag and a matching
dated `CHANGELOG.md` section exist for the same commit.

`build.zig.zon` is the single source of truth for the program version. The build
passes it to `clanker --version`, HTTP agent cards, MCP server metadata, and HTTP
user agents. The build rejects values that are not valid Semantic Versioning.

## Compatibility contract

clanker uses Semantic Versioning with the following explicit pre-1.0 policy:

- `0.MINOR.0` may make breaking changes. Release notes must label each break and
  give a concrete migration, including before/after config or command examples.
- `0.MINOR.PATCH` is backward compatible and contains fixes only. New
  consumer-visible capabilities wait for the next minor release.
- From `1.0.0`, incompatible public changes require a major release, compatible
  features require a minor release, and compatible fixes require a patch.
- Pre-release identifiers such as `-rc.1` are for testing the exact prospective
  release. Build metadata does not encode compatibility or replace a version
  bump.

The public contract includes more than Zig declarations: documented CLI commands
and flags; exit behavior and stdout/stderr formats; configuration keys and
defaults; HTTP, MCP, A2A, peer, and WASM host/guest protocols; tool names and
descriptor schemas; and persisted files under `state/`. A signature-preserving
change to results, errors, defaults, side effects, wire data, or persisted data
can therefore be breaking.

Anything described as experimental or internal in documentation or a tool
descriptor is outside the stable API. An underscore, source-file location, or
absence from the README does not by itself make a reachable surface private.

## Deprecation and migration

A stable surface is deprecated before removal. The deprecation must name its
replacement, emit a useful runtime or compile-time warning where practical, and
remain available through at least the next minor release. Documentation and
examples switch to the replacement immediately. Removal is listed under
`Removed` and `Breaking` in the changelog with a migration example.

Readers for config and persisted state must accept data written by the previous
minor release unless the new release is explicitly breaking. New required fields
need a default or a transition period. A release that changes an on-disk format
must migrate it automatically or document backup, migration, and rollback steps.

## Release gate

Before creating a tag:

1. Review changes since the previous tag across every public surface above.
2. Move relevant `Unreleased` entries into a dated version section, grouped as
   `Breaking`, `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and
   `Security`. Give users outcomes and migrations rather than commit summaries.
3. Choose the SemVer bump from compatibility impact, then update
   `build.zig.zon`. The changelog heading and intended tag must match it exactly.
4. Run `zig build`, `zig build test`, `zig build tools`, and the end-to-end tests.
   Smoke-test the packaged release binary and its `--version` output, not only a
   checkout build.
5. Run `./release-check.sh vMAJOR.MINOR.PATCH zig-out/bin/clanker`. CI repeats
   this check for every version tag and rejects a tag, changelog, manifest, or
   binary version mismatch.
6. Create release notes from the changelog and create the immutable version tag.
   Never move a published tag or replace an artifact for an existing version;
   publish a new patch release instead.

No version is currently supported and there is no security-backport branch.
That changes only when a published release names its support window here. Until
then, fixes are made on the development branch only.
