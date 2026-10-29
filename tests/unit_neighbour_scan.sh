#!/bin/sh
# Host-side regression tests for the SIM8260E native neighbour-cell path.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHIM="$HERE/../deploy-x16/atcli_smd11"
SCANNER="$HERE/../deploy-x16/qmanager_neighbour_scanner"
FAKE="$HERE/fake-atcmd"
FIXTURE="$HERE/fixtures/neighbour_qeng.txt"
TMP="${TMPDIR:-/tmp}/neighbour-scan-test.$$"
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# Verify exact native command passthrough through the production dialect shim.
out=$(FAKE_NEIGHBOUR_FILE="$FIXTURE" ATC="$FAKE" \
    QM_CPSI_CACHE="$TMP/cpsi" QM_AT_CACHE_DIR="$TMP/atcache" \
    QM_AT_BLACKLIST="$TMP/blacklist" \
    sh "$SHIM" 'AT+QENG="neighbourcell"')
assert_eq "shim preserves native neighbour response" \
    "12" "$(printf '%s\n' "$out" | grep -c '^+QENG:.*neighbourcell')"
assert_eq "shim does not substitute serving cell" \
    "0" "$(printf '%s\n' "$out" | grep -c '^+QENG:.*servingcell')"

# A small deterministic qcmd substitute lets the real scanner run with no modem.
cat > "$TMP/bin/qcmd" <<'QCMD'
#!/bin/sh
case "$1" in
  'AT+QENG="neighbourcell"')
    if [ "${FAKE_SERVING_ONLY:-0}" = 1 ]; then
      printf '+QENG: "servingcell","CONNECT","LTE","FDD",410,03,CA52865,256,1312,3,5,5,29DD,-94,-7,-76,18\n\nOK\n'
    else
      cat "$FAKE_NEIGHBOUR_FILE"
      printf '\nOK\n'
    fi
    ;;
  'AT+QNWCFG="nr5g_meas_info",1'|'AT+QNWCFG="nr5g_meas_info"')
    # LTE-only SIMCom firmware does not implement Quectel NR measurement
    # reporting. The shim intentionally answers a successful empty response.
    if [ "${FAKE_NR_FAIL:-0}" = 1 ]; then
      echo 'ERROR: command_failed' >&2
      exit 1
    fi
    printf 'OK\n'
    ;;
  *) echo "ERROR: unexpected command $1" >&2; exit 1 ;;
esac
QCMD
chmod +x "$TMP/bin/qcmd"

run_scanner() {
    rm -f "$TMP"/result.json "$TMP"/error "$TMP"/pid "$TMP"/parsed "$TMP"/*_err
    env PATH="$TMP/bin:$PATH" QCMD_BIN=qcmd JQ_BIN="$(command -v jq)" \
      FAKE_NEIGHBOUR_FILE="$FIXTURE" FAKE_SERVING_ONLY="${FAKE_SERVING_ONLY:-0}" \
      FAKE_NR_FAIL="${FAKE_NR_FAIL:-0}" \
      NEIGHBOUR_SCAN_PID_FILE="$TMP/pid" \
      NEIGHBOUR_SCAN_RESULT_FILE="$TMP/result.json" \
      NEIGHBOUR_SCAN_ERROR_FILE="$TMP/error" \
      NEIGHBOUR_SCAN_PARSED_FILE="$TMP/parsed" \
      NEIGHBOUR_SCAN_LTE_ERR_FILE="$TMP/lte_err" \
      NEIGHBOUR_SCAN_NR_ERR_FILE="$TMP/nr_err" \
      NEIGHBOUR_NR_PAUSE=0 \
      sh "$SCANNER"
}

# Real captured modem data: 12 LTE neighbours, with metrics normalized from
# SIM8260E tenths to integer dBm/dB used by the UI.
run_scanner
assert_eq "captured neighbours yield 12 rows" "12" "$(jq 'length' "$TMP/result.json")"
assert_eq "frequency field maps EARFCN" "1312" "$(jq -r '.[0].frequency' "$TMP/result.json")"
assert_eq "PCI field maps PCID" "256" "$(jq -r '.[0].pci' "$TMP/result.json")"
assert_eq "signalStrength is RSRP in dBm" "-93" "$(jq -r '.[0].signalStrength' "$TMP/result.json")"
assert_eq "RSRQ is rounded from tenths" "-7" "$(jq -r '.[0].rsrq' "$TMP/result.json")"
assert_eq "RSSI is normalized from tenths" "-66" "$(jq -r '.[0].rssi' "$TMP/result.json")"
assert_eq "intra/inter classification preserved" "intra inter" \
  "$(jq -r '[.[0].cellType, .[3].cellType] | join(" ")' "$TMP/result.json")"
[ ! -s "$TMP/error" ] && ok "successful scan writes no error" || bad "successful scan writes no error" "$(cat "$TMP/error")"

# Servingcell must never be mistaken for a neighbour row. On LTE-only
# firmware an empty NR response is a successful no-data leg, not a scan error.
FAKE_SERVING_ONLY=1 run_scanner
assert_eq "servingcell-only response gives zero fake rows" "0" "$(jq 'length' "$TMP/result.json")"
[ ! -s "$TMP/error" ] && ok "LTE-only empty scan completes without error" || bad "LTE-only empty scan completes without error" "$(cat "$TMP/error")"

# If NR reporting itself fails, real LTE rows remain a valid partial result.
FAKE_SERVING_ONLY=0 FAKE_NR_FAIL=1 run_scanner
assert_eq "LTE data survives unsupported NR read" "12" "$(jq 'length' "$TMP/result.json")"
[ ! -s "$TMP/error" ] && ok "partial LTE result remains usable" || bad "partial LTE result remains usable" "$(cat "$TMP/error")"

echo "unit_neighbour_scan: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
