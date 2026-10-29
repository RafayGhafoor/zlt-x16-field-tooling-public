#!/bin/sh
# unit_phy_devinfo.sh — host tests for the X16 third PHY source: the vendor
# devinfo store, added to QManager's lib/phy_metrics.sh by
# deploy-x16/phy_metrics_x16_devinfo.patch.
#
# The library is NOT vendored in this repo. Every run copies the unpatched
# phy_metrics.sh out of the QManager tree, applies the patch with the same
# `patch -p1` the deploy uses, and sources the result — so these tests also fail
# if the patch stops applying, and nothing here can pass against a hand-edited
# copy of the file.
#
# Device truth is in tests/fixtures/devinfo_{live,stale,partial}.txt, taken from
# docs/captures/recon-detail-metrics.md §3, the live dump of the dialer's
# /tmp/.devinfo_module_data (SIMCom SIM8260E, 2026-10-26 15:48:58 device time):
#   live    the captured instant, CQI 6, CQI_5G 11, lte_rank 1, nr_rank 2,
#           DL_MCS_5G 0, UL_MCS_5G 19, UL_MCS empty, MIMO_STATUS empty
#   stale   the same table at an earlier instant (the recon watched
#           CQI 10 -> 5 -> 6), so "a stale read yields nothing" is also "10
#           never reaches the UI"; its mtime is pushed back by the test
#   partial the dialer still rewriting the store but the metric keys empty
#
# Fixtures are COPIED and touch(1)ed into the temp dir before use: their mtime
# in a git checkout is whatever the checkout made it, and the library rejects a
# store older than QM_PHY_DEVINFO_TTL (30 s) — reading a fixture in place would
# make these tests depend on when the repo was cloned.
#
# Portable POSIX sh, no installs. QM_SRC may be set to point at another QManager
# scripts/usr/lib/qmanager directory.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
QM_SRC="${QM_SRC:-$HERE/../../greenpacket-o5a-qmanager/scripts/usr/lib/qmanager}"
PATCHFILE="$HERE/../deploy-x16/phy_metrics_x16_devinfo.patch"
FIX="$HERE/fixtures"
TMP="${TMPDIR:-/tmp}/unit_phy_devinfo.$$"
LIB="$TMP/src/phy_metrics.sh"
mkdir -p "$TMP/bin" "$TMP/src"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
    bad "prerequisites" "jq not found; the library parses the store with jq"
    printf 'FAIL  0 passed, %s failed\n' "$FAIL"
    exit 1
fi

# -----------------------------------------------------------------------------
# Harness: the patched library, and fakes for the two externals it spends.
# -----------------------------------------------------------------------------
# `timeout`: _qm_phy_capture() needs something that bounds an external call and
# still passes its stdout and exit status through. Supplied here so the suite
# does not depend on coreutils being installed (macOS has no `timeout` by
# default) or on HOMEbrew's copy being first on PATH.
cat > "$TMP/bin/timeout" <<'SHIM'
#!/bin/sh
shift
exec "$@"
SHIM

# Fake qcmd, the AT transport. Real behaviour on a device where the read fails:
# no output, non-zero. Real behaviour on the X16, whose shim stubs AT+QNWCFG:
# a bare "OK" and no +QNWCFG payload. FAKE_QCMD_FILE picks which one happens.
cat > "$TMP/bin/qcmd" <<'SHIM'
#!/bin/sh
[ -n "${FAKE_QCMD_FILE:-}" ] || exit 1
cat "$FAKE_QCMD_FILE"
SHIM
chmod +x "$TMP/bin/timeout" "$TMP/bin/qcmd"

# One library call in its own shell: source the patched file, run the snippet.
# $1 is the store to point QM_PHY_DEVINFO_FILE at; the rest is the snippet.
run_lib() {
    _store=$1
    shift
    env QM_LIB="$LIB" QM_PHY_DEVINFO_FILE="$_store" QM_PHY_JQ="$JQ" \
        PATH="$TMP/bin:$PATH" \
        sh -c ". \"\$QM_LIB\"; $*"
}

# One field of the devinfo-derived AT-shaped object / modemd-shaped object.
at_f() { run_lib "$1" 'qm_phy_x16_at' | "$JQ" -r "$2" 2>/dev/null; }
md_f() { run_lib "$1" 'qm_phy_x16_modemd' | "$JQ" -r "$2" 2>/dev/null; }

# A copy of the live capture with one "key:value" line replaced, so a range-gate
# assertion is about the gate and not about the rest of the fixture. Unknown key
# is appended, which also proves the parser does not require a fixed layout.
mkstore() {  # mkstore <out> <key> <value>
    awk -v k="$2" -v v="$3" '
        { split($0, kv, ":") }
        kv[1] == k { print k ":" v; done = 1; next }
        { print }
        END { if (!done) print k ":" v }' "$TMP/devinfo_live.txt" > "$1"
}

# A copy of the live capture with one key absent entirely.
dropkey() {  # dropkey <out> <key>
    awk -v k="$2" -F: '$1 != k' "$TMP/devinfo_live.txt" > "$1"
}

# -----------------------------------------------------------------------------
# Setup 1 — the patch applies to the QManager source
# -----------------------------------------------------------------------------
cp "$QM_SRC/phy_metrics.sh" "$TMP/src/phy_metrics.sh" 2>/dev/null
if [ ! -f "$TMP/src/phy_metrics.sh" ]; then
    bad "QManager phy_metrics.sh is readable" "nothing at $QM_SRC (set QM_SRC)"
    printf 'FAIL  0 passed, %s failed\n' "$FAIL"
    exit 1
fi
PATCH_OUT=$( cd "$TMP/src" && patch -p1 -s < "$PATCHFILE" 2>&1 )
PATCH_RC=$?
if [ "$PATCH_RC" -eq 0 ] && grep -q '^qm_phy_x16_at()' "$LIB" 2>/dev/null &&
   grep -q '^qm_phy_x16_modemd()' "$LIB" 2>/dev/null; then
    ok "patch -p1 applies to QManager phy_metrics.sh and defines both X16 sources"
else
    bad "patch -p1 applies to QManager phy_metrics.sh" \
        "rc=$PATCH_RC at $QM_SRC: $PATCH_OUT"
    printf 'FAIL  0 passed, %s failed\n' "$FAIL"
    exit 1
fi

# -----------------------------------------------------------------------------
# Setup 2 — the primitives the rest of the suite stands on
# -----------------------------------------------------------------------------
# The TTL gate reads the store's mtime as `date -r <path> +%s`. Prove that form
# reads a FILE's mtime on this host, and that `touch -t` puts it in the past —
# both are what the staleness tests below mean by "old". (BSD date on macOS
# documents `-r filename` alongside `-r seconds`; GNU date and busybox date both
# accept a path there too. Neither flag is GNU-only.)
: > "$TMP/mtime_probe"
touch -t 202001010000 "$TMP/mtime_probe"
PROBE_M=$(date -r "$TMP/mtime_probe" +%s 2>/dev/null) || PROBE_M=""
PROBE_NOW=$(date +%s)
case "$PROBE_M" in
    ''|*[!0-9]*) PROBE_AGE=unreadable ;;
    *)           PROBE_AGE=$(( PROBE_NOW - PROBE_M )) ;;
esac
if [ "$PROBE_AGE" != unreadable ] && [ "$PROBE_AGE" -gt 100000000 ]; then
    ok "host date -r <path> reads file mtime and touch -t backdates it"
else
    bad "host date -r <path> reads file mtime and touch -t backdates it" \
        "date -r -> [$PROBE_M] (age $PROBE_AGE s); the TTL gate cannot work on this host"
fi

for n in live stale partial; do
    cp "$FIX/devinfo_$n.txt" "$TMP/devinfo_$n.txt"
done
LIVE="$TMP/devinfo_live.txt"
STALE="$TMP/devinfo_stale.txt"
PARTIAL="$TMP/devinfo_partial.txt"
touch "$LIVE" "$PARTIAL"                 # fresh: inside any TTL under test
touch -t 202001010000 "$STALE"           # 2020-01-01: outside every TTL
MISSING="$TMP/no-such-store"

mkstore "$TMP/gate_cqi0.txt"     CQI       0
mkstore "$TMP/gate_cqi16.txt"    CQI       16
mkstore "$TMP/gate_rank0.txt"    lte_rank  0
mkstore "$TMP/gate_cqi5g0.txt"   CQI_5G    0
mkstore "$TMP/gate_sim0.txt"     sim_status 0
dropkey "$TMP/no_sim_status.txt" sim_status
for f in "$TMP"/gate_*.txt "$TMP/no_sim_status.txt"; do touch "$f"; done

# AT captures. The compound echo is line 1 exactly as qcmd prints it; the shim
# on the X16 answers that line with a bare OK and no +QNWCFG payload.
cat > "$TMP/at_bare_ok.txt" <<'EOT'
AT+QNWCFG="lte_csi";+QNWCFG="lte_ulMCS";+QNWCFG="lte_dl_tx_mode";+QNWCFG="rrc_state"
OK
EOT
cat > "$TMP/at_mimo_only.txt" <<'EOT'
AT+QNWCFG="lte_csi";+QNWCFG="lte_ulMCS";+QNWCFG="lte_dl_tx_mode";+QNWCFG="rrc_state"
+QNWCFG: "lte_mimo_layers",1,2

OK
EOT
cat > "$TMP/at_csi.txt" <<'EOT'
AT+QNWCFG="lte_csi";+QNWCFG="lte_ulMCS";+QNWCFG="lte_dl_tx_mode";+QNWCFG="rrc_state"
+QNWCFG: "lte_csi",1,2,3,0
+QNWCFG: "lte_mimo_layers",1,2

OK
EOT

# =============================================================================
# 1. FAIL-SOFT — an absent store is today's behaviour, and today's failure code
# =============================================================================
out=$(run_lib "$MISSING" 'qm_phy_x16_at' 2>/dev/null); rc=$?
assert_eq "absent store: qm_phy_x16_at returns 2 (absent/unreadable)" "2" "$rc"
assert_eq "absent store: qm_phy_x16_at prints no object" "" "$out"

out=$(run_lib "$MISSING" 'qm_phy_x16_modemd' 2>/dev/null); rc=$?
assert_eq "absent store: qm_phy_x16_modemd returns 2" "2" "$rc"
assert_eq "absent store: qm_phy_x16_modemd prints no object" "" "$out"

# The factory entry point keeps returning non-zero on a box with no ubus, so the
# poller publishes nulls exactly as before this patch.
out=$(run_lib "$MISSING" 'qm_phy_modemd' 2>/dev/null); rc=$?
assert_eq "absent store and no ubus: qm_phy_modemd returns 2" "2" "$rc"
assert_eq "absent store and no ubus: qm_phy_modemd fabricates nothing" "" "$out"

out=$(run_lib "$MISSING" 'qm_phy_at LTE' 2>/dev/null); rc=$?
assert_eq "absent store and no AT: qm_phy_at returns 3, not a made-up object" "3" "$rc"
assert_eq "absent store and no AT: qm_phy_at prints nothing" "" "$out"

run_lib "$MISSING" 'qm_phy_available' >/dev/null 2>&1; rc=$?
assert_eq "absent store: qm_phy_available stays 1 (Tier 3 gate closed)" "1" "$rc"

# =============================================================================
# 2. FAIL-SOFT — a STALE store is not a reading
# =============================================================================
out=$(run_lib "$STALE" 'qm_phy_x16_at' 2>/dev/null); rc=$?
assert_eq "stale store (mtime 2020, TTL 30 s): qm_phy_x16_at returns 3" "3" "$rc"
assert_eq "stale store: qm_phy_x16_at publishes no stale value" "" "$out"

out=$(run_lib "$STALE" 'qm_phy_x16_modemd' 2>/dev/null); rc=$?
assert_eq "stale store: qm_phy_x16_modemd returns 3" "3" "$rc"
assert_eq "stale store: qm_phy_x16_modemd publishes no stale value" "" "$out"

run_lib "$STALE" 'qm_phy_available' >/dev/null 2>&1; rc=$?
assert_eq "stale store: qm_phy_available stays 1 (no Tier 3 on dead data)" "1" "$rc"

# What rejected it was the AGE and not the content: with the TTL widened past
# the file's age the same bytes are read, and they are the stale instant's
# numbers (CQI 10), not the live capture's (6).
out=$(QM_PHY_DEVINFO_TTL=999999999 run_lib "$STALE" 'qm_phy_x16_at' 2>/dev/null); rc=$?
assert_eq "TTL is what rejects the stale store (same file, TTL widened)" "0" "$rc"
assert_eq "widened TTL: the stale instant's own CQI is what comes back" \
    "10" "$(printf '%s' "$out" | "$JQ" -r '.lte.cqi' 2>/dev/null)"

# =============================================================================
# 3. FAIL-SOFT — an unreadable store is not a reading either
# =============================================================================
cp "$LIVE" "$TMP/unreadable.txt"
chmod 000 "$TMP/unreadable.txt"
UNREADABLE="$TMP/unreadable.txt"
if [ -r "$UNREADABLE" ]; then
    # root ignores the mode bits; a directory is the one path cat(1) cannot read.
    mkdir -p "$TMP/unreadable_dir"
    UNREADABLE="$TMP/unreadable_dir"
fi
out=$(run_lib "$UNREADABLE" 'qm_phy_x16_at' 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    ok "unreadable store: qm_phy_x16_at fails with no object, no zeros"
else
    bad "unreadable store: qm_phy_x16_at fails with no object, no zeros" \
        "rc=$rc, stdout=[$out]"
fi
out=$(run_lib "$UNREADABLE" 'qm_phy_modemd' 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    ok "unreadable store: qm_phy_modemd fails, so registered stays null"
else
    bad "unreadable store: qm_phy_modemd fails, so registered stays null" \
        "rc=$rc, stdout=[$out]"
fi

# =============================================================================
# 4. A FRESH store is a source — with no AT and no ubus at all
# =============================================================================
out=$(run_lib "$LIVE" 'qm_phy_at LTE' 2>/dev/null); rc=$?
assert_eq "fresh store with no usable AT: qm_phy_at succeeds from the store" "0" "$rc"
assert_eq "fresh store: lte.cqi is the capture's CQI" "6" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.cqi' 2>/dev/null)"
assert_eq "fresh store: lte.ri is the capture's lte_rank" "1" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.ri' 2>/dev/null)"
assert_eq "fresh store: nr.cqi is the capture's CQI_5G" "11" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.cqi' 2>/dev/null)"
assert_eq "fresh store: nr.ri is the capture's nr_rank" "2" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.ri' 2>/dev/null)"
assert_eq "fresh store: nr.ul_mcs is the capture's UL_MCS_5G" "19" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.ul_mcs' 2>/dev/null)"
# The capture has an EMPTY UL_MCS (no uplink grant at that instant) and an empty
# MIMO_STATUS. Empty is not 0: the AT-shaped object must carry null, and the
# layer count must not be invented from MIMO_STATUS — it comes from rank on the
# modemd side instead (section 6).
assert_eq "fresh store: empty UL_MCS is null, not 0" "null" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.ul_mcs' 2>/dev/null)"
assert_eq "fresh store: empty MIMO_STATUS never becomes a layer count" "null" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.mimo_layers' 2>/dev/null)"
assert_eq "fresh store: no PMI exists on this firmware, so null" "null" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.pmi' 2>/dev/null)"
assert_eq "fresh store: rrc.rat is derived from network_type_str 5G(NSA)" "NR" \
    "$(printf '%s' "$out" | "$JQ" -r '.rrc.rat' 2>/dev/null)"

run_lib "$LIVE" 'qm_phy_available' >/dev/null 2>&1; rc=$?
assert_eq "fresh store, no ubus: qm_phy_available is 0 (Tier 3 gate opens)" "0" "$rc"

# =============================================================================
# 5. RANGE GATES — the asymmetry is deliberate
# =============================================================================
# CQI and RI are 1-based on this firmware; the store writes 0 for "not
# reported", and a published CQI 0 would be a fabricated reading.
assert_eq "CQI:0 becomes null (CQI is 1..15)" "null" "$(at_f "$TMP/gate_cqi0.txt" '.lte.cqi')"
assert_eq "CQI_5G:0 becomes null (CQI is 1..15)" "null" "$(at_f "$TMP/gate_cqi5g0.txt" '.nr.cqi')"
assert_eq "CQI:16 (above the range) becomes null" "null" "$(at_f "$TMP/gate_cqi16.txt" '.lte.cqi')"
assert_eq "lte_rank:0 becomes null (RI is 1..8)" "null" "$(at_f "$TMP/gate_rank0.txt" '.lte.ri')"
# 0 IS a real MCS index, so it must survive — the capture has DL_MCS_5G:0.
assert_eq "DL_MCS_5G:0 stays 0 (0 is a real MCS index)" "0" "$(at_f "$LIVE" '.nr.dl_mcs')"
assert_eq "CQI:0 does not disturb the MCS in the same read" "0" "$(at_f "$TMP/gate_cqi0.txt" '.nr.dl_mcs')"
assert_eq "lte_rank:0 does not disturb the CQI in the same read" "6" "$(at_f "$TMP/gate_rank0.txt" '.lte.cqi')"
# And an empty store value stays null on both sides of the asymmetry.
assert_eq "empty CQI is null, not 0" "null" "$(at_f "$PARTIAL" '.lte.cqi')"
assert_eq "empty CQI_5G is null, not 0" "null" "$(at_f "$PARTIAL" '.nr.cqi')"
assert_eq "empty lte_rank is null, not 0" "null" "$(at_f "$PARTIAL" '.lte.ri')"
assert_eq "empty UL_MCS_5G is null, not 0" "null" "$(at_f "$PARTIAL" '.nr.ul_mcs')"
assert_eq "DL_MCS_5G:0 in an otherwise empty store is still 0" "0" "$(at_f "$PARTIAL" '.nr.dl_mcs')"

# =============================================================================
# 6. MERGE, NOT SWITCH — the two halves answer for different fields
# =============================================================================
# The X16 shim answers the QNWCFG compound with a bare OK. The store's fields
# must survive that: an "is the AT parse non-empty?" test would publish the
# AT half's all-null object and blank CQI/RI/MCS again.
out=$(FAKE_QCMD_FILE="$TMP/at_bare_ok.txt" run_lib "$LIVE" 'qm_phy_at LTE' 2>/dev/null); rc=$?
assert_eq "AT half answering a bare OK: qm_phy_at still succeeds" "0" "$rc"
assert_eq "AT half answering a bare OK does not erase the store's CQI" "6" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.cqi' 2>/dev/null)"
assert_eq "AT half answering a bare OK does not erase the store's NR UL MCS" "19" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.ul_mcs' 2>/dev/null)"

# The regression this replaced: the AT half starts yielding lte_mimo_layers, and
# the result must then contain BOTH that and the store's CQI/RI/MCS.
out=$(FAKE_QCMD_FILE="$TMP/at_mimo_only.txt" run_lib "$LIVE" 'qm_phy_at LTE' 2>/dev/null); rc=$?
assert_eq "AT half yields layers only: qm_phy_at succeeds" "0" "$rc"
assert_eq "AT half yields layers only: the AT field survives" "2" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.mimo_layers' 2>/dev/null)"
assert_eq "AT half yields layers only: the store's CQI survives with it" "6" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.cqi' 2>/dev/null)"
assert_eq "AT half yields layers only: the store's RI survives with it" "1" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.ri' 2>/dev/null)"
assert_eq "AT half yields layers only: the store's NR MCS survives with it" "19" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.ul_mcs' 2>/dev/null)"

# Precedence when both halves report the same field: the live AT figure wins,
# field by field, and the fields only the store has are untouched.
out=$(FAKE_QCMD_FILE="$TMP/at_csi.txt" run_lib "$LIVE" 'qm_phy_at LTE' 2>/dev/null)
assert_eq "both halves report CQI: the AT reading wins" "3" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.cqi' 2>/dev/null)"
assert_eq "both halves report RI: the AT reading wins" "2" \
    "$(printf '%s' "$out" | "$JQ" -r '.lte.ri' 2>/dev/null)"
assert_eq "AT half silent on NR MCS: the store's value is kept" "19" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.ul_mcs' 2>/dev/null)"
assert_eq "AT half silent on NR CQI: the store's value is kept" "11" \
    "$(printf '%s' "$out" | "$JQ" -r '.nr.cqi' 2>/dev/null)"

# =============================================================================
# 7. registered — connected only when both keys say so, null when unknown
# =============================================================================
assert_eq "sim_status:1 plus network_type_str: registered is true" "true" \
    "$(md_f "$LIVE" '.registered')"
# Missing sim_status is not evidence of "not registered": null, never a false.
assert_eq "sim_status absent: registered is null, not a fabricated false" "null" \
    "$(md_f "$TMP/no_sim_status.txt" '.registered')"
# A present sim_status:0 IS evidence: the SIM is known and not attached, which
# is the one case that may publish `false` — the Registration card renders null
# as a dash and false as "Not registered" (registration-card.tsx:58-68), so a
# SIM that is present and detached is the case where the dash is wrong. The
# patch as shipped falls through to null here; this assertion is the contract,
# and it fails until that fallthrough publishes false.
assert_eq "sim_status:0 with a network type: registered is false" "false" \
    "$(md_f "$TMP/gate_sim0.txt" '.registered')"

# =============================================================================
# 8. modemd-shaped object — lte_mimo_layers comes from lte_rank
# =============================================================================
# QM_PHY_SNAPSHOT_JQ takes mimo_layers from modemd's lte_rank/nr_rank, and the
# AT half's layer count can be lost to the per-call timeout on a busy cycle, so
# this is the reliable path for the MIMO Layers row.
assert_eq "modemd object: lte_mimo_layers is lte_rank" "1" "$(md_f "$LIVE" '.lte_mimo_layers')"
assert_eq "modemd object: nr_mimo_layers is nr_rank" "2" "$(md_f "$LIVE" '.nr_mimo_layers')"
assert_eq "modemd object: empty lte_rank gives null, not 0" "null" \
    "$(md_f "$PARTIAL" '.lte_mimo_layers')"

# =============================================================================
# 9. What the API actually publishes
# =============================================================================
snap_of() {  # snap_of <store>  -> qm_phy_snapshot over both halves from the store
    run_lib "$1" 'md=$(qm_phy_x16_modemd); at=$(qm_phy_x16_at); qm_phy_snapshot "$md" "$at" "{}"'
}
snap=$(snap_of "$LIVE")
assert_eq "snapshot: lte.cqi reaches the served object" "6" \
    "$(printf '%s' "$snap" | "$JQ" -r '.lte.cqi' 2>/dev/null)"
assert_eq "snapshot: nr.dl_mcs reaches the served object as 0, not null" "0" \
    "$(printf '%s' "$snap" | "$JQ" -r '.nr.dl_mcs' 2>/dev/null)"
assert_eq "snapshot: lte.mimo_layers is filled from the store's rank" "1" \
    "$(printf '%s' "$snap" | "$JQ" -r '.lte.mimo_layers' 2>/dev/null)"
assert_eq "snapshot: registered is true, so the card can say Registered" "true" \
    "$(printf '%s' "$snap" | "$JQ" -r '.registered' 2>/dev/null)"

snap=$(snap_of "$TMP/no_sim_status.txt")
assert_eq "snapshot: registered is null when the store has no sim_status" "null" \
    "$(printf '%s' "$snap" | "$JQ" -r '.registered' 2>/dev/null)"

snap=$(snap_of "$PARTIAL")
assert_eq "snapshot: an empty store value stays null end to end" "null" \
    "$(printf '%s' "$snap" | "$JQ" -r '.lte.cqi' 2>/dev/null)"
assert_eq "snapshot: a real 0 MCS stays 0 end to end" "0" \
    "$(printf '%s' "$snap" | "$JQ" -r '.nr.dl_mcs' 2>/dev/null)"

if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %s assertions\n' "$PASS"
else
    printf 'FAIL  %s passed, %s failed\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
