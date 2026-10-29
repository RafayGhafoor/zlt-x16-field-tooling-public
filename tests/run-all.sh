#!/bin/sh
# =============================================================================
# tests/run-all.sh — one entry point for every test
# =============================================================================
#   sh tests/run-all.sh              # unit tests only (no device needed)
#   sh tests/run-all.sh --device     # + endpoint smoke test over SSH
#
# The device leg needs the retry wrapper used everywhere else in this repo
# (the X16 sits behind a load-balancing uplink and drops ~1 connection in 3):
#   SSH_OPTS="-o ConnectTimeout=8"
#   sshpass -p <redacted-password> ssh $SSH_OPTS root@192.168.3.1 ...
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
DEVICE="${DEVICE:-root@192.168.3.1}"
PASSWORD="${DEVICE_PASS:-<redacted-password>}"
WITH_DEVICE=0
[ "${1:-}" = "--device" ] && WITH_DEVICE=1

RC=0

# ---------------------------------------------------------------------------
# Parallel by default. The suites are independent processes that each set their
# own temp paths, and the wall-clock cost was entirely waiting (18 s real vs
# 8.7 s of CPU) -- so running them concurrently is close to free: 14 s -> 5 s
# on an 8-core host, measured stable over repeated runs.
#
# Output stays DETERMINISTIC: each suite writes to its own file and the files
# are replayed in declaration order, so a failure is where it always was rather
# than wherever the scheduler happened to put it.
#
# Sequential is one env var away, and is the fallback when there is only one
# core (no point) or when a suite is suspected of contamination:
#     QM_TESTS_SEQ=1 sh tests/run-all.sh
#
# The device leg is NEVER parallelised: it is one SSH session against a 1-core
# router, and concurrent runs there are what made an earlier recon drive it to
# load 20.
# ---------------------------------------------------------------------------
CORES=$( (getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1) | head -1 )
case "$CORES" in ''|*[!0-9]*) CORES=1 ;; esac
if [ "${QM_TESTS_SEQ:-0}" = "1" ] || [ "$CORES" -le 1 ]; then
    PARALLEL=0
else
    PARALLEL=1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/qm-tests.XXXXXX") || exit 1
# Keep the per-suite logs when the run FAILS.
#
# They used to be deleted unconditionally, which made a transient failure
# undiagnosable: the parallel runner writes each suite's full transcript to
# $WORK/<n>.log, and once the run ended there was nothing left to look at. Two
# suites did fail once ("shim: policy" and "PHY devinfo source") and nine
# subsequent runs — including under 8-core load — passed, so the flake could not
# be chased down; the evidence had already been removed by this trap. Keeping it
# costs a copied directory and only on failure.
KEEP="${TMPDIR:-/tmp}/qm-tests-last-failure"
trap 'if [ "${RC:-0}" != "0" ]; then rm -rf "$KEEP"; cp -R "$WORK" "$KEEP" 2>/dev/null && printf "\n suite logs kept in %s (per-suite transcripts incl. the failing assertions)\n" "$KEEP" >&2; fi; rm -rf "$WORK"' EXIT
SUITE_LIST="$WORK/suites"
: > "$SUITE_LIST"
NSUITE=0

# Declare a suite. Runs immediately when sequential, otherwise queues it.
run_unit() {
    name=$1
    file=$2
    NSUITE=$((NSUITE + 1))
    printf '%s\t%s\t%s\n' "$NSUITE" "$name" "$file" >> "$SUITE_LIST"
    if [ "$PARALLEL" = "0" ]; then
        _run_one "$NSUITE" "$name" "$file"
    fi
}

# A suite that calls an undefined helper still exits 0: `sh` prints
# "command not found" to stderr and carries on, so the assertion silently does
# not run and the suite looks green. That happened for real in
# unit_cgi_parsers.sh, where an assertion used `pass`/`fail` instead of
# `ok`/`bad` and had been doing nothing. Treat it as a failure -- an assertion
# that did not run is not a passing assertion.
_scan_log() {
    _log=$1; _name=$2
    if grep -q 'command not found' "$_log" 2>/dev/null; then
        printf '\n### %s FAILED: a helper was not defined (assertions silently skipped)\n' "$_name"
        grep 'command not found' "$_log" | head -3 | sed 's/^/    /'
        return 1
    fi
    return 0
}

_run_one() {
    _n=$1; _name=$2; _file=$3
    printf '\n### %s\n' "$_name"
    if _scan_log "$WORK/$_n.log" "$_name" && sh "$_file" > "$WORK/$_n.log" 2>&1 && _scan_log "$WORK/$_n.log" "$_name"; then
        cat "$WORK/$_n.log"
        echo "0" > "$WORK/$_n.rc"
    else
        cat "$WORK/$_n.log"
        RC=1
        printf '### %s FAILED\n' "$_name"
        echo "1" > "$WORK/$_n.rc"
    fi
}

_run_parallel() {
    while IFS='	' read -r _n _name _file; do
        ( sh "$_file" > "$WORK/$_n.log" 2>&1; echo "$?" > "$WORK/$_n.rc" ) &
    done < "$SUITE_LIST"
    wait
    # Replay in declaration order so the transcript reads the same every run.
    while IFS='	' read -r _n _name _file; do
        printf '\n### %s\n' "$_name"
        cat "$WORK/$_n.log" 2>/dev/null
        if [ "$(cat "$WORK/$_n.rc" 2>/dev/null)" != "0" ] || ! _scan_log "$WORK/$_n.log" "$_name"; then
            RC=1
            printf '### %s FAILED\n' "$_name"
        fi
    done < "$SUITE_LIST"
}

printf '=================================================================\n'
printf ' QManager-on-ZLT-X16 test suite\n'
printf '=================================================================\n'

# The shim suite is split in two so the halves run side by side; combined they
# are the same 153 assertions as the original single file. It was the commit
# gate's critical path purely by accumulation.
run_unit "shim: dialect (transport, cells, CA, bands)"      "$HERE/unit_atcli_dialect.sh"
run_unit "shim: policy (chains, cache, allowlist, perf)"    "$HERE/unit_atcli_policy.sh"
run_unit "shim: daemon sentinels (file transfer, CFUN?)"  "$HERE/unit_atcli_sentinels.sh"
run_unit "atcmd guard: URC-thread / absent-daemon decisions" "$HERE/unit_atcmd_guard.sh"
# The lock-free read path spans two files — the shim's --peek mode and qcmd's
# decision to trust it — so it gets a suite that drives the real qcmd (from the
# QManager tree) against the fake modem and asserts which path ran.
run_unit "qcmd: snapshot-fresh reads skip the AT lock"      "$HERE/unit_qcmd_peek.sh"
run_unit "traffic sampler"                          "$HERE/unit_traffic_sampler.sh"
run_unit "neighbour-cell scanner"                   "$HERE/unit_neighbour_scan.sh"
run_unit "speedtest binary + status state machine"     "$HERE/unit_speedtest.sh"
run_unit "tower LTE-lock translation + schedule guards" "$HERE/unit_tower_schedule.sh"
run_unit "cell history archive without optional QMI"       "$HERE/unit_history_archive.sh"
# --- added for the 2026-10-26 fix batch (porting coverage) -------------------
# Each of these exists because a fix in that batch was wrong in a way the old
# suite could not see. They are grouped by the layer they pin, so a port to a
# new device fails in the layer that actually differs.
run_unit "shim: MIMO/TA/capability from non-AT sources"   "$HERE/unit_shim_sources.sh"
run_unit "QMI reader: return codes, cache, LD_LIBRARY_PATH" "$HERE/unit_qmi_read.sh"
run_unit "flap meter: change-vs-drop direction, absent data" "$HERE/unit_flap_meter.sh"
run_unit "QMI bands: capability/policy lists, no AT+CSYSSEL=?"   "$HERE/unit_qmi_bands.sh"
run_unit "QMI probe: cells/signal text parity with qmicli"   "$HERE/unit_qmi_probe_text.sh"
run_unit "PHY devinfo source: fail-soft, gates, merge"      "$HERE/unit_phy_devinfo.sh"
run_unit "CGI parsers: SMS store, APN CID, autoneg, bands"  "$HERE/unit_cgi_parsers.sh"
# The process table is the only CGI that computes a percentage itself: /proc is
# cumulative, so the share only exists relative to the previous sample it keeps
# in /tmp. This suite fabricates a /proc tree and advances the counters by hand.
run_unit "process table: /proc deltas, null-vs-zero, ordering" "$HERE/unit_processes_cgi.sh"
# Serving-cell parsing must not fabricate a band. "B" f(N) turned a band field of
# 0 into the literal "B0" during a service blip, which events.sh reported as a
# real band change plus a PCI handoff -- the UI's "continuous cell handoffs".
run_unit "parse_at: no fabricated band / phantom handoffs"   "$HERE/unit_parse_at.sh"
run_unit "payload integration: staging, patches, paths"     "$HERE/integration_payload.sh"

[ "$PARALLEL" = "1" ] && _run_parallel

# Static sanity that costs nothing and catches the two deploy traps that have
# actually bitten: a lost exec bit and a stale absolute path.
printf '\n### static checks\n'
miss=0
for f in "$REPO"/deploy-x16/*; do
    # only files that are actually scripts (shebang) must be executable
    head -c 2 "$f" 2>/dev/null | grep -q '#!' || continue
    [ -x "$f" ] || { echo "  FAIL not executable: $f"; miss=1; }
done
[ "$miss" = "0" ] && echo "  ok   every deploy-x16 script is executable" || RC=1

if grep -n '/usrdata\|/usr/lib/qmanager' "$REPO"/deploy-x16/atcli_smd11 "$REPO"/deploy-x16/qm_serve.sh 2>/dev/null | grep -v '^.*#' >/dev/null; then
    echo "  FAIL GreenPacket paths leaked into the X16 layer"
    RC=1
else
    echo "  ok   no GreenPacket paths in the X16 layer"
fi

# Frontend maths + the freshness rule. Kept separate from run_unit because it
# needs bun and the QManager source tree; the wrapper prints its own SKIP line
# and exits 0 when they are unavailable, so a host without them still runs the
# shell suites rather than failing.
printf '\n### frontend maths + staleness (bun)\n'
if sh "$HERE/ts/run-ts-tests.sh"; then
    :
else
    RC=1
    printf '### frontend maths FAILED\n'
fi

if [ "$WITH_DEVICE" = "1" ]; then
    printf '\n### device smoke (%s)\n' "$DEVICE"
    if cat "$HERE/smoke_endpoints.sh" | sshpass -p "$PASSWORD" ssh \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "$DEVICE" 'cat > /tmp/smoke.sh' 2>/dev/null; then
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "$DEVICE" "sh /tmp/smoke.sh '$PASSWORD'" || RC=1

        printf '\n### boot wiring (%s)\n' "$DEVICE"
        if cat "$HERE/check_boot_wiring.sh" | sshpass -p "$PASSWORD" ssh \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 "$DEVICE" 'cat > /tmp/boot.sh' 2>/dev/null; then
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 "$DEVICE" 'sh /tmp/boot.sh' || RC=1
        else
            echo "  FAIL could not reach $DEVICE"
            RC=1
        fi
    else
        echo "  FAIL could not reach $DEVICE"
        RC=1
    fi
fi

printf '\n=================================================================\n'
if [ "$RC" = "0" ]; then
    echo " ALL TESTS PASSED"
else
    echo " TESTS FAILED"
fi
printf '=================================================================\n'
exit "$RC"
