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
# Master tip that the 0.17-dev patch applies against (not crates.io 1.1.2).
# Full SHA required: short form is not a fetchable remote ref.
REF_ZIG="6479aa13f32f701c383083d8b28360ebd682fb7d"
PATCH="$OUT_DIR/0001-zig-0.17-dev-support.patch"

lang="${1:-zig}"
[ "$lang" = "zig" ] || { printf 'error: only zig is supported so far\n' >&2; exit 1; }

command -v cc >/dev/null || { printf 'error: a C compiler is required\n' >&2; exit 1; }

mkdir -p "$OUT_DIR" "$SRC_DIR"
if [ ! -d "$SRC_DIR/tree-sitter-zig/.git" ]; then
  git clone --quiet "$REPO_ZIG" "$SRC_DIR/tree-sitter-zig"
fi
git -C "$SRC_DIR/tree-sitter-zig" fetch --quiet origin
git -C "$SRC_DIR/tree-sitter-zig" checkout --quiet --detach "$REF_ZIG"
git -C "$SRC_DIR/tree-sitter-zig" reset --quiet --hard "$REF_ZIG"
git -C "$SRC_DIR/tree-sitter-zig" clean -fdq

cd "$SRC_DIR/tree-sitter-zig"
if [ -f "$PATCH" ]; then
  git apply --check "$PATCH"
  git apply "$PATCH"
fi

if command -v tree-sitter >/dev/null; then
  tree-sitter generate
elif [ -x /tmp/tree-sitter ]; then
  /tmp/tree-sitter generate
else
  printf 'error: tree-sitter CLI required to regenerate after patch\n' >&2
  exit 1
fi

srcs=(src/parser.c)
[ -f src/scanner.c ] && srcs+=(src/scanner.c)
cc -shared -fPIC -O2 -I src "${srcs[@]}" -o "$OUT_DIR/zig.so"

printf 'built %s\n' "$OUT_DIR/zig.so"
# shellcheck disable=SC2016
printf 'check it: ast-grep run --config sgconfig.yml -l zig -p "const \$A = @import(\$B);" src/main.zig\n'
