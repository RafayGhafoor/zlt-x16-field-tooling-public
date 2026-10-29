#!/bin/sh
# =============================================================================
# tests/unit_qmi_bands.sh — capability/policy band lists over QMI
# =============================================================================
# qm_qmi_capability_lines and qm_qmi_policy_lines exist so the poller can read the
# band catalogue without sending AT+CSYSSEL=?, which AGENTS.md §6 lists as a
# command that can hang with no timeout in atcmd -- on the boot path of the
# band picker. They emit the shim's own +QNWPREFCFG: dialect so parse_policy_band()
# is unchanged.
#
# Two failure modes are worth a test rather than a review, because both were real
# while this was being written (2026-10-29):
#   1. a parser that validates the COMMA list against a COLON regex rejects every
#      list and returns 4 -- silently, since the caller then falls back to AT and
#      behaves exactly as before. That is the worst kind: the improvement is dead
#      and nothing looks wrong.
#   2. an empty NR policy reported as the LTE list (or vice versa) tells the UI a
#      band is enabled when it is not. Empty must stay distinguishable.
#
# The fixtures are real qmicli output captured from this unit, so the awk sees the
# exact tabs, commas and quoting the device emits. No device, no libqmi, no QRTR.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/../qmanager/scripts/usr/lib/qmanager/qmi_read.sh"
[ -f "$LIB" ] || LIB="${QM_SRC:-/tmp/qm}/scripts/usr/lib/qmanager/qmi_read.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }
missing()  { case "$3" in *"$2"*) bad "$1" "must NOT contain [$2], got [$3]" ;; *) ok "$1" ;; esac; }

[ -r "$LIB" ] || { echo "FATAL: qmi_read.sh not found ($LIB)" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qmibands.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# Stub qmicli: prints a fixture named by the first --nas-/--dms- flag it is given.
cat > "$TMP/qmicli" <<'STUB'
#!/bin/sh
# qm_qmi_available() probes with --dms-get-operating-mode first, so that has to
# answer too or every reader below reports "unavailable" (2) and the suite tests
# the fallback path instead of the parser.
for a in "$@"; do
    case "$a" in
        --dms-get-operating-mode)               printf "[qrtr://3] Operating mode retrieved:\n\tMode: 'online'\n"; exit 0 ;;
        --dms-get-band-capabilities)            cat "$FIXTURES/caps.txt"; exit 0 ;;
        --nas-get-system-selection-preference)  cat "$FIXTURES/ssp.txt";  exit 0 ;;
    esac
done
exit 1
STUB
chmod +x "$TMP/qmicli"
mkdir -p "$TMP/f"
fixtures=$TMP/f

# Real capture (2026-10-29): capability vs policy on this unit.
printf "\tBands: 'wcdma-2100, wcdma-850-us, wcdma-800, wcdma-900'\n\tLTE bands: '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43'\n\tLTE bands (extended): '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43, 46, 48'\n\tNR5G bands: '1, 3, 5, 7, 8, 20, 26, 28, 38, 40, 41, 48, 77, 78, 79'\n" > "$fixtures/caps.txt"
printf "[qrtr://3] Device band capabilities retrieved:\n" | cat - "$fixtures/caps.txt" > "$fixtures/caps2.txt" && mv "$fixtures/caps2.txt" "$fixtures/caps.txt"

printf "[qrtr://3] Successfully got system selection preference\n\tEmergency mode: 'no'\n\tMode preference: 'lte, 5gnr'\n\tLTE band preference: '1, 3, 5, 28, 38, 41'\n\tLTE band preference (extended): '1, 3, 5, 28, 38, 41'\n\tNR5G SA band preference: '1, 8, 40, 41, 78'\n\tNR5G NSA band preference: '1, 8, 40, 41, 78'\n\tRoaming preference: 'any'\n" > "$fixtures/ssp.txt"

# Stub probe: qmi-probe's qmicli-shaped text modes. Emits the SAME values as the
# qmicli stub above, which is the point -- both backends must produce identical
# band lists, or the band picker silently changes when one is installed.
cat > "$TMP/qmi-probe" <<'PSTUB'
#!/bin/sh
case "$1" in
    ports)
        printf 'service 0x02 -> qrtr://3 port 68  [modern]\nservice 0x03 -> qrtr://3 port 55  [modern]\n'
        exit 0 ;;
    caps-text)
        cat "$FIXTURES/caps_probe.txt"; exit $? ;;
    ssp-text)
        cat "$FIXTURES/ssp_probe.txt"; exit $? ;;
esac
exit 2
PSTUB
chmod +x "$TMP/qmi-probe"

# qmicli-shaped output the probe prints, same numbers as the qmicli fixtures.
printf "[qrtr] Device band capabilities retrieved:\n\tLTE bands: '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43, 46, 48'\n\tLTE bands (extended): '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43, 46, 48'\n\tNR5G bands: '1, 3, 5, 7, 8, 20, 26, 28, 38, 40, 41, 48, 77, 78, 79'\n" > "$fixtures/caps_probe.txt"
printf "[qrtr] Successfully got system selection preference\n\tLTE band preference: '1, 3, 5, 28, 38, 41'\n\tLTE band preference (extended): '1, 3, 5, 28, 38, 41'\n\tNR5G SA band preference: '1, 8, 40, 41, 78'\n\tNR5G NSA band preference: '1, 8, 40, 41, 78'\n" > "$fixtures/ssp_probe.txt"

run_lib() {
    FIXTURES=$fixtures \
    QM_QMI_BIN=$TMP/qmicli QM_QMI_LIBDIR=$TMP \
    QM_QMI_PROBE_BIN=${PROBE:-} \
    sh -c ". \"$LIB\" 2>/dev/null; $1" 2>/dev/null
}

# --- capability ---------------------------------------------------------------
out=$(run_lib 'qm_qmi_capability_lines'); rc=$?
eq "capability returns 0 on a real answer" "0" "$rc"
contains "capability carries the EXTENDED LTE list (19 bands, incl. 46/48)" \
    '+QNWPREFCFG: "ue_capability_band",1:3:5:7:8:<mac-redacted>:<mac-redacted>:46:48' "$out"
contains "capability publishes lte_band in the shim's dialect" \
    '+QNWPREFCFG: "lte_band",1:3:5:7:8:<mac-redacted>:<mac-redacted>:46:48' "$out"
contains "capability publishes the NR list once, for NSA and SA" \
    '+QNWPREFCFG: "nr5g_band",1:3:5:7:8:<mac-redacted>:48:77:78:79' "$out"
missing  "capability never emits the POLICY value" \
    '1:3:5:28:38:41' "$out"

# --- policy ------------------------------------------------------------------
out=$(run_lib 'qm_qmi_policy_lines'); rc=$?
eq "policy returns 0 on a real answer" "0" "$rc"
contains "policy reports the live LTE set"  '+QNWPREFCFG: "lte_band",1:3:5:28:38:41' "$out"
contains "policy reports the NSA set"       '+QNWPREFCFG: "nsa_nr5g_band",1:8:40:41:78' "$out"
contains "policy reports the SA set"        '+QNWPREFCFG: "nr5g_band",1:8:40:41:78' "$out"

# --- empty NR policy must not be reported as the LTE list -------------------
printf "[qrtr://3] Successfully got system selection preference\n\tLTE band preference: '1, 3'\n\tNR5G SA band preference: ''\n\tNR5G NSA band preference: ''\n" > "$fixtures/ssp.txt"
out=$(run_lib 'qm_qmi_policy_lines')
contains "an empty NR policy becomes 0, not the LTE list" '+QNWPREFCFG: "nr5g_band",0' "$out"
missing  "an empty NR policy never borrows the LTE set"  'nr5g_band",1:3' "$out"

# --- failures must be reported, never an invented list ----------------------
# No success marker at all: the lib's contract calls that a half-answered CALL (3),
# which is distinct from an answer that arrived but carried no band lines (4).
printf "garbage with no band markers\n" > "$fixtures/caps.txt"
run_lib 'qm_qmi_capability_lines' > "$TMP/out.txt" 2>/dev/null
eq "a marker-less answer is a call failure (3)" "3" "$?"

# Marker present, no band labels: a real answer we could not use.
printf "[qrtr://3] Device band capabilities retrieved:\n\tBands: 'wcdma-2100'\n" > "$fixtures/caps.txt"
run_lib 'qm_qmi_capability_lines' > "$TMP/out.txt" 2>/dev/null
eq "an answer with no LTE list is a parse failure (4)" "4" "$?"

rm -f "$TMP/qmicli"
run_lib 'qm_qmi_capability_lines' > "$TMP/out.txt" 2>/dev/null
eq "a missing qmicli is 'unavailable' (2), so the caller falls back to AT" "2" "$?"

# --- backend selection and parity -------------------------------------------
# The failure tests above deliberately broke the qmicli stub and its fixtures, so
# rebuild them here: this block compares two healthy backends, and asserting
# parity against a broken fixture would "pass" for the wrong reason.
cat > "$TMP/qmicli" <<'STUB2'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        --dms-get-operating-mode)               printf "[qrtr://3] Operating mode retrieved:\n\tMode: 'online'\n"; exit 0 ;;
        --dms-get-band-capabilities)            cat "$FIXTURES/caps.txt"; exit 0 ;;
        --nas-get-system-selection-preference)  cat "$FIXTURES/ssp.txt";  exit 0 ;;
    esac
done
exit 1
STUB2
chmod +x "$TMP/qmicli"
printf "[qrtr://3] Device band capabilities retrieved:\n\tLTE bands: '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43'\n\tLTE bands (extended): '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43, 46, 48'\n\tNR5G bands: '1, 3, 5, 7, 8, 20, 26, 28, 38, 40, 41, 48, 77, 78, 79'\n" > "$fixtures/caps.txt"
printf "[qrtr://3] Successfully got system selection preference\n\tLTE band preference: '1, 3, 5, 28, 38, 41'\n\tLTE band preference (extended): '1, 3, 5, 28, 38, 41'\n\tNR5G SA band preference: '1, 8, 40, 41, 78'\n\tNR5G NSA band preference: '1, 8, 40, 41, 78'\n" > "$fixtures/ssp.txt"
printf "[qrtr] Device band capabilities retrieved:\n\tLTE bands: '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43, 46, 48'\n\tLTE bands (extended): '1, 3, 5, 7, 8, 18, 19, 20, 26, 28, 32, 38, 39, 40, 41, 42, 43, 46, 48'\n\tNR5G bands: '1, 3, 5, 7, 8, 20, 26, 28, 38, 40, 41, 48, 77, 78, 79'\n" > "$fixtures/caps_probe.txt"

cap_qmicli=$(run_lib 'qm_qmi_capability_lines')
pol_qmicli=$(run_lib 'qm_qmi_policy_lines')
cap_probe=$(PROBE=$TMP/qmi-probe run_lib 'qm_qmi_capability_lines')
pol_probe=$(PROBE=$TMP/qmi-probe run_lib 'qm_qmi_policy_lines')

eq "capability is identical from qmicli and from the probe" "$cap_qmicli" "$cap_probe"
eq "policy is identical from qmicli and from the probe"     "$pol_qmicli" "$pol_probe"

eq "no probe installed -> backend is qmicli" \
   "qmicli" "$(run_lib 'qm_qmi_backend')"
eq "probe installed -> backend is the probe" \
   "probe" "$(PROBE=$TMP/qmi-probe run_lib 'qm_qmi_backend')"

# A probe that answers the liveness check but fails the real read must be a call
# failure (3), never an empty band list.
printf "no marker here\n" > "$fixtures/caps_probe.txt"
PROBE=$TMP/qmi-probe run_lib 'qm_qmi_capability_lines' > "$TMP/out.txt" 2>/dev/null
eq "a failing probe read is a call failure (3)" "3" "$?"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
