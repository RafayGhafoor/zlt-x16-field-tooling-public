#!/bin/sh
# =============================================================================
# tests/unit_qmi_probe_text.sh — the probe's qmicli-shaped reads must parse alike
# =============================================================================
# qm_qmi_neighbours and qm_qmi_signal run at 1 Hz, so they are the one place the
# backend choice shows up as CPU. `qmi-probe cells-text` / `signal-text` print the
# SAME lines qmicli prints, so one awk serves both. That only works while the two
# shapes agree, which is exactly what this asserts — a drift here would silently
# change what the Live view shows (or blank it), and nothing else would notice.
#
# The fixtures are real: the qmicli one is a capture from this unit's modem, the
# probe one is what the probe printed for the same call minutes later. Values move
# (RSRP drifts), so identity is asserted on the identity fields — serving PCI,
# EARFCN, cell counts, type tags — not on measurements.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/../qmanager/scripts/usr/lib/qmanager/qmi_read.sh"
[ -f "$LIB" ] || LIB="${QM_SRC:-/tmp/qm}/scripts/usr/lib/qmanager/qmi_read.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }

[ -r "$LIB" ] || { echo "FATAL: qmi_read.sh not found ($LIB)" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qmxtext.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- fixture 1: qmicli --nas-get-cell-location-info (real capture) ------------
cat > "$TMP/cells-qmicli.txt" <<'FIX'
[qrtr://3] Successfully got cell location info
Intrafrequency LTE Info
	UE In Idle: 'no'
	PLMN: '41003'
	Tracking Area Code: '10717'
	Global Cell ID: '212150373'
	EUTRA Absolute RF Channel Number: '1312' (E-UTRA band 3: 1800+)
	Serving Cell ID: '256'
	Cell [0]:
		Physical Cell ID: '256'
		RSRQ: '-11.8' dB
		RSRP: '-73.7' dBm
		RSSI: '-41.6' dBm
	Cell [1]:
		Physical Cell ID: '318'
		RSRQ: '-17.8' dB
		RSRP: '-79.3' dBm
		RSSI: '-52.5' dBm
Interfrequency LTE Info
	UE In Idle: 'no'
	Frequency [0]:
		EUTRA Absolute RF Channel Number: '150' (E-UTRA band 1: 2100)
		Selection RX Level Low Threshold: '0'
		Cell [0]:
			Physical Cell ID: '502'
			RSRQ: '-10.2' dB
			RSRP: '-76.5' dBm
			RSSI: '-47.3' dBm
FIX

# --- fixture 2: qmi-probe cells-text (real output, same call) -----------------
cat > "$TMP/cells-probe.txt" <<'FIX'
[qrtr] Successfully got cell location info
Intrafrequency LTE Info
	Serving Cell ID: '256'
	EUTRA Absolute RF Channel Number: '1312'
	Cell [0]:
		Physical Cell ID: '256'
		RSRQ: '-11.2' dB
		RSRP: '-73.6' dBm
		RSSI: '-42.2' dBm
	Cell [1]:
		Physical Cell ID: '318'
		RSRQ: '-17.2' dB
		RSRP: '-78.6' dBm
		RSSI: '-52.3' dBm
Interfrequency LTE Info
	Frequency [0]:
		EUTRA Absolute RF Channel Number: '150'
		Cell [0]:
			Physical Cell ID: '502'
			RSRQ: '-9.5' dB
			RSRP: '-76.9' dBm
			RSSI: '-50.3' dBm
FIX

awk_parse() { sh -c ". \"$LIB\" 2>/dev/null; awk \"\$_QM_QMI_$1_AWK\"" < "$2"; }

a=$(awk_parse NEIGHBOURS "$TMP/cells-qmicli.txt"); ra=$?
b=$(awk_parse NEIGHBOURS "$TMP/cells-probe.txt");  rb=$?

eq "qmicli cells fixture parses (rc 0)" "0" "$ra"
eq "probe cells fixture parses (rc 0)"  "0" "$rb"
[ -n "$a" ] && [ -n "$b" ] && ok "both produce JSON" || bad "both produce JSON" "one was empty"

# identities must match; measurements may drift between the two captures
for probe_js in "$a" "$b"; do
    case "$probe_js" in
        *'"serving":{"pci":"256","earfcn":"1312"'*) : ;;
        *) bad "both name the same serving cell (pci 256 / earfcn 1312)" "$probe_js" ;;
    esac
done
case "$a$b" in
    *'"serving":true'*'"serving":true'*) ok "both mark a serving row" ;;
    *) bad "both mark a serving row" "a=$a b=$b" ;;
esac
eq "both find the same number of cells" \
   "$(printf '%s' "$a" | tr ',' '\n' | grep -c '"pci"')" \
   "$(printf '%s' "$b" | tr ',' '\n' | grep -c '"pci"')"
eq "both tag the inter-frequency cell as inter" \
   "$(printf '%s' "$b" | tr ',' '\n' | grep -c '"type":"inter"')" \
   "$(printf '%s' "$a" | tr ',' '\n' | grep -c '"type":"inter"')"

# --- signal: both shapes must yield the same LTE numbers and nulls for absent 5G
printf "[qrtr://3] Successfully got signal info\nLTE:\n\tRSSI: '-42 dBm'\n\tRSRQ: '-10 dB'\n\tRSRP: '-74 dBm'\n\tSNR: '3.4 dB'\n5G:\n\tRSRP: 'n/a'\n\tSNR: 'n/a'\n\tRSRQ: 'n/a'\n" > "$TMP/sig-qmicli.txt"
printf "[qrtr] Successfully got signal info\nLTE:\n\tRSSI: '-42 dBm'\n\tRSRQ: '-10 dB'\n\tRSRP: '-74 dBm'\n\tSNR: '3.4 dB'\n5G:\n\tRSRP: 'n/a'\n\tSNR: 'n/a'\n\tRSRQ: 'n/a'\n" > "$TMP/sig-probe.txt"
sa=$(awk_parse SIGNAL "$TMP/sig-qmicli.txt")
sb=$(awk_parse SIGNAL "$TMP/sig-probe.txt")
eq "signal parses identically from both shapes" "$sa" "$sb"
contains "absent 5G becomes nulls, not zeros" '"nr":{"rsrp":null,"rsrq":null,"snr":null}' "$sb"

# --- registration: reg-text must satisfy the same parser qmicli feeds --------
printf "[qrtr://3] Successfully got serving system:\n\tRegistration state: 'registered'\n\tCurrent PLMN:\n\t\tMCC: '410'\n\t\tMNC: '3'\n\t\tDescription: 'Onic'\n" > "$TMP/reg-qmicli.txt"
printf "[qrtr] Successfully got serving system:\n\tRegistration state: 'registered'\n\tCS: 'attached'\n\tPS: 'attached'\n\tSelected network: '3gpp'\n\tRadio interfaces: '1'\n\t\t[0]: 'lte'\n\tCurrent PLMN:\n\t\tMCC: '410'\n\t\tMNC: '3'\n\t\tDescription: 'Onic'\n" > "$TMP/reg-probe.txt"
ra=$(awk_parse REG "$TMP/reg-qmicli.txt")
rb=$(awk_parse REG "$TMP/reg-probe.txt")
eq "registration parses identically from both shapes" "{$ra}" "{$rb}"
contains "the carrier name survives from the probe's PLMN block" '"carrier":"Onic"' "$rb"

# A roaming registration must not read as "registered": qmicli prints
# 'registered-roaming', and the parser compares the string literally.
printf "[qrtr] Successfully got serving system:\n\tRegistration state: 'registered-roaming'\n\tCurrent PLMN:\n\t\tDescription: 'Onic'\n" > "$TMP/reg-roam.txt"
rr=$(awk_parse REG "$TMP/reg-roam.txt")
contains "registered-roaming is not reported as registered" '"registered":false' "$rr"

# No description at all -> carrier null, never an empty string.
printf "[qrtr] Successfully got serving system:\n\tRegistration state: 'registered'\n" > "$TMP/reg-nodesc.txt"
rn=$(awk_parse REG "$TMP/reg-nodesc.txt")
contains "a missing description becomes null" '"carrier":null' "$rn"

printf '\n'
if [ "$FAIL" -eq 0 ]; then printf 'PASS  %d assertions\n' "$PASS"; exit 0; fi
printf 'FAIL  %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
