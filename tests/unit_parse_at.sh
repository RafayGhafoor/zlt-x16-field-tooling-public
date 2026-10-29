#!/bin/sh
# parse_at.sh — serving-cell parsing must not fabricate a band.
#
# The bug this pins (measured 2026-10-27): the LTE-only and EN-DC branches built
# the band as the literal `"B" f(N)`. During a service blip the modem can return
# a partial +QENG line whose band field is 0, so that produced the string "B0" —
# a band that does not exist. events.sh debounces band/pci changes but treats a
# NON-EMPTY value as a real observation, so every blip emitted:
#
#   band_change  LTE band settled on B0 (was B3, PCI 0)
#   pci_change   LTE cell handoff on B0 (PCI 227 -> 0)
#
# ...and then the mirror pair on the way back. That is where the reported
# "continuous cell handoffs" came from: two phantom handoff pairs per outage,
# on a box that had 26 outages.
#
# _ev_settle already ignores an EMPTY value as "absent observation", so leaving
# the band blank is the correct fix and needs no change in events.sh.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="${QM_SRC:-/tmp/qm}/scripts/usr/lib/qmanager/parse_at.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

if [ ! -f "$LIB" ]; then
    printf 'unit_parse_at: SKIP (no %s — set QM_SRC to a QManager tree)\n' "$LIB"
    exit 0
fi

# The library expects the qlog_* helpers from qlog.sh; stub them so this test
# needs no logging stack.
qlog_warn() { :; }; qlog_info() { :; }; qlog_error() { :; }; qlog_debug() { :; }
qlog_at_cmd() { :; }; qlog_state_change() { :; }
# The library is written to be sourced with nounset OFF (it probes for
# optionally-defined globals, e.g. _PARSE_AT_LOADED). Source it unset, then
# restore our own strict mode.
set +u
# shellcheck disable=SC1090
. "$LIB"
set -u

probe() { parse_serving_cell "$1"; }

# --- a real cell must be parsed exactly as before ---------------------------
probe '+QENG: "servingcell","CONNECT","LTE","FDD",410,01,ABC123,227,1850,3,5,5,D857,-72,-13,-39,6'
eq "real cell: band kept"   "B3"   "$lte_band"
eq "real cell: pci kept"    "227"  "$lte_pci"
eq "real cell: earfcn kept" "1850" "$lte_earfcn"
eq "real cell: state"       "connected" "$lte_state"

# --- band 0 must NOT become "B0" -------------------------------------------
probe '+QENG: "servingcell","CONNECT","LTE","FDD",410,01,,0,0,0,0,0,,0,0,0,0'
eq "band 0 does not fabricate B0"   "" "$lte_band"
eq "band 0 does not anchor a pci"   "" "$lte_pci"
eq "band 0 does not anchor an earfcn" "" "$lte_earfcn"

# A blank band field (rather than 0) must behave the same way.
probe '+QENG: "servingcell","CONNECT","LTE","FDD",410,01,,227,1850,,5,5,D857,-72,-13,-39,6'
eq "blank band does not fabricate B" "" "$lte_band"
eq "blank band does not anchor a pci" "" "$lte_pci"

# --- band 1 is the lowest real band, and must survive ----------------------
probe '+QENG: "servingcell","CONNECT","LTE","FDD",410,01,ABC123,104,250,1,5,5,D857,-72,-13,-39,6'
eq "band 1 is real and kept" "B1"  "$lte_band"
eq "band 1 keeps its pci"    "104" "$lte_pci"

# --- SEARCH sentinel stays blank ------------------------------------------
probe '+QENG: "servingcell","SEARCH"'
eq "SEARCH: band blank"  "" "$lte_band"
eq "SEARCH: state unknown" "unknown" "$lte_state"

echo "unit_parse_at: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
