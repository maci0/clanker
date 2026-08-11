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
SRC_DIR="${TMPDIR:-/tmp}/clanker-grammars"
REPO_ZIG="https://github.com/tree-sitter-grammars/tree-sitter-zig.git"

lang="${1:-zig}"
[ "$lang" = "zig" ] || { printf 'error: only zig is supported so far\n' >&2; exit 1; }

command -v cc >/dev/null || { printf 'error: a C compiler is required\n' >&2; exit 1; }

mkdir -p "$OUT_DIR" "$SRC_DIR"
if [ -d "$SRC_DIR/tree-sitter-zig/.git" ]; then
  git -C "$SRC_DIR/tree-sitter-zig" pull --ff-only --quiet
else
  git clone --depth 1 --quiet "$REPO_ZIG" "$SRC_DIR/tree-sitter-zig"
fi

cd "$SRC_DIR/tree-sitter-zig"
# Some grammars ship an external scanner; zig currently does not, so it is
# compiled only when present rather than assumed either way.
srcs=(src/parser.c)
[ -f src/scanner.c ] && srcs+=(src/scanner.c)
cc -shared -fPIC -O2 -I src "${srcs[@]}" -o "$OUT_DIR/zig.so"

printf 'built %s\n' "$OUT_DIR/zig.so"
printf 'check it: ast-grep run --config sgconfig.yml -l zig -p "const \$A = @import(\$B);" src/main.zig\n'
