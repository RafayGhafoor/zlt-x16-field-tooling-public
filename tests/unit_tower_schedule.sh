#!/bin/sh
# SIMCom LTE lock translation + tower-schedule validation tests. No device writes.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHIM="$HERE/../deploy-x16/atcli_smd11"
FAKE="$HERE/fake-atcmd"
SCHEDULE="/tmp/qm/scripts/www/cgi-bin/quecmanager/tower/schedule.sh"
TMP="${TMPDIR:-/tmp}/tower-schedule-test.$$"
mkdir -p "$TMP/bin" "$TMP/lib"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] lacks [$2]" ;; esac; }

# Native CCELLCFG reads are verified on the SIM8260E. Simulate their captured
# responses and prove the QNWLOCK-shaped layer parses the status correctly.
# CCELLCFG answers are changed between assertions in this file (locked / not
# locked), so the snapshot cache is cleared per call: what is under test here is
# the QNWLOCK translation, not caching.
run_shim() {
    rm -rf "$TMP/atcache"
    FAKE_CCELLCFG="${FAKE_CCELLCFG:-0,0}" \
    FAKE_CALL_LOG="$TMP/at-calls" \
    QM_CPSI_CACHE="$TMP/cpsi" QM_AT_CACHE_DIR="$TMP/atcache" \
    QM_AT_BLACKLIST="$TMP/blacklist" \
    ATC="$FAKE" sh "$SHIM" "$1"
}
: > "$TMP/at-calls"
out=$(run_shim 'AT+QNWLOCK="common/4g"')
assert_contains "native disabled state maps to QNWLOCK unlocked" \
  '+QNWLOCK: "common/4g",0' "$out"
assert_eq "read state calls only the native read command" \
  'AT+CCELLCFG?' "$(cat "$TMP/at-calls")"

: > "$TMP/at-calls"
out=$(FAKE_CCELLCFG=256,1312 run_shim 'AT+QNWLOCK="common/4g"')
assert_contains "native PCI,EARFCN order maps to QNWLOCK EARFCN,PCI" \
  '+QNWLOCK: "common/4g",1,1312,256' "$out"

: > "$TMP/at-calls"
out=$(run_shim 'AT+QNWLOCK="common/4g",1,1312,256')
assert_contains "one LTE cell lock receives modem OK" "OK" "$out"
assert_eq "LTE lock command reverses args to native PCI,EARFCN order" \
  'AT+CCELLCFG=1,256,1312' "$(cat "$TMP/at-calls")"

: > "$TMP/at-calls"
out=$(run_shim 'AT+QNWLOCK="common/4g",0')
assert_contains "LTE unlock receives modem OK" "OK" "$out"
assert_eq "LTE unlock maps to verified native clear command" \
  'AT+CCELLCFG=0' "$(cat "$TMP/at-calls")"

: > "$TMP/at-calls"
out=$(run_shim 'AT+QNWLOCK="common/4g",2,1312,256,150,502')
assert_eq "multi-cell writes are refused rather than approximated" "ERROR" "$(printf '%s\n' "$out" | head -1)"
assert_eq "refused multi-cell write never contacts modem" "0" "$(wc -l < "$TMP/at-calls" | tr -d ' ')"

: > "$TMP/at-calls"
out=$(run_shim 'AT+QNWLOCK="common/5g"')
assert_eq "unverified NR-SA lock query is refused" "ERROR" "$(printf '%s\n' "$out" | head -1)"
assert_eq "NR-SA query never contacts modem" "0" "$(wc -l < "$TMP/at-calls" | tr -d ' ')"

# CGI shim for the real tower schedule endpoint. It records decisions locally
# and never calls systemd or a modem.
cat > "$TMP/lib/cgi_base.sh" <<'CGI'
qlog_init() { :; }
qlog_info() { :; }
qlog_error() { :; }
cgi_headers() { :; }
cgi_handle_options() { :; }
cgi_read_post() { :; }
cgi_error() { jq -cn --arg error "$1" --arg detail "$2" '{success:false,error:$error,detail:$detail}'; }
CGI
cat > "$TMP/lib/tower_lock_mgr.sh" <<'LIB'
tower_config_init() { :; }
tower_config_get() {
    case "$1" in
      '.lte.cells | map(select(. != null)) | length') printf '%s' "${FAKE_HAS_LTE:-0}" ;;
      '.nr_sa.pci') printf '%s' "${FAKE_NR_PCI:-}" ;;
      '.nr_sa.arfcn') printf '%s' "${FAKE_NR_ARFCN:-}" ;;
      *) printf '' ;;
    esac
}
tower_config_update_schedule() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$FAKE_SCHEDULE_UPDATES"; }
LIB
cat > "$TMP/lib/arm" <<'ARM'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_ARM_CALLS"
printf '{"success":true,"armed":true}\n'
ARM
cat > "$TMP/bin/qcmd" <<'QCMD'
#!/bin/sh
[ "$1" = 'AT+CGMM' ] && { printf 'SIMCOM_SIM8260E\n\nOK\n'; exit 0; }
printf 'ERROR\n' >&2
exit 1
QCMD
cat > "$TMP/bin/sudo" <<'SUDO'
#!/bin/sh
[ "${1:-}" = -n ] && shift
exec "$@"
SUDO
chmod +x "$TMP/lib/arm" "$TMP/bin/qcmd" "$TMP/bin/sudo"

run_schedule() {
    rm -f "$TMP/updates" "$TMP/arm-calls"
    REQUEST_METHOD=POST POST_DATA="$1" CONTENT_LENGTH=0 \
      QM_CGI_BASE="$TMP/lib/cgi_base.sh" \
      QM_TOWER_LOCK_LIB="$TMP/lib/tower_lock_mgr.sh" \
      QM_TOWER_SCHEDULE_ARM="$TMP/lib/arm" \
      FAKE_SCHEDULE_UPDATES="$TMP/updates" FAKE_ARM_CALLS="$TMP/arm-calls" \
      PATH="$TMP/bin:/usr/bin:/bin" FAKE_HAS_LTE="${FAKE_HAS_LTE:-0}" \
      FAKE_NR_PCI="${FAKE_NR_PCI:-}" FAKE_NR_ARFCN="${FAKE_NR_ARFCN:-}" \
      sh "$SCHEDULE"
}

body=$(run_schedule '{"start_time":"08:00","end_time":"22:00","days":[1]}')
assert_eq "missing enabled field is rejected" "no_enabled" "$(printf '%s' "$body" | jq -r '.error')"
body=$(run_schedule '{"enabled":true,"start_time":"8:00","end_time":"22:00","days":[1]}')
assert_eq "invalid HH:MM is rejected" "invalid_start_time" "$(printf '%s' "$body" | jq -r '.error')"
body=$(run_schedule '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[]}')
assert_eq "empty day selection is rejected" "no_days" "$(printf '%s' "$body" | jq -r '.error')"
body=$(run_schedule '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[7]}')
assert_eq "day outside 0-6 is rejected" "invalid_day" "$(printf '%s' "$body" | jq -r '.error')"
body=$(run_schedule '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1]}')
assert_eq "enabling without a saved lock target is rejected" "no_lock_targets" "$(printf '%s' "$body" | jq -r '.error')"
if [ -e "$TMP/arm-calls" ]; then actual=true; else actual=false; fi
assert_eq "rejected schedule does not arm timers" "false" "$actual"

body=$(FAKE_NR_PCI=256 FAKE_NR_ARFCN=1312 run_schedule '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1]}')
assert_eq "unverified NR-SA lock schedules are explicitly refused" "unsupported_nr_lock" "$(printf '%s' "$body" | jq -r '.error')"
if [ -e "$TMP/arm-calls" ]; then actual=true; else actual=false; fi
assert_eq "NR-SA refusal does not arm timers" "false" "$actual"

body=$(FAKE_HAS_LTE=1 run_schedule '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1,2,3,4,5]}')
assert_eq "valid LTE schedule returns success" "true" "$(printf '%s' "$body" | jq -r '.success')"
assert_eq "valid schedule reports armed" "true" "$(printf '%s' "$body" | jq -r '.armed')"
assert_eq "apply and clear timer pair receives schedule" "install 08:00 22:00 1,2,3,4,5" "$(cat "$TMP/arm-calls")"
if grep -Fq 'true|08:00|22:00|[1,2,3,4,5]' "$TMP/updates"; then actual=true; else actual=false; fi
assert_eq "config schedule persists the validated days" "true" "$actual"

body=$(FAKE_HAS_LTE=0 run_schedule '{"enabled":false}')
assert_eq "disable does not require lock targets" "true" "$(printf '%s' "$body" | jq -r '.success')"
assert_eq "disable tears down timer pair" "teardown" "$(cat "$TMP/arm-calls")"

if grep -q 'qmanager_tower_schedule_arm' "$HERE/../deploy-x16/start_qmanager"; then actual=true; else actual=false; fi
assert_eq "boot hook restores saved timers after late /etc mount" "true" "$actual"
if [ -f "$HERE/../deploy-x16/qmanager-tower-schedule-apply.service" ] && \
   [ -f "$HERE/../deploy-x16/qmanager-tower-schedule-clear.service" ]; then actual=true; else actual=false; fi
assert_eq "installer carries both static timer services" "true" "$actual"
if grep -q 'qmanager-tower-schedule-apply.service' "$HERE/../deploy-x16/install.sh"; then actual=true; else actual=false; fi
assert_eq "installer deploys tower schedule units" "true" "$actual"


# =============================================================================
# Multi-cell refusal must explain the one-cell limit
# =============================================================================
# The shim refuses >1 LTE cell by design. Line 1 stays "ERROR" so the failure
# contract other consumers match on is unchanged; the human reason goes on
# line 2, because "Modem rejected tower lock command" sends the operator to the
# radio when the real problem is a slot this device cannot use.
: > "$TMP/at-calls"
out=$(run_shim 'AT+QNWLOCK="common/4g",2,1312,256,150,502')
assert_eq "multi-cell refusal keeps ERROR on line 1" "ERROR" "$(printf '%s\n' "$out" | head -1)"
assert_contains "multi-cell refusal explains the one-cell limit" \
  "one LTE cell" "$(printf '%s\n' "$out" | sed -n '2p')"
assert_eq "multi-cell refusal never contacts modem" "0" "$(wc -l < "$TMP/at-calls" | tr -d ' ')"

# =============================================================================
# Stale lock reconciliation — tower_reconcile_lte_config()
# =============================================================================
# The LTE lock is not persistent: after a reboot the modem is unlocked while the
# config still says enabled=true, which is exactly the state found on the X16 on
# 2026-10-26. Clearing on anything less than an OBSERVED "unlocked" would erase a
# lock that is really in force, so each guard is pinned here.
LIB="/tmp/qm/scripts/usr/lib/qmanager/tower_lock_mgr.sh"
REC="$TMP/reconcile"
mkdir -p "$REC"
CFG="$REC/config.json"
INFL="$REC/inflight"

cat > "$REC/run.sh" <<'RECON'
#!/bin/sh
qlog_info() { printf 'INFO %s\n' "$*" >> "$RECON_LOG"; }
qlog_warn() { :; }
qlog_error() { printf 'ERR %s\n' "$*" >> "$RECON_LOG"; }
. "$RECON_LIB"
TOWER_CONFIG_FILE="$RECON_CFG"
TOWER_WRITE_INFLIGHT="$RECON_INFLIGHT"
tower_reconcile_lte_config "$1" "$2" "$3"
printf 'rc=%s\n' "$?"
printf 'enabled=%s\n' "$(jq -r '.lte.enabled' "$TOWER_CONFIG_FILE" 2>/dev/null)"
printf 'cells=%s\n' "$(jq -c '.lte.cells' "$TOWER_CONFIG_FILE" 2>/dev/null)"
RECON

write_cfg() {
    printf '{"lte":{"enabled":%s,"cells":[{"earfcn":250,"pci":104},null,null]},"nr_sa":{"enabled":false,"pci":null,"arfcn":null,"scs":null,"band":null},"persist":false,"failover":{"enabled":false,"threshold":20},"schedule":{"enabled":false,"start_time":"08:00","end_time":"22:00","days":[1,2,3,4,5]}}\n' "$1" > "$CFG"
}
recon() {
    RECON_LIB="$LIB" RECON_CFG="$CFG" RECON_INFLIGHT="$INFL" RECON_LOG="$REC/log" \
      sh "$REC/run.sh" "$1" "$2" "$3"
}

rm -f "$INFL"; write_cfg true
out=$(recon false false false)
assert_contains "unreadable modem does NOT count as unlocked" "enabled=true" "$out"
assert_contains "unreadable modem takes no action" "rc=1" "$out"

write_cfg true
out=$(recon true true false)
assert_contains "a lock still in force is not cleared" "enabled=true" "$out"

write_cfg true
out=$(recon true false true)
assert_contains "persist=true keeps the saved intent" "enabled=true" "$out"
assert_contains "persist=true takes no action" "rc=1" "$out"

write_cfg true
printf '%s' "$(( $(date +%s) + 30 ))" > "$INFL"
out=$(recon true false false)
assert_contains "a tower write in flight is not mistaken for a lost lock" "enabled=true" "$out"
rm -f "$INFL"

write_cfg true
out=$(recon true false false)
assert_contains "stale lock is cleared when the modem reports unlocked" "enabled=false" "$out"
assert_contains "cleared lock drops its cell targets" "cells=[null,null,null]" "$out"
assert_contains "clearing reports action taken" "rc=0" "$out"

write_cfg false
out=$(recon true false false)
assert_contains "an already-clear config is left alone" "rc=1" "$out"

echo "unit_tower_schedule: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
