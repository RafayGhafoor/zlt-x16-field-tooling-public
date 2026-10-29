#!/bin/sh
# History archive regression: X16 has Tier-1 cell data even without ubus/modemd.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
QM_SRC=${QM_SRC:-/tmp/qm}
PHY="$QM_SRC/scripts/usr/lib/qmanager/phy_metrics.sh"
CGI="$QM_SRC/scripts/www/cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh"
TMP="${TMPDIR:-/tmp}/history-archive-test.$$"
mkdir -p "$TMP/lib" "$TMP/archive"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

[ -f "$PHY" ] || { echo "FATAL: QManager source missing at $PHY" >&2; exit 2; }
[ -f "$CGI" ] || { echo "FATAL: QManager source missing at $CGI" >&2; exit 2; }

QM_PHY_JQ=$(command -v jq)
QM_PHY_ARCHIVE_DIR="$TMP/archive"
. "$PHY"

if qm_phy_archive_has_source '{}' '{}' '{"lte_rsrp":null,"lte_pci":null,"lte_earfcn":null,"nr_rsrp":null,"nr_pci":null,"nr_arfcn":null}'; then actual=true; else actual=false; fi
assert_eq "all-null context with no PHY reads is not archived" "false" "$actual"
if qm_phy_archive_has_source '{}' '{}' '{"rat":"LTE","lte_rsrp":-94,"lte_pci":256,"lte_earfcn":1312}'; then actual=true; else actual=false; fi
assert_eq "real Tier-1 LTE context is archiveable without QMI" "true" "$actual"
if qm_phy_archive_has_source '{"registered":true}' '{}' '{}'; then actual=true; else actual=false; fi
assert_eq "a successful PHY source remains archiveable" "true" "$actual"

# Write one synthetic but representative row through the production writer.
ctx='{"rat":"LTE","registered":null,"lte_rsrp":-94,"lte_rsrq":-7,"lte_rssi":-80,"lte_sinr":14,"lte_pci":256,"lte_earfcn":1312,"lte_band":"B3","lte_bw":20,"lte_cellid":212150373,"lte_tac":10717,"nr_avail":0,"cpu_pct":null,"mem_pct":42,"dl_bps":5000,"ul_bps":1000,"ca_cc":2,"nrca_cc":0,"bw_mhz":35,"bands":"B3+B1"}'
snap=$(qm_phy_snapshot '{}' '{}' "$ctx")
# macOS date does not implement GNU date -d; prune is best-effort and the
# production poller does not run with errexit. Match that runtime behavior here.
set +e
qm_phy_archive_row "$snap" 45 2 "$ctx"
archive_rc=$?
set -e
assert_eq "context-only archive write succeeds without a QMI reader" "0" "$archive_rc"
archive=$(find "$TMP/archive" -type f -name '*.csv' | head -1)
[ -s "$archive" ] && ok "production writer creates a day archive row" || bad "production writer creates a day archive row" "no CSV written"
assert_eq "row has schema header and one sample" "2" "$(wc -l < "$archive" | tr -d ' ')"

cat > "$TMP/lib/cgi_base.sh" <<'CGI'
qlog_init() { :; }
qlog_debug() { :; }
qlog_info() { :; }
qlog_warn() { :; }
qlog_error() { :; }
cgi_headers() { :; }
cgi_handle_options() { :; }
CGI
cat > "$TMP/status.json" <<'STATUS'
{"network":{"type":"LTE"},"phy":{"lte":{"rsrp":-94,"rsrq":-7,"rssi":-80,"sinr":14},"nr":{"rsrp":null,"rsrq":null,"sinr":null},"registered":null}}
STATUS
body=$(REQUEST_METHOD=GET QUERY_STRING='view=cells&range=24h' \
    QM_CGI_BASE="$TMP/lib/cgi_base.sh" QM_STATUS_FILE="$TMP/status.json" \
    QM_PHY_ARCHIVE_DIR="$TMP/archive" sh "$CGI")
assert_eq "history endpoint returns success for archived rows" "true" "$(printf '%s' "$body" | jq -r '.success')"
assert_eq "cell history window includes the written sample" "1" "$(printf '%s' "$body" | jq -r '.window.samples')"
assert_eq "signal history carries the real LTE RSRP" "-94" "$(printf '%s' "$body" | jq -r '.series.rsrp[0].v | tonumber | floor')"
assert_eq "cell timeline carries serving PCI" "256" "$(printf '%s' "$body" | jq -r '.cells.timeline[0].lte_pci')"
assert_eq "LTE-only history records measured NR unavailable" "0" "$(printf '%s' "$body" | jq -r '.cells.availability[0].up')"

echo "unit_history_archive: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
