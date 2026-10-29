#!/bin/sh
# =============================================================================
# tests/unit_qcmd_peek.sh — does a snapshot-fresh read really skip the lock?
# =============================================================================
# This is the property the whole change exists for: `atcli_smd11 --peek` lets
# qcmd answer a read WITHOUT /tmp/qmanager_at.lock, because a peek never opens
# the modem and therefore cannot race /bin/atcmd's fixed reply socket.
#
# Measured on the X16 2026-11-05: the same cache-fresh AT+QENG="servingcell"
# costs 40 ms p50 with no lock and 980 ms p50 behind qmanager_poller's cycle
# (max 6.2 s), because flock() has no fairness and the poller re-acquires ~22
# times per cycle.
#
# HOW THIS IS OBSERVED WITHOUT flock(1): the assertion is on the shim's argv.
# qcmd is driven against a wrapper that records the first argument of every
# invocation, so "did it peek?" is answered by looking at what qcmd actually
# ran — which also lets the suite assert the FALLBACK (a cold cache must still
# reach the modem), and the version-skew discriminator (an old shim answering
# ERROR to --peek must be refused and retried under the lock).
# `flock` exists on the device but not on macOS, so nothing here depends on it.
# =============================================================================
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib_atcli.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/qmqcmd.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# A host without flock(1) (macOS) cannot exercise qcmd's locked branch at all:
# flock_wait would fail all 200 times and answer "modem_busy", so every fallback
# assertion would be testing the host, not qcmd. The lock itself is not what
# this suite is about (the device has flock; the peek path is what we are
# pinning), so provide a no-op that always acquires.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/flock"
chmod 755 "$WORK/bin/flock"
PATH="$WORK/bin:$PATH"; export PATH

# Prefer the QManager tree vendored in THIS repo (qmanager/, a git subtree), so
# the suite tests the tree a fresh clone actually deploys; fall back to the
# sibling checkout that predates the vendoring.
if [ -z "${QM_SRC:-}" ]; then
    if [ -f "$HERE/../qmanager/scripts/usr/bin/qcmd" ]; then
        QM_SRC="$HERE/../qmanager"
    else
        QM_SRC="$HERE/../../greenpacket-o5a-qmanager"
    fi
fi
QCMD_SRC="$QM_SRC/scripts/usr/bin/qcmd"

if [ ! -f "$QCMD_SRC" ]; then
    printf 'SKIP  qcmd source not found at %s (set QM_SRC)\n' "$QCMD_SRC"
    exit 0
fi

LOG="$WORK/argv.log"
WRAP="$WORK/atcli_wrap"
SKEW="$WORK/atcli_skew"

# wrapper: record the first argument, then behave like the shim
cat > "$WRAP" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$LOG"
exec "$SHIM" "\$@"
EOF
# skew wrapper: what an OLD shim does when handed --peek — treats it as a
# command, answers ERROR, exits 0. Everything else is answered normally.
cat > "$SKEW" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$LOG"
[ "\$1" = "--peek" ] && { printf 'ERROR\n'; exit 0; }
exec "$SHIM" "\$@"
EOF
chmod 755 "$WRAP" "$SKEW"

# qcmd with the three absolute paths this host cannot satisfy redirected.
# AT_DEVICE must exist or qcmd refuses to run at all (/dev/smd11 on the device).
make_qcmd() {
    sed -e "s|^AT_CLI=.*|AT_CLI=\"$1\"|" \
        -e 's|^AT_DEVICE=.*|AT_DEVICE="/dev/null"|' \
        -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$WORK/at.lock\"|" \
        "$QCMD_SRC" > "$2"
    chmod 755 "$2"
}

QCMD="$WORK/qcmd";  make_qcmd "$WRAP" "$QCMD"
QCMD_SKEW="$WORK/qcmd_skew"; make_qcmd "$SKEW" "$QCMD_SKEW"
sh -n "$QCMD" || { echo "FATAL: generated qcmd does not parse"; exit 1; }

# Every run gets its own snapshot cache so nothing leaks between assertions.
runq() {
    _bin=$1; _cmd=$2
    rm -rf "$WORK/cache"
    QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" QM_CPSI_CACHE="" \
        ATC="$FAKE" "$_bin" "$_cmd" 2>/dev/null
}
runq_warm() {
    _bin=$1; _cmd=$2
    # prime through the same code path, then clear the log
    QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" QM_CPSI_CACHE="" \
        ATC="$FAKE" "$_bin" "$_cmd" >/dev/null 2>&1
    : > "$LOG"
    QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" QM_CPSI_CACHE="" \
        ATC="$FAKE" "$_bin" "$_cmd" 2>/dev/null
}

echo "== a cold cache must still reach the modem (fallback intact) =="
: > "$LOG"
rm -rf "$WORK/cache"
out=$(QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" ATC="$FAKE" "$QCMD" 'AT+CGMM' 2>/dev/null)
assert_contains "cold cache: qcmd still answers"       'SIMCOM_SIM8260E' "$out"
assert_eq       "cold cache: it tried --peek first"    '--peek'          "$(head -1 "$LOG")"
assert_eq       "cold cache: then ran the real call"   'AT+CGMM'         "$(sed -n 2p "$LOG")"

echo "== a warm cache must NOT take the locked path =="
: > "$LOG"
out=$(runq_warm "$QCMD" 'AT+CGMM')
assert_contains "warm cache: answer served"            'SIMCOM_SIM8260E' "$out"
assert_eq       "warm cache: exactly one shim start"   '1'               "$(wc -l < "$LOG" | tr -d ' ')"
assert_eq       "  ... and it was the peek"            '--peek'          "$(head -1 "$LOG")"

echo "== QM_AT_NO_PEEK=1 must bypass the fast path =="
: > "$LOG"
runq_warm "$QCMD" 'AT+CGMM' >/dev/null
: > "$LOG"
out=$(QM_AT_NO_PEEK=1 QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" \
      ATC="$FAKE" "$QCMD" 'AT+CGMM' 2>/dev/null)
assert_contains "no-peek: answer still served"         'SIMCOM_SIM8260E' "$out"
assert_eq       "no-peek: no --peek attempt made"      'AT+CGMM'         "$(head -1 "$LOG")"

echo "== an OLD shim (answers ERROR to --peek) must be refused, not trusted =="
: > "$LOG"
rm -rf "$WORK/cache"
out=$(QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" ATC="$FAKE" "$QCMD_SKEW" 'AT+CGMM' 2>/dev/null)
assert_contains "old shim: qcmd retried under the lock" 'SIMCOM_SIM8260E' "$out"
assert_not_contains "old shim: the ERROR was not passed on" 'ERROR'       "$out"
assert_eq       "old shim: both attempts visible"      '--peek AT+CGMM'  "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"

echo "== a compound with a stale part must fall back as a whole =="
: > "$LOG"
rm -rf "$WORK/cache"
# prime AT+CGMM only, then ask for CGMM;CSQ — the second part is not cached
QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" ATC="$FAKE" \
    "$QCMD" 'AT+CGMM' >/dev/null 2>&1
: > "$LOG"
out=$(QM_AT_CACHE_DIR="$WORK/cache" QM_AT_BLACKLIST="$WORK/bl" ATC="$FAKE" \
      "$QCMD" 'AT+CGMM;+CSQ' 2>/dev/null)
assert_contains "compound: the real answer still arrives" 'SIMCOM_SIM8260E' "$out"
assert_contains "compound: ... including the uncached part" '+CSQ: 24,99'   "$out"
assert_eq       "compound: fell back to the locked path" 'AT+CGMM;+CSQ'     "$(tail -1 "$LOG")"

echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED_NAMES"
exit 1
