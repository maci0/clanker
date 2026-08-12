#!/usr/bin/env bash
# clanker-merge-worktree.sh — land a branch into another at the ref level,
# without checking out or touching any working tree on either side.
#
# This is the pattern src/improve/worktree.zig's mergeBack implements
# natively for the self-improve loop; this script is the same pattern for
# everything else — a scratch dev worktree, a fix branch, anything cut with
# `git worktree add` that needs to land in main (or another branch) without
# disturbing whatever files anyone else has open there.
#
# Usage:
#   ./clanker-merge-worktree.sh <branch> [options]
#
# Options:
#   --base <branch>     branch to merge into (default: current branch)
#   --message <text>    merge commit message when a real merge is needed
#                        (default: "Merge <branch>: <its top commit subject>")
#   --resync            after landing, reset <branch> itself to the commit
#                        that landed, so a worktree still checked out on it
#                        stays in lockstep and future merges from it stay
#                        small instead of re-diverging (see worktree.zig's
#                        own comment on why this matters — skipping it is
#                        exactly the bug that once orphaned 23 promotions)
#   --remove-worktree <path>   remove the worktree at <path> after landing
#                        (implies the branch is no longer needed as a
#                        distinct ref there; still requires --resync or a
#                        clean fast-forward to be safe to remove)
#   --keep-branch        don't delete <branch> after a successful, fully
#                        landed merge (default: delete it, since its content
#                        now lives on <base>)
#   -n, --dry-run        show what would happen, change nothing
#   -h, --help           this text
#
# Exit status:
#   0   landed (fast-forward or a clean 3-way merge)
#   1   usage error
#   2   lost the compare-and-swap race after 3 attempts (retry the script)
#   3   a real conflict — nothing was touched; resolve by hand (see below)
#
# On a real conflict, this prints the conflicting paths and exits without
# guessing at a resolution. To resolve: `git worktree add <tmp> <base>`,
# `git -C <tmp> merge --no-commit --no-ff <branch>`, fix the conflicts,
# `git -C <tmp> commit`, then re-run this script with that commit as the
# branch — or just merge that commit onto <base> the same way this script
# does its own fast-forward/CAS step.

set -euo pipefail
cd "$(dirname "$0")"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^$/!d; s/^# \?//p' "$0"; }

BASE=""
MESSAGE=""
RESYNC=0
REMOVE_WORKTREE=""
KEEP_BRANCH=0
DRY_RUN=0
BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    --resync) RESYNC=1; shift ;;
    --remove-worktree) REMOVE_WORKTREE="$2"; shift 2 ;;
    --keep-branch) KEEP_BRANCH=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [ -z "$BRANCH" ] || die "unexpected extra argument: $1"
      BRANCH="$1"; shift ;;
  esac
done

[ -n "$BRANCH" ] || { usage; exit 1; }
git rev-parse --verify --quiet "$BRANCH" >/dev/null || die "not a valid ref: $BRANCH"

if [ -z "$BASE" ]; then
  BASE="$(git symbolic-ref --short HEAD 2>/dev/null)" || die "detached HEAD and no --base given; say which branch to merge into"
fi
git rev-parse --verify --quiet "$BASE" >/dev/null || die "not a valid ref: $BASE"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

attempt=0
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  base_sha="$(git rev-parse "$BASE")"
  branch_sha="$(git rev-parse "$BRANCH")"

  if [ "$base_sha" = "$branch_sha" ]; then
    info "$BASE already equals $BRANCH; nothing to merge"
    landed_sha="$base_sha"
    break
  fi

  merge_base="$(git merge-base "$base_sha" "$branch_sha")"

  if [ "$merge_base" = "$base_sha" ]; then
    info "fast-forwarding $BASE to $branch_sha"
    if [ "$DRY_RUN" -eq 1 ]; then
      landed_sha="$branch_sha"; break
    fi
    if git update-ref "refs/heads/$BASE" "$branch_sha" "$base_sha"; then
      landed_sha="$branch_sha"
      break
    fi
    warn "$BASE moved during the fast-forward attempt; retrying (attempt $attempt/3)"
    continue
  fi

  info "computing a 3-way merge of $BRANCH into $BASE"
  if ! tree="$(git merge-tree --write-tree --no-messages "$base_sha" "$branch_sha" 2>&1)"; then
    warn "merging $BRANCH into $BASE conflicts; nothing was touched"
    printf '%s\n' "$tree" >&2
    printf '\nResolve by hand:\n' >&2
    printf '  git worktree add /tmp/merge-%s %s\n' "$BRANCH" "$BASE" >&2
    printf '  git -C /tmp/merge-%s merge --no-commit --no-ff %s\n' "$BRANCH" "$BRANCH" >&2
    printf '  # fix conflicts, git add, git commit\n' >&2
    printf '  ./clanker-merge-worktree.sh <that-commit> --base %s\n' "$BASE" >&2
    exit 3
  fi

  msg="${MESSAGE:-Merge $BRANCH: $(git log -1 --format=%s "$branch_sha")}"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would create a merge commit (tree $tree) and land it on $BASE"
    landed_sha="$tree"
    break
  fi
  commit="$(git commit-tree "$tree" -p "$base_sha" -p "$branch_sha" -m "$msg")"
  if git update-ref "refs/heads/$BASE" "$commit" "$base_sha"; then
    info "landed merge commit $commit on $BASE"
    landed_sha="$commit"
    break
  fi
  warn "$BASE moved during the merge attempt; retrying (attempt $attempt/3)"
done

if [ -z "${landed_sha:-}" ]; then
  warn "kept losing the race to land on $BASE after 3 attempts; nothing was touched, try again"
  exit 2
fi

if [ "$RESYNC" -eq 1 ] && [ "$branch_sha" != "$landed_sha" ]; then
  info "resyncing $BRANCH to the landed commit"
  # CAS, same as the land itself: $branch_sha is the value this script last
  # read for $BRANCH, so this only succeeds if nothing else moved it in the
  # meantime (a human still working on it, a second concurrent run of this
  # script) — a blind two-arg update-ref would silently overwrite whatever
  # they added.
  run git update-ref "refs/heads/$BRANCH" "$landed_sha" "$branch_sha" ||
    warn "$BRANCH moved since it landed; left it as-is rather than overwrite whatever moved it"
fi

if [ -n "$REMOVE_WORKTREE" ]; then
  # Cross-check before --force discards anyone's uncommitted work: only
  # remove a worktree that is actually checked out on $BRANCH, not just
  # whatever path was passed.
  wt_branch="$(git worktree list --porcelain | awk -v p="$REMOVE_WORKTREE" '
    $1=="worktree" { w=$2 } $1=="branch" && w==p { sub("refs/heads/", "", $2); print $2 }
  ')"
  if [ "$wt_branch" = "$BRANCH" ]; then
    info "removing worktree $REMOVE_WORKTREE"
    run git worktree remove --force "$REMOVE_WORKTREE"
  else
    warn "not removing $REMOVE_WORKTREE: it's checked out on '${wt_branch:-<none found>}', not $BRANCH — pass the right path or remove it yourself"
  fi
fi

if [ "$KEEP_BRANCH" -eq 0 ]; then
  info "deleting $BRANCH (its content now lives on $BASE)"
  run git branch -D "$BRANCH" || warn "could not delete $BRANCH (still checked out somewhere?)"
fi

info "done"
