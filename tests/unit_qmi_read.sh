#!/bin/sh
# =============================================================================
# tests/unit_qmi_read.sh — contract tests for QManager's QMI reader library
# =============================================================================
# qmi_read.sh is the second, independent pipe into the modem (libqmi over QRTR),
# it never touches the AT port or its mutex, and it is the only source of the
# neighbour page's "Live" range. Every input it has is env-overridable —
# QM_QMI_BIN, QM_QMI_LIBDIR, QM_QMI_DEV, QM_QMI_TIMEOUT, QM_QMI_AVAIL_TTL — so
# the whole library runs here against tests/fake-qmicli-qmi with no modem, no
# libqmi, no QRTR node and no device access at all.
#
#   sh tests/unit_qmi_read.sh
#   QM_SRC=~/src/qmanager sh tests/unit_qmi_read.sh
#   QM_QMI_READ_SH=/data/qmanager/lib/qmi_read.sh sh tests/unit_qmi_read.sh
#
# CODE UNDER TEST is $QM_SRC's tree *plus* deploy-x16/qmi_read_ld_library_path.patch,
# staged into $TMPDIR — which is exactly what deploy-x16/install.sh ships (it
# applies that patch to the staged copy, and skips it when the tree already
# carries the fix). Staging keeps this suite honest whether or not the fix has
# been upstreamed, and touches nothing outside its own scratch directory.
#
# Four things are asserted, in the order a caller hits them:
#   1. the return-code contract — 0 ok, 2 unavailable, 3 call failed, 4 parse
#      failed. Callers keep their last-good data on any non-zero code, so a
#      code that is wrong in either direction either publishes a failed read as
#      "no cells are visible" or throws good data away;
#   2. the availability cache — a positive result is reused for
#      QM_QMI_AVAIL_TTL, and so is a FAILURE, which is then re-probed so a modem
#      that comes back is picked up without restarting the reader;
#   3. the LD_LIBRARY_PATH regression this library has already had once:
#      platform.sh defines qm_timeout as a shell FUNCTION, and on this
#      firmware's ash a `VAR=val func` prefix does not reach the function's
#      children, so qmicli could not load libqmi-glib and every call returned 3;
#   4. the neighbour and signal parsers against captured real qmicli output —
#      the JSON shape callers read (source:"qmi", exactly one serving row) and
#      the "null, never 0" rule for a value the modem did not report.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
FAKE="$HERE/fake-qmicli-qmi"
CELL_FIXTURE="$HERE/fixtures/qmi_cell_location.txt"
SIGNAL_FIXTURE="$HERE/fixtures/qmi_signal_info.txt"
LD_FIX="$REPO/deploy-x16/qmi_read_ld_library_path.patch"

TMP="${TMPDIR:-/tmp}/qmi-read-test.$$"
mkdir -p "$TMP/bin" "$TMP/lib"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
FAILED=""
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED
  - $1: $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }
excludes() { case "$3" in *"$2"*) bad "$1" "must NOT contain [$2], got [$3]" ;; *) ok "$1" ;; esac; }
begins_with() { case "$3" in "$2"*) ok "$1" ;; *) bad "$1" "expected to start with [$2], got [$3]" ;; esac; }
ends_with()   { case "$3" in *"$2") ok "$1" ;; *) bad "$1" "expected to end with [$2], got [$3]" ;; esac; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }

# --- locate and stage the code under test -----------------------------------
QM_SRC="${QM_SRC:-/tmp/qm}"
QMI_SRC="${QM_QMI_READ_SH:-}"
if [ -z "$QMI_SRC" ]; then
    for c in "$QM_SRC/scripts/usr/lib/qmanager/qmi_read.sh" \
             "$REPO/../greenpacket-o5a-qmanager/scripts/usr/lib/qmanager/qmi_read.sh"; do
        if [ -f "$c" ]; then QMI_SRC=$c; break; fi
    done
fi
if [ -z "$QMI_SRC" ] || [ ! -f "$QMI_SRC" ]; then
    echo "FATAL: qmi_read.sh not found — set QM_SRC or QM_QMI_READ_SH" >&2
    exit 2
fi
[ -f "$CELL_FIXTURE" ]   || { echo "FATAL: $CELL_FIXTURE missing" >&2; exit 2; }
[ -f "$SIGNAL_FIXTURE" ] || { echo "FATAL: $SIGNAL_FIXTURE missing" >&2; exit 2; }
[ -x "$FAKE" ] || chmod +x "$FAKE" 2>/dev/null

LIB="$TMP/lib/qmi_read.sh"
cp "$QMI_SRC" "$LIB" || { echo "FATAL: cannot read $QMI_SRC" >&2; exit 2; }
if grep -q 'LD_LIBRARY_PATH must be EXPORTED' "$LIB" 2>/dev/null; then
    SHAPE="$QMI_SRC (fix already in the tree)"
elif [ -f "$LD_FIX" ] && command -v patch >/dev/null 2>&1 &&
     ( cd "$TMP/lib" && patch -s -p1 < "$LD_FIX" ) >/dev/null 2>&1; then
    SHAPE="$QMI_SRC + deploy-x16/qmi_read_ld_library_path.patch"
else
    SHAPE="$QMI_SRC UNPATCHED — deploy-x16/qmi_read_ld_library_path.patch missing or did not apply"
fi
printf '  ..   code under test: %s\n' "$SHAPE"

# --- driver -----------------------------------------------------------------
# qm_timeout is a shell FUNCTION for the whole suite, deliberately: that is how
# platform.sh defines it on the device, and the LD_LIBRARY_PATH regression in
# section 3 only exists because of that boundary. It also means the suite needs
# no `timeout` binary, which macOS does not ship.
cat > "$TMP/drive.sh" <<'DRIVE'
# $1 = qmi_read.sh to source, $2 = shell snippet to evaluate in that shell
qm_timeout() { shift; "$@"; }
. "$1" || exit 90
shift
eval "$1"
DRIVE

# Replayable clock for the TTL tests: `date +%s` reads $FAKE_QMI_CLOCK, prints
# it, then adds $FAKE_QMI_CLOCK_STEP. A 60 s cache window is therefore exercised
# in microseconds, deterministically, instead of with `sleep 61`.
cat > "$TMP/bin/date" <<'DATE'
#!/bin/sh
now=$(cat "${FAKE_QMI_CLOCK:-}" 2>/dev/null) || now=1000000
[ -n "$now" ] || now=1000000
printf '%s\n' "$now"
step=${FAKE_QMI_CLOCK_STEP:-0}
if [ "$step" != 0 ]; then
    printf '%s\n' "$((now + step))" > "$FAKE_QMI_CLOCK"
fi
DATE
chmod +x "$TMP/bin/date"
CLOCK="$TMP/clock"
reset_clock() { printf '%s\n' 1000000 > "$CLOCK"; }
reset_clock

# runqm <snippet> — source the library with the fake qmicli and the captured
# fixtures, then evaluate <snippet> in that shell. stdout is the snippet's
# stdout and the status is the snippet's status. The FAKE_QMI_* knobs are read
# from this shell, which is how each scenario below picks its failure mode.
runqm() {
    env TMPDIR="$TMP" \
        PATH="$TMP/bin:$PATH" \
        QM_QMI_BIN="${QM_QMI_BIN:-$FAKE}" \
        QM_QMI_LIBDIR="${QM_QMI_LIBDIR:-/data/qmanager/lib/qmi/lib}" \
        QM_QMI_DEV="${QM_QMI_DEV:-qrtr://3}" \
        QM_QMI_TIMEOUT="${QM_QMI_TIMEOUT:-5}" \
        QM_QMI_AVAIL_TTL="${QM_QMI_AVAIL_TTL:-60}" \
        FAKE_QMI_CELL_FIXTURE="${FAKE_QMI_CELL_FIXTURE:-$CELL_FIXTURE}" \
        FAKE_QMI_SIGNAL_FIXTURE="${FAKE_QMI_SIGNAL_FIXTURE:-$SIGNAL_FIXTURE}" \
        FAKE_QMI_MODE="${FAKE_QMI_MODE:-}" \
        FAKE_QMI_FAIL_ON="${FAKE_QMI_FAIL_ON:-}" \
        FAKE_QMI_FAIL_MODE="${FAKE_QMI_FAIL_MODE:-}" \
        FAKE_QMI_FLIP_FILE="${FAKE_QMI_FLIP_FILE:-}" \
        FAKE_QMI_LOG="$LOG" \
        FAKE_QMI_LD_RECORD="${FAKE_QMI_LD_RECORD:-}" \
        FAKE_QMI_CLOCK="$CLOCK" \
        FAKE_QMI_CLOCK_STEP="${FAKE_QMI_CLOCK_STEP:-0}" \
        sh "$TMP/drive.sh" "$LIB" "$1"
}

# --- JSON readers (no jq: these suites must run with nothing installed) ------
# Every object the library emits is flat, so a greedy match is unambiguous once
# the object itself has been isolated.
val() { # val <flat-object> <key> — the value with any quotes stripped
    printf '%s\n' "$1" | sed -n 's/.*"'"$2"'":\([^,}]*\).*/\1/p' | tr -d '"'
}
obj() { # obj <json> <key> — the {..} object stored under <key>
    printf '%s\n' "$1" | sed -n 's/.*"'"$2"'":\({[^}]*}\).*/\1/p'
}
count_of() { # count_of <text> <literal> — occurrences of a literal
    printf '%s\n' "$1" | grep -o -F "$2" | wc -l | tr -d ' '
}
cell_count() { count_of "$1" '{"type":'; }
cell() { # cell <neighbour-json> <1-based row>
    printf '%s\n' "$1" | sed -n 's/^.*"cells":\[\(.*\)\]}$/\1/p' \
        | awk '{ gsub(/},\{/, "}\n{"); print }' \
        | sed -n "$2p"
}

# --- scenario driver --------------------------------------------------------
# Knobs are set explicitly for one call and cleared afterwards, never with a
# `VAR=val func` prefix: bash keeps that assignment in scope after the function
# returns, so a prefix-based suite leaks one case's failure mode into the next
# (this suite did exactly that before the knobs were made explicit).
reset_knobs() {
    QM_QMI_BIN=""; QM_QMI_LIBDIR=""
    FAKE_QMI_MODE=""; FAKE_QMI_FAIL_ON=""; FAKE_QMI_FAIL_MODE=""
    FAKE_QMI_FLIP_FILE=""; FAKE_QMI_LD_RECORD=""
    FAKE_QMI_CELL_FIXTURE=""; FAKE_QMI_SIGNAL_FIXTURE=""
    FAKE_QMI_CLOCK_STEP=0
}

LOG="$TMP/calls.log"
OUT=""
RC=0
# qmrun <snippet> [knob=value ...] — one scenario. $LOG is cleared first; OUT and
# RC are left holding the snippet's stdout and status.
qmrun() {
    _snip=$1
    shift
    reset_knobs
    for _kv in "$@"; do export "$_kv"; done
    rm -f "$LOG"
    OUT=$(runqm "$_snip")
    RC=$?
    reset_knobs
}
read_neighbours() { qmrun 'qm_qmi_neighbours' "$@"; }
read_signal()     { qmrun 'qm_qmi_signal' "$@"; }

# =============================================================================
# 1. Return-code contract
# =============================================================================
printf '\n1. return-code contract (0 ok / 2 unavailable / 3 call failed / 4 parse failed)\n'

read_neighbours
eq "captured answer, fake qmicli healthy -> 0 (ok)" "0" "$RC"

# 2 — the transport is not there at all.
read_neighbours QM_QMI_BIN=/nonexistent/qmicli
eq "binary missing -> 2 (unavailable), callers stay on AT" "2" "$RC"
eq "a missing binary publishes no JSON" "" "$OUT"

: > "$TMP/qmicli-not-executable"
chmod 644 "$TMP/qmicli-not-executable"
read_neighbours QM_QMI_BIN="$TMP/qmicli-not-executable"
eq "binary present but not executable -> 2 (unavailable)" "2" "$RC"

# The availability probe gates every reader, so a probe that cannot answer is
# reported as 2 — "the QRTR node is silent" — not as 3.
read_neighbours FAKE_QMI_FAIL_ON=--dms-get-operating-mode FAKE_QMI_FAIL_MODE=exit1
eq "silent QRTR node (probe exits 1) -> 2 (unavailable)" "2" "$RC"

read_neighbours FAKE_QMI_MODE=empty
eq "a modem that answers nothing at all -> 2: the probe gates every reader" "2" "$RC"

# 3 — the probe answered but the payload call did not. This is the only path on
# which a caller ever sees 3, so the fake needs a per-call rule to reach it.
read_neighbours FAKE_QMI_FAIL_ON=--nas-get-cell-location-info FAKE_QMI_FAIL_MODE=exit1
eq "payload call exits 1 -> 3 (call failed)" "3" "$RC"
eq "a failed call publishes no JSON, so the caller keeps last-good data" "" "$OUT"

read_neighbours FAKE_QMI_FAIL_ON=--nas-get-cell-location-info FAKE_QMI_FAIL_MODE=empty
eq "payload call exits 0 with empty output -> 3 (call failed)" "3" "$RC"
eq "a half-answered (empty) call publishes no JSON" "" "$OUT"

read_neighbours FAKE_QMI_FAIL_ON=--nas-get-cell-location-info FAKE_QMI_FAIL_MODE=nomarker
eq "output with no success marker -> 3 (call failed)" "3" "$RC"

# 4 — the marker was there, so the call succeeded, but nothing parsed out of it.
read_neighbours FAKE_QMI_FAIL_ON=--nas-get-cell-location-info FAKE_QMI_FAIL_MODE=garbage
eq "success marker with no cell rows -> 4 (parse failed)" "4" "$RC"
eq "a parse failure publishes no JSON either — never an empty cell list" "" "$OUT"

# The two-call reader keeps the same contract on both halves: signal values
# without the attachment state are the trap the library's header forbids.
read_signal
eq "signal reader with both halves answered -> 0" "0" "$RC"

read_signal FAKE_QMI_FAIL_ON=--nas-get-signal-info FAKE_QMI_FAIL_MODE=garbage
eq "signal answer with no LTE/5G rows -> 4 (parse failed)" "4" "$RC"
eq "a signal parse failure publishes no JSON" "" "$OUT"

read_signal FAKE_QMI_FAIL_ON=--nas-get-serving-system FAKE_QMI_FAIL_MODE=exit1
eq "registration half fails -> 3: values are not published without it" "3" "$RC"
eq "no signal values are published when the registration half fails" "" "$OUT"

# =============================================================================
# 2. Availability cache
# =============================================================================
printf '\n2. availability cache (QM_QMI_AVAIL_TTL)\n'

count_calls() {
    if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi
}
probe_twice='qm_qmi_available; echo "first=$?"; qm_qmi_available; echo "second=$?"'

reset_clock
qmrun "$probe_twice"
eq "two probes inside the TTL both report available" "first=0 second=0" "$(oneline "$OUT")"
eq "a positive probe is reused: one qmicli call, not two" "1" "$(count_calls)"

# The comparison in qm_qmi_available is `-le`, so a window that has elapsed
# exactly is still cached and one second more is not. Both sides are asserted
# because changing `-le` to `-lt` doubles the probe rate of every 1 Hz reader.
reset_clock
qmrun "$probe_twice" FAKE_QMI_CLOCK_STEP=60
eq "exactly QM_QMI_AVAIL_TTL seconds later the cached answer is still used (-le)" "1" "$(count_calls)"

reset_clock
qmrun "$probe_twice" FAKE_QMI_CLOCK_STEP=61
eq "past the TTL the probe is repeated" "2" "$(count_calls)"
eq "and the re-probe still reports available" "first=0 second=0" "$(oneline "$OUT")"

# A FAILURE is cached on the same window, or a dead modem costs a qmicli spawn
# per call...
reset_clock
qmrun "$probe_twice" FAKE_QMI_MODE=exit1
eq "an unavailable modem reports unavailable on both probes" "first=1 second=1" "$(oneline "$OUT")"
eq "a failed probe is cached too: one qmicli call, not two" "1" "$(count_calls)"

# ...and it is re-probed after the TTL, which is how a modem that comes back is
# picked up without restarting the reader.
reset_clock
rm -f "$TMP/flip"
qmrun 'qm_qmi_available; echo "first=$?"; : > "$FAKE_QMI_FLIP_FILE"; qm_qmi_available; echo "second=$?"' \
      FAKE_QMI_MODE=exit1 FAKE_QMI_FLIP_FILE="$TMP/flip" FAKE_QMI_CLOCK_STEP=61
eq "a cached failure is re-probed after the TTL and a recovered modem is seen" "first=1 second=0" "$(oneline "$OUT")"
eq "the re-probe cost a second qmicli call" "2" "$(count_calls)"

# =============================================================================
# 3. LD_LIBRARY_PATH must reach the child (regression this library had once)
# =============================================================================
printf '\n3. LD_LIBRARY_PATH reaches qmicli (never as a `VAR=val qm_timeout` prefix)\n'

# The premise: qm_timeout is a function in this environment, as platform.sh
# defines it on the device. Were it an external command, the prefix form would
# work and this section would be testing nothing.
qmrun 'command -v qm_timeout'
eq "qm_timeout resolves to a shell function, as platform.sh defines it" "qm_timeout" "$OUT"

# The deterministic half of the regression test. On bash and dash a `VAR=val
# function` prefix IS exported to the function's children, so the behavioural
# assertion below cannot catch a reintroduced prefix on every host; this one can,
# on all of them. The pattern is the prefix form ending in a line continuation.
n=$(grep -c '^[[:space:]]*LD_LIBRARY_PATH=.*\\[[:space:]]*$' "$LIB")
eq "qmicli is not launched with a VAR=val prefix that ash drops at the function boundary" "0" "$n"
order=$(awk '/^[ \t]*export LD_LIBRARY_PATH[ \t]*$/ { if (!e) e = NR }
             /qm_timeout "\$QM_QMI_TIMEOUT"/ { t = NR }
             END { if (e && t && e < t) print "export-before-call"; else print "no-export-before-call" }' "$LIB")
eq "the private libdir is exported before qm_timeout is invoked" "export-before-call" "$order"
order=$(awk '/LD_LIBRARY_PATH="\$_qm_old_ld"/ { r = NR }
             /qm_timeout "\$QM_QMI_TIMEOUT"/ { t = NR }
             END { if (r && t && r > t) print "restored-after-call"; else print "not-restored" }' "$LIB")
eq "the caller's LD_LIBRARY_PATH is restored after the call" "restored-after-call" "$order"

LDREC="$TMP/ld.record"
rm -f "$LDREC"
qmrun 'qm_qmi_neighbours >/dev/null; echo "rc=$?"' \
      QM_QMI_LIBDIR=/opt/qmi/lib-under-test FAKE_QMI_LD_RECORD="$LDREC"
eq "the read succeeds with the libdir under test" "rc=0" "$(oneline "$OUT")"
seen=$(sed -n 1p "$LDREC" 2>/dev/null)
case $seen in
    /opt/qmi/lib-under-test|/opt/qmi/lib-under-test:*)
        ok "qmicli runs with QM_QMI_LIBDIR in its environment" ;;
    '<unset>'|'')
        bad "qmicli runs with QM_QMI_LIBDIR in its environment" \
            "qmicli saw no LD_LIBRARY_PATH at all: libqmi-glib.so.5 cannot load, every call would return 3" ;;
    *)
        bad "qmicli runs with QM_QMI_LIBDIR in its environment" "qmicli saw [$seen]" ;;
esac

# The other half of the export: repeated reads must not accumulate the libdir,
# which is what a missing restore would do. Three qmicli calls are expected —
# one availability probe (reused from the cache) and one per read.
rm -f "$LDREC"
qmrun 'qm_qmi_neighbours >/dev/null; qm_qmi_neighbours >/dev/null; echo "rc=$?"' \
      QM_QMI_LIBDIR=/opt/qmi/lib-under-test FAKE_QMI_LD_RECORD="$LDREC"
eq "both reads succeed" "rc=0" "$(oneline "$OUT")"
eq "one probe and two payload calls reached qmicli" "3" "$([ -f "$LDREC" ] && wc -l < "$LDREC" | tr -d ' ' || echo 0)"
eq "the second read sees the same libdir, not an accumulating one" \
    "$(sed -n 2p "$LDREC" 2>/dev/null)" "$(sed -n 3p "$LDREC" 2>/dev/null)"

# =============================================================================
# 4. Parsers against the captured answers
# =============================================================================
printf '\n4. parsers (captured qmicli output)\n'

# tests/fixtures/qmi_cell_location.txt is the literal captured answer
# (qmicli --nas-get-cell-location-info on this QRTR node). Recon-distance-mimo.md
# §1.4 reports the same call's sections; it condenses each field onto one line
# where qmicli itself breaks them one per line, and the parser matches on the
# line breaks qmicli actually writes.
read_neighbours
NJ=$OUT
eq "cell-location capture parses -> 0" "0" "$RC"
eq "the answer is one JSON object on one line" "1" "$(printf '%s\n' "$NJ" | wc -l | tr -d ' ')"
begins_with "the object opens with the serving cell" '{"serving":{' "$NJ"
ends_with "the object closes the cells array" ']}' "$NJ"
eq "braces balance" "$(count_of "$NJ" '{')" "$(count_of "$NJ" '}')"

eq "all four captured LTE cells are published" "4" "$(cell_count "$NJ")"
eq "exactly one row is flagged serving:true" "1" "$(count_of "$NJ" '"serving":true')"
eq "every row carries source:\"qmi\", the API's provenance field" "4" "$(count_of "$NJ" '"source":"qmi"')"
eq "every row is rat LTE: QMI reports no NR neighbour cells" "4" "$(count_of "$NJ" '"rat":"LTE"')"
eq "every row is intrafrequency, the only section that carried cells" "4" "$(count_of "$NJ" '"type":"intra"')"
eq "an empty Interfrequency section adds no inter row" "0" "$(count_of "$NJ" '"type":"inter"')"
excludes "the trailing '5GNR ARFCN' line is not turned into an NR cell" '"earfcn":"509070"' "$NJ"

SERVING=$(obj "$NJ" serving)
eq "serving.pci is the section's Serving Cell ID" "104" "$(val "$SERVING" pci)"
eq "serving.earfcn is the section's E-UTRA channel" "250" "$(val "$SERVING" earfcn)"
eq "serving.rsrp is a JSON number, not a quoted string" "-77.9" "$(val "$SERVING" rsrp)"
eq "serving.rsrq" "-11.0" "$(val "$SERVING" rsrq)"
eq "serving.rssi" "-50.3" "$(val "$SERVING" rssi)"
eq "the serving row is the cell whose PCI matches, and it is first" "104" "$(val "$(cell "$NJ" 1)" pci)"
eq "the serving row repeats serving:true" "true" "$(val "$(cell "$NJ" 1)" serving)"
eq "a neighbour row is serving:false" "false" "$(val "$(cell "$NJ" 2)" serving)"
eq "neighbour 2 keeps its own PCI" "102" "$(val "$(cell "$NJ" 2)" pci)"

# A neighbour the modem does not report a value for must be null, never 0: 0 is
# a measurement, null is "the modem did not say". The variant is the shape
# QManager's own stub capture carries — one cell with the RSRP line absent.
awk '/Cell \[2\]:/ { c2 = 1 } c2 && !dropped && /RSRP:/ { dropped = 1; next } { print }' \
    "$CELL_FIXTURE" > "$TMP/cell_missing_rsrp.txt"
read_neighbours FAKE_QMI_CELL_FIXTURE="$TMP/cell_missing_rsrp.txt"
MJ=$OUT
eq "a neighbour with no RSRP line still parses" "4" "$(cell_count "$MJ")"
eq "an unreported RSRP is null, never 0" "null" "$(val "$(cell "$MJ" 3)" rsrp)"
eq "the neighbours that did report RSRP keep their values" "-85.4" "$(val "$(cell "$MJ" 4)" rsrp)"

# tests/fixtures/qmi_signal_info.txt is the same capture's
# --nas-get-signal-info answer: units travel inside the quotes, so the parser has
# to strip them or every value would become a string.
read_signal
SJ=$OUT
eq "signal capture parses -> 0" "0" "$RC"
begins_with "the object opens with the LTE block" '{"lte":{' "$SJ"
contains "the object carries the attachment state alongside the values" '"registered":' "$SJ"
eq "LTE RSRP" "-79" "$(val "$(obj "$SJ" lte)" rsrp)"
eq "LTE RSRQ" "-12" "$(val "$(obj "$SJ" lte)" rsrq)"
eq "LTE RSSI" "-53" "$(val "$(obj "$SJ" lte)" rssi)"
eq "LTE SNR keeps its tenth of a dB" "4.2" "$(val "$(obj "$SJ" lte)" snr)"
eq "5G RSRP" "-60" "$(val "$(obj "$SJ" nr)" rsrp)"
eq "5G RSRQ" "-11" "$(val "$(obj "$SJ" nr)" rsrq)"
eq "5G SNR" "26.5" "$(val "$(obj "$SJ" nr)" snr)"
eq "no measurement is published as a quoted string" "0" "$(count_of "$SJ" '"rsrp":"')"
eq "the registration state is the modem's, not a guess" "true" "$(val "$SJ" registered)"
eq "the carrier is the Current PLMN description" "Jazz" "$(val "$SJ" carrier)"

# No 5G section at all (LTE-only attach) means nr:null — not an object of zeros,
# and not an object of nulls either: the shape itself says "there is no NR leg".
sed '/^5G:/,$d' "$SIGNAL_FIXTURE" > "$TMP/signal_lte_only.txt"
read_signal FAKE_QMI_SIGNAL_FIXTURE="$TMP/signal_lte_only.txt"
LJ=$OUT
eq "an answer with no 5G section yields nr:null" "1" "$(count_of "$LJ" '"nr":null')"
excludes "a missing 5G section is not invented as an object of zeros" '"nr":{"rsrp":0' "$LJ"
excludes "a missing 5G section is not turned into an object of nulls" '"nr":{"rsrp":null' "$LJ"
eq "the LTE half still parses when the 5G section is absent" "-79" "$(val "$(obj "$LJ" lte)" rsrp)"

# With the NR leg down libqmi still prints the 5G block, with 'n/a' for every
# value (recon-distance-mimo.md §1.4 records exactly that on this box). That is a
# different shape from "no section": nr is an object here, and its values are
# null rather than 0.
sed "/^5G:/,\$ { s/'-60 dBm'/'n\/a'/; s/'-11 dB'/'n\/a'/; s/'26.5 dB'/'n\/a'/; }" \
    "$SIGNAL_FIXTURE" > "$TMP/signal_nr_na.txt"
read_signal FAKE_QMI_SIGNAL_FIXTURE="$TMP/signal_nr_na.txt"
NAJ=$OUT
eq "a 5G block reporting 'n/a' yields nr with nulls, not zeros" "1" \
    "$(count_of "$NAJ" '"nr":{"rsrp":null,"rsrq":null,"snr":null}')"

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED"
exit 1
