#!/bin/sh
# =============================================================================
# tests/ts/run-ts-tests.sh — the TypeScript suites, under the repo's convention
# =============================================================================
#   sh tests/ts/run-ts-tests.sh
#   QM_ROOT=/path/to/greenpacket-o5a-qmanager sh tests/ts/run-ts-tests.sh
#
# Everything under tests/ts/ tests QManager (TypeScript) code, so it runs with
# `bun test` FROM the QManager tree: that is where tsconfig's `@/*` alias and
# node_modules live, and neither resolves for a file that sits in this repo.
# This wrapper is the supported entry point — it finds the tree, runs bun, and
# turns bun's summary into the `PASS  N assertions` line every other suite in
# tests/ prints.
#
# Skipping is explicit and exits 0: a host with no bun, or without the QManager
# checkout beside this repo, has not failed the port — it just cannot run these
# rules, and says so instead of pretending.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
QM_ROOT="${QM_ROOT:-$(CDPATH= cd -- "$HERE/../../.." && pwd)/greenpacket-o5a-qmanager}"

skip_all() {
    printf '  SKIP %s\n' "$1"
    printf '       %s\n' "$2"
    printf 'SKIP  0 assertions (see the SKIP line above)\n'
    exit 0
}

command -v bun >/dev/null 2>&1 || skip_all \
    "bun is not installed" \
    "these suites run under bun (https://bun.sh); install it, then re-run sh tests/ts/run-ts-tests.sh"

[ -f "$QM_ROOT/types/modem-status.ts" ] || skip_all \
    "QManager source tree not found" \
    "expected $QM_ROOT/types/modem-status.ts — set QM_ROOT=/path/to/greenpacket-o5a-qmanager"
[ -f "$QM_ROOT/hooks/use-modem-status.ts" ] || skip_all \
    "QManager source tree is missing the status hook" \
    "expected $QM_ROOT/hooks/use-modem-status.ts — set QM_ROOT to a complete checkout"

DISTANCE="$HERE/distance.test.ts"
STALENESS="$HERE/staleness.test.ts"
PHONE="$HERE/phone.test.ts"
MASK="$HERE/mask.test.ts"
RNNOISE="$HERE/rnnoise.test.ts"
RING="$HERE/ring.test.ts"
for f in "$DISTANCE" "$STALENESS" "$PHONE" "$MASK" "$RING" "$RNNOISE"; do
    [ -f "$f" ] || skip_all "suite file missing" "expected $f"
done

OUT=$(mktemp "${TMPDIR:-/tmp}/qm-ts.XXXXXX") || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -f "$OUT"' EXIT HUP INT TERM

printf '\n### typescript: cell distance + freshness + contact matching + mask + ring + rnnoise (bun test)\n'
printf '  tree %s\n' "$QM_ROOT"
printf '  run  cd %s && bun test %s %s %s %s %s %s\n' "$QM_ROOT" "$DISTANCE" "$STALENESS" "$PHONE" "$MASK" "$RING" "$RNNOISE"

( cd "$QM_ROOT" && QM_ROOT="$QM_ROOT" NO_COLOR=1 bun test "$DISTANCE" "$STALENESS" "$PHONE" "$MASK" "$RING" "$RNNOISE" ) >"$OUT" 2>&1
RC=$?

# bun prints "(pass) <test>" / "(fail) <test>"; the repo prints "  ok   " / "  FAIL ".
sed -e 's/^(pass) /  ok   /' -e 's/^(fail) /  FAIL /' "$OUT"

# bun's summary: " 7 pass", " 0 fail", " 18 expect() calls".
count() { sed -n "s/^ *\([0-9][0-9]*\) $1.*/\1/p" "$OUT" | tail -n 1; }
ASSERTIONS=$(count 'expect() calls')
PASSED=$(count 'pass')
FAILED=$(count 'fail')
: "${ASSERTIONS:=0}" "${PASSED:=0}" "${FAILED:=0}"

echo
if [ "$RC" -eq 0 ]; then
    # One assertion is what the brief asks to count; bun counts matcher calls,
    # which is the same figure for these suites. Fall back to the test count if
    # bun ever stops printing it.
    [ "$ASSERTIONS" -gt 0 ] || ASSERTIONS=$PASSED
    printf 'PASS  %d assertions\n' "$ASSERTIONS"
    exit 0
fi

if [ "$FAILED" -eq 0 ]; then
    # bun died before summarising (a suite failed to load, or bun itself erred).
    printf 'FAIL  bun test exited %d before reporting a summary\n' "$RC"
    exit 1
fi
printf 'FAIL  %d passed, %d failed\n' "$PASSED" "$FAILED"
exit 1
