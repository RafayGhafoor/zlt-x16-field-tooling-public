#!/bin/sh
# =============================================================================
# lib_atcli.sh — shared harness for the shim test suites
# =============================================================================
# Split out of unit_atcli_smd11.sh so the suites can run in parallel: it had
# become the critical path of the commit gate (~4.7 s) purely by ACCUMULATION,
# and its sections were already independent. Two files now run side by side.
#
# Sourced, never executed. Defines: run(), assert_eq/contains/not_contains,
# qeng_field/qeng_line_field/qeng_lines, want(), the counters.
#
#   sh tests/unit_atcli_dialect.sh    # transport, QENG, CA, capability, identity
#   sh tests/unit_atcli_policy.sh     # compound chains, CPSI cache, safety, perf
#
# Both accept a filter argument, e.g. `sh tests/unit_atcli_dialect.sh qeng`.
#
# Every test asserts on the EXACT field positions the QManager parsers read
# (parse_at.sh:392-402 for +QENG, parse_at.sh:803+ for +QCAINFO). A translation
# that is merely "close" is a bug: the awk parsers index by position. The modem
# is replaced by tests/fake-atcmd, whose responses are copied verbatim from a
# real capture (docs/captures/at-capture-2026-10-26.txt), so the suites run
# anywhere with no device.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHIM="$HERE/../deploy-x16/atcli_smd11"
FAKE="$HERE/fake-atcmd"
FILTER="${1:-}"

command -v "$SHIM" >/dev/null 2>&1 || true
[ -f "$SHIM" ] || { echo "FATAL: shim not found at $SHIM" >&2; exit 1; }
[ -x "$FAKE" ] || chmod +x "$FAKE" 2>/dev/null

PASS=0
FAIL=0
FAILED_NAMES=""

# --- tiny assertion helpers -------------------------------------------------
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  - $1
    $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# run the shim with the fake modem; extra env comes from the caller.
# Each call gets a fresh +CPSI cache AND a fresh snapshot-cache directory: the
# shim caches read-only answers for a couple of seconds in production (that is
# the point), so an un-isolated cache would let one assertion's modem answer
# stand in for the next one's — every suite runs in the same /tmp.
run() {
    _c="/tmp/qmtest-cpsi.$$.cache"
    _d="/tmp/qmtest-atcache.$$"
    rm -f "$_c"
    rm -rf "$_d"
    QM_CPSI_CACHE="${QM_CPSI_CACHE:-$_c}" QM_AT_CACHE_DIR="$_d" \
        ATC="$FAKE" sh "$SHIM" "$1"
    _rc=$?
    rm -f "$_c"
    rm -rf "$_d"
    return $_rc
}

# assert_eq <name> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "expected to contain [$2] in [$3]" ;;
    esac
}

# assert_not_contains <name> <needle> <haystack>
assert_not_contains() {
    case "$3" in
        *"$2"*) bad "$1" "should NOT contain [$2] in [$3]" ;;
        *) ok "$1" ;;
    esac
}

# QENG field extractor: field N of the first +QENG line (1-based, comma split)
qeng_field() {
    # strip the "+QENG: " prefix first so field 1 is the token "servingcell"
    printf '%s\n' "$1" | grep '^+QENG:' | head -1 \
        | sed 's/^+QENG: //' \
        | awk -F',' -v n="$2" '{gsub(/^[ \t]+|[ \t\r]+$/,"",$n); print $n}'
}

# qeng_line_field <output> <line-index (1-based)> <field (1-based)>
# The EN-DC layout is three +QENG: lines, so an assertion needs both indexes.
qeng_line_field() {
    printf '%s\n' "$1" | grep '^+QENG:' | sed -n "$2p" \
        | sed 's/^+QENG: //' \
        | awk -F',' -v n="$3" '{gsub(/^[ \t]+|[ \t\r]+$/,"",$n); print $n}'
}

# count of +QENG: lines in an output
qeng_lines() {
    printf '%s\n' "$1" | grep -c '^+QENG:'
}

want() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

# ===========================================================================