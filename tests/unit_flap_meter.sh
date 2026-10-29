#!/bin/sh
# =============================================================================
# tests/unit_flap_meter.sh — the flap meter's join logic, without a device
# =============================================================================
# scripts/flap-meter/analyze.sh answers one question: do radio changes precede
# the WAN drops, or follow them? The answer decides whether any radio surgery is
# worth doing (docs/29 measured "follows"; a later unit may disagree), so the
# analyzer must never overstate what it saw. Three ways it could lie, all
# asserted here with synthetic fixtures:
#
#   1. counting a drop that happened OUTSIDE the sampled window as "no change
#      happened" -- absent data is not negative evidence. This was a real bug,
#      found when the first capture had 32 historical drops and a 60-second
#      transition window: every row printed "no/no" and the verdict read like a
#      finding instead of "you sampled nothing".
#   2. missing a change that precedes a drop (the "churn leads" case), which
#      would make radio surgery look unnecessary without any basis;
#   3. missing the reverse ("drops lead"), which is the docs/29 conclusion and
#      therefore the one a biased reading is most likely to confirm by accident.
#
# Host-only, no device, no network, no QMI binary: awk on two fixture files.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ANALYZE="$HERE/../scripts/flap-meter/analyze.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }

[ -r "$ANALYZE" ] || { echo "FATAL: $ANALYZE missing" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/flapmeter.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- fixture 1: a radio change 20 s BEFORE a drop ----------------------------
cat > "$TMP/t-before.log" <<'EOF'
2026-10-30 10:00:00 STATE pcc=B3/1312/256 scc=B1/150/502:act cc=2 endc=0 nr=-
2026-10-30 10:00:30 HEARTBEAT pcc=B3/1312/256 scc=B1/150/502:act cc=2 endc=0 nr=-
2026-10-30 10:05:40 CHANGE pcc B3/1312/256 -> B1/250/104
2026-10-30 10:05:40 STATE pcc=B1/250/104 scc=B1/150/502:act cc=2 endc=0 nr=-
2026-10-30 10:05:58 CHANGE scc B1/150/502:act -> B1/150/502:act,B5/2450/469:act
2026-10-30 10:05:58 STATE pcc=B1/250/104 scc=B1/150/502:act,B5/2450/469:act cc=3 endc=0 nr=-
2026-10-30 10:06:00 CHANGE endc 0 -> 1
2026-10-30 10:06:00 STATE pcc=B1/250/104 scc=B1/150/502:act,B5/2450/469:act cc=3 endc=1 nr=-
2026-10-30 10:20:00 SUMMARY samples=1200 changes=3 seconds=1200
EOF
cat > "$TMP/d-before.log" <<'EOF'
2026-10-30 10:06:20.000000 [syslog] [dialer] data_call_evt_cb: <<<<< Datacall Disconnected!
2026-10-30 10:06:45.000000 [syslog] [dialer] sunsea_dialer_config_lan_wan: <<<<<dial successful.<<<<<
EOF

out=$(sh "$ANALYZE" "$TMP/t-before.log" "$TMP/d-before.log" 2>&1)

contains "a change before the drop is reported as such" "before" "$out"
contains "the recovery time is computed from drop to re-dial" "25s" "$out"
# The analyzer names the three transition types separately (docs/44): a PCC/band
# change is a reselection, an SCell add/release is RRC, and an activation toggle is
# MAC CE. This fixture's only transition is the PCC change, so assert the label the
# analyzer now prints for it -- the earlier "serving cell (pcc)" wording was replaced
# in a2ad0f3e and this assertion was not carried over with it.
contains "per-type breakdown counts the serving-cell change" "serving cell / band (RRC reselection): 1" "$out"
contains "per-type breakdown counts the EN-DC change" "EN-DC available: 1" "$out"
contains "in-window drop is counted as preceded by a change" "preceding 60 s: 1/1" "$out"

# --- fixture 2: the reverse -- the drop comes first, the churn follows -------
cat > "$TMP/t-after.log" <<'EOF'
2026-10-30 10:59:00 STATE pcc=B3/1850/227 scc=- cc=1 endc=0 nr=-
2026-10-30 11:30:00 HEARTBEAT pcc=B1/250/162 scc=B1/150/502:act cc=2 endc=0 nr=-
2026-10-30 11:00:36 CHANGE pcc B3/1850/227 -> B1/250/162
2026-10-30 11:00:36 STATE pcc=B1/250/162 scc=- cc=1 endc=0 nr=-
2026-10-30 11:20:35 CHANGE scc - -> B1/150/502:act
2026-10-30 11:20:35 STATE pcc=B1/250/162 scc=B1/150/502:act cc=2 endc=0 nr=-
2026-10-30 11:40:37 CHANGE endc 0 -> 1
2026-10-30 11:40:37 STATE pcc=B1/250/162 scc=B1/150/502:act cc=2 endc=1 nr=-
EOF
cat > "$TMP/d-after.log" <<'EOF'
2026-10-30 11:00:21.000000 [syslog] [dialer] data_call_evt_cb: <<<<< Datacall Disconnected!
2026-10-30 11:00:26.000000 [syslog] [dialer] sunsea_dialer_config_lan_wan: <<<<<dial successful.<<<<<
2026-10-30 11:20:21.000000 [syslog] [dialer] data_call_evt_cb: <<<<< Datacall Disconnected!
2026-10-30 11:20:26.000000 [syslog] [dialer] sunsea_dialer_config_lan_wan: <<<<<dial successful.<<<<<
2026-10-30 11:40:21.000000 [syslog] [dialer] data_call_evt_cb: <<<<< Datacall Disconnected!
2026-10-30 11:40:26.000000 [syslog] [dialer] sunsea_dialer_config_lan_wan: <<<<<dial successful.<<<<<
EOF

out=$(sh "$ANALYZE" "$TMP/t-after.log" "$TMP/d-after.log" 2>&1)
contains "a change after the drop is reported as such" "after" "$out"
contains "the verdict names the docs/29 direction in this case" "drops LEAD the churn" "$out"

# --- fixture 3: drops outside the window must NOT read as "no change" -------
cat > "$TMP/d-outside.log" <<'EOF'
2026-10-28 03:00:00.000000 [syslog] [dialer] data_call_evt_cb: <<<<< Datacall Disconnected!
2026-10-28 03:00:52.000000 [syslog] [dialer] sunsea_dialer_config_lan_wan: <<<<<dial successful.<<<<<
EOF

out=$(sh "$ANALYZE" "$TMP/t-before.log" "$TMP/d-outside.log" 2>&1)
contains "an out-of-window drop is labelled 'no data'" "no data (outside window)" "$out"
contains "it is excluded from the correlation counts" "1 of 1 drop(s) fall outside" "$out"
contains "and the verdict refuses to conclude" "run the sampler across a drop" "$out"

# --- fixture 4: no dialer log at all ---------------------------------------
out=$(sh "$ANALYZE" "$TMP/t-before.log" /dev/null 2>&1)
contains "an empty dialer log says so instead of inventing a verdict" "none in this log" "$out"

# --- fixture 5: a sampler gap must be visible, not averaged away ------------
cat > "$TMP/t-gap.log" <<'EOF'
2026-10-30 09:00:00 STATE pcc=B3/1312/256 scc=- cc=1 endc=0 nr=-
2026-10-30 09:01:00 HEARTBEAT pcc=B3/1312/256 scc=- cc=1 endc=0 nr=-
2026-10-30 09:40:00 HEARTBEAT pcc=B3/1312/256 scc=- cc=1 endc=0 nr=-
2026-10-30 09:40:01 CHANGE pcc B3/1312/256 -> B3/1312/480
2026-10-30 09:40:01 STATE pcc=B3/1312/480 scc=- cc=1 endc=0 nr=-
EOF
out=$(sh "$ANALYZE" "$TMP/t-gap.log" /dev/null 2>&1)
contains "a 39-minute sampler gap is reported" "largest gap between samples: 0h39m00s" "$out"

# --- fixture 6: the echo of the analyzer's own limits ----------------------
out=$(sh "$ANALYZE" "$TMP/t-before.log" "$TMP/d-before.log" 2>&1)
# The point of splitting the types is that the MAC-level half is invisible over AT
# (docs/44: `AT+CCAINFO` reports the SCell set, not its activation state), so the
# analyzer has to label it. Assert the label rather than the old free-text note.
contains "SCC-state transitions are labelled as MAC CE (invisible over AT)" "SCell activated/deactivated (MAC CE)" "$out"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
