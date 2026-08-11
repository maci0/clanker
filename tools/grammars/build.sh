#!/usr/bin/env bash
# Build the tree-sitter grammars ast-grep needs for languages it does not ship.
#
# ast-grep has no Zig parser, so structural search over this project's own
# source is impossible without one. This compiles tree-sitter-zig into a shared
# library and drops it where sgconfig.yml expects it. The .so is a build
# artifact: it is not committed, and this script is how you get it back.
#
# Usage: tools/grammars/build.sh [zig]
set -euo pipefail

OUT_DIR="${CLANKER_GRAMMAR_DIR:-$(cd "$(dirname "$0")" && pwd)}"
SRC_DIR="${CLANKER_GRAMMAR_SRC_DIR:-$HOME/.cache/clanker-grammars}"
REPO_ZIG="https://github.com/tree-sitter-grammars/tree-sitter-zig.git"
# Pinned commit (tag v1.1.2), not a branch: a floating clone would fetch
# different source on every run with no way to tell the versions apart.
REF_ZIG="b670c8df85a1568f498aa5c8cae42f51a90473c0"

lang="${1:-zig}"
[ "$lang" = "zig" ] || { printf 'error: only zig is supported so far\n' >&2; exit 1; }

command -v cc >/dev/null || { printf 'error: a C compiler is required\n' >&2; exit 1; }

mkdir -p "$OUT_DIR" "$SRC_DIR"
if [ ! -d "$SRC_DIR/tree-sitter-zig/.git" ]; then
  git clone --quiet "$REPO_ZIG" "$SRC_DIR/tree-sitter-zig"
fi
git -C "$SRC_DIR/tree-sitter-zig" fetch --quiet origin "$REF_ZIG"
git -C "$SRC_DIR/tree-sitter-zig" checkout --quiet --detach "$REF_ZIG"

cd "$SRC_DIR/tree-sitter-zig"
# Some grammars ship an external scanner; zig currently does not, so it is
# compiled only when present rather than assumed either way.
srcs=(src/parser.c)
[ -f src/scanner.c ] && srcs+=(src/scanner.c)
cc -shared -fPIC -O2 -I src "${srcs[@]}" -o "$OUT_DIR/zig.so"

printf 'built %s\n' "$OUT_DIR/zig.so"
printf 'check it: ast-grep run --config sgconfig.yml -l zig -p "const \$A = @import(\$B);" src/main.zig\n'
