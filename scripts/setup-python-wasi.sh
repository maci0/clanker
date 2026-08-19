#!/usr/bin/env bash
# Fetches the WASI-sandboxed CPython interpreter the `kernel` tool uses
# (agent.kernel in config.toml). Not run by `zig build`: this pulls ~25 MB
# over the network, and not every checkout uses the kernel tool. Run once:
#     ./scripts/setup-python-wasi.sh
#
# Idempotent: skips the download if the pinned version is already present
# and its checksum matches.
set -euo pipefail

release_tag='python/3.12.0+20231211-040d5a6'
archive='python-3.12.0-wasi-sdk-20.0.tar.gz'
sha256='6c1cddbb69ae09e87eee2906bdc70539bff5f2969818a6f8457d4e6a6eb67d4d'
url="https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/${release_tag//+/%2B}/${archive}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest="${repo_root}/vendor/python-wasi"
wasm_binary="${dest}/bin/python-3.12.0.wasm"

# sha256sum is GNU coreutils; macOS ships the Perl Digest::SHA shasum instead,
# with the same --check/--status interface and <hash>  <file> input format, so
# pick whichever exists rather than requiring the GNU tool on a macOS checkout.
if command -v sha256sum >/dev/null 2>&1; then
    check_cmd=(sha256sum --check --status)
elif command -v shasum >/dev/null 2>&1; then
    check_cmd=(shasum -a 256 --check --status)
else
    echo "setup-python-wasi: sha256sum (Linux) or shasum (macOS) is required" >&2
    exit 1
fi

verify() {
    printf '%s  %s\n' "$sha256" "$1" | "${check_cmd[@]}"
}

if [ -f "$wasm_binary" ]; then
    echo "already present: $wasm_binary"
    exit 0
fi

command -v tar >/dev/null || { echo "setup-python-wasi: tar is required" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "fetching $archive ..."
curl -fsSL -o "$work/$archive" "$url"

echo "verifying checksum ..."
if ! verify "$work/$archive"; then
    echo "setup-python-wasi: checksum mismatch for $archive" >&2
    exit 1
fi

mkdir -p "$dest"
tar xzf "$work/$archive" -C "$dest"

echo "installed: $wasm_binary"
echo "set [kernel] enabled = true in config.local.toml to use it"
