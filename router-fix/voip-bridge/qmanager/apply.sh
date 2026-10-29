#!/bin/sh
# =============================================================================
# apply.sh — put the Calls feature's QManager source into a QManager tree
# =============================================================================
# Why this exists: the QManager app-layer half of this module (the Calls page, the
# dashboard card, the shared hook, and the locale/nav edits) is source, not a
# payload file, and the tree it was written in is not a git repository. Keeping it
# here means a fresh QM_SRC can be brought back to the built-and-verified state
# instead of losing the feature to a wiped /tmp.
#
# AGENTS.md §7 asks for device and QManager changes to be committed "in both
# repos, same scope". This directory is the QManager side of that: the same 31
# files, byte for byte, with the hashes to prove it.
#
# What it does NOT do: build or deploy. After applying, build the export and push
# it the way docs/27-call-terminal.md §5 describes.
#
# Usage:
#   ./apply.sh              # copy the overlay into $QM_SRC (default /tmp/qm)
#   ./apply.sh --check      # verify every overlay file is in place, change nothing
#   ./apply.sh --list       # what the overlay contains
#
# Environment:
#   QM_SRC   the QManager source tree (default: /tmp/qm)
# =============================================================================
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OVERLAY="$HERE/overlay"
MANIFEST="$HERE/MANIFEST.sha256"
QM_SRC="${QM_SRC:-/tmp/qm}"

MANIFEST_VERSION=v0.1.18-draft

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $* =="; }

[ -d "$OVERLAY" ] || die "missing $OVERLAY"
[ -f "$MANIFEST" ] || die "missing $MANIFEST"

files=$(cd "$OVERLAY" && find . -type f | sed 's|^\./||' | sort)
count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')

case "${1:-}" in
  --list)
    printf '%s\n' "$files"
    echo "-- $count files (overlay built against QManager $MANIFEST_VERSION)"
    exit 0
    ;;
  --check)
    [ -f "$QM_SRC/package.json" ] || die "$QM_SRC is not a QManager tree (no package.json)"
    bad=0
    for f in $files; do
      if [ ! -f "$QM_SRC/$f" ]; then
        echo "  missing: $f"
        bad=$((bad + 1))
      elif ! cmp -s "$OVERLAY/$f" "$QM_SRC/$f"; then
        echo "  differs: $f"
        bad=$((bad + 1))
      fi
    done
    if [ "$bad" -ne 0 ]; then
      echo "FAIL: $bad/$count overlay file(s) not in place in $QM_SRC" >&2
      exit 1
    fi
    echo "OK: all $count overlay files are in place in $QM_SRC"
    exit 0
    ;;
  ""|--apply) : ;;
  *) die "usage: $0 [--apply|--check|--list]" ;;
esac

say "target"
[ -f "$QM_SRC/package.json" ] || die "$QM_SRC is not a QManager tree (no package.json) — set QM_SRC=..."
grep -q "\"version\": \"$MANIFEST_VERSION\"" "$QM_SRC/package.json" \
  || echo "   WARNING: $QM_SRC is not $MANIFEST_VERSION — the overlay replaces whole
   files, so re-run 'bun run build' and check the diff before deploying"
echo "   $QM_SRC ($(grep -m1 '"version"' "$QM_SRC/package.json" | sed 's/.*: "//;s/",*//'))"

say "applying $count files"
for f in $files; do
  mkdir -p "$QM_SRC/$(dirname "$f")"
  cp -f "$OVERLAY/$f" "$QM_SRC/$f"
done

say "verifying"
"$HERE/apply.sh" --check || die "post-apply check failed"

cat <<TXT

Next:
  ( cd $QM_SRC && bunx tsc --noEmit && bun run build )     # typecheck + static export
  tar czf - -C $QM_SRC/out . | ssh zlt-x16-root 'tar xzf - -C /data/qmanager/www'
  # then open https://192.168.3.1:8444/cellular/calls/
TXT
