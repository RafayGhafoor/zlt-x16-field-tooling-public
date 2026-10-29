#!/bin/sh
# =============================================================================
# tests/unit_traffic_sampler.sh — unit tests for qmanager_traffic.sh
# =============================================================================
# The sampler takes a file path from QMT_PROC, so the whole maths can be tested
# with synthetic /proc/net/dev snapshots and no network at all.
#   sh tests/unit_traffic_sampler.sh
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SAMPLER="$HERE/../deploy-x16/qmanager_traffic.sh"
[ -f "$SAMPLER" ] || { echo "FATAL: $SAMPLER missing" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED="$FAILED
  - $1: $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# /proc/net/dev shaped file. Layout after the colon:
#   rx_bytes rx_packets rx_errs rx_drop rx_fifo rx_frame rx_compressed rx_multicast
#   tx_bytes tx_packets tx_errs tx_drop tx_fifo tx_colls tx_carrier rx_compressed
mkproc() {
    # $1 file  $2 bridge0_rx  $3 bridge0_tx
    cat > "$1" <<EOF
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
  eth0:  100000     100    0    0    0     0          0         0   200000     100    0    0    0     0       0          0
bridge0:  $2     500    0    0    0     0          0         0   $3     500    0    0    0     0       0          0
EOF
}

TMP=$(mktemp -d)
OUT="$TMP/out.json"

# --- 1: 1 MB/s download over a 1 s window --------------------------------
# Deterministic replay: two snapshots, 1,000,000 bytes of rx and no tx delta.
SEQ="$TMP/seq1"; mkdir -p "$SEQ"
mkproc "$SEQ/01" 10000000 2000000
mkproc "$SEQ/02" 11000000 2000000
rm -f "$OUT"
QMT_SEQ_DIR="$SEQ" QMT_OUT="$OUT" QMT_IFACE=bridge0 QMT_INTERVAL=1 sh "$SAMPLER" >/dev/null 2>&1

if [ -f "$OUT" ]; then
    eq "iface is reported" "bridge0" "$(sed -n 's/.*"iface":"\([^"]*\)".*/\1/p' "$OUT")"
    # 1,000,000 bytes in 1 s = 8,000,000 bits/s
    eq "download delta converts to bits/s" "8000000" "$(sed -n 's/.*"rx_bps":\([0-9]*\).*/\1/p' "$OUT")"
    eq "upload delta is zero when tx is flat" "0" "$(sed -n 's/.*"tx_bps":\([0-9]*\).*/\1/p' "$OUT")"
    eq "window is reported" "1000" "$(sed -n 's/.*"window_ms":\([0-9]*\).*/\1/p' "$OUT")"
    case "$(cat "$OUT")" in
        '{"ok":true'*'"ts":'*'}'*) ok "output is well-formed JSON" ;;
        *) bad "output is well-formed JSON" "$(cat "$OUT")" ;;
    esac
else
    bad "sampler produced output" "no $OUT"
fi

# --- 2: counter reset (interface recreated) ------------------------------
SEQ="$TMP/seq2"; mkdir -p "$SEQ"
mkproc "$SEQ/01" 11000000 2000000
mkproc "$SEQ/02" 10000000 2000000      # counters go backwards
rm -f "$OUT"
QMT_SEQ_DIR="$SEQ" QMT_OUT="$OUT" QMT_IFACE=bridge0 QMT_INTERVAL=1 sh "$SAMPLER" >/dev/null 2>&1
if [ -f "$OUT" ]; then
    eq "counter reset is flagged" "true" "$(sed -n 's/.*"counter_reset":\([a-z]*\).*/\1/p' "$OUT")"
    eq "reset does not emit a bogus rate" "0" "$(sed -n 's/.*"rx_bps":\([0-9]*\).*/\1/p' "$OUT")"
else
    bad "counter reset output" "no file"
fi

# --- 3: upload ----------------------------------------------------------
SEQ="$TMP/seq3"; mkdir -p "$SEQ"
mkproc "$SEQ/01" 11000000 2000000
mkproc "$SEQ/02" 11000000 2500000      # 500,000 bytes up = 4,000,000 bit/s
rm -f "$OUT"
QMT_SEQ_DIR="$SEQ" QMT_OUT="$OUT" QMT_IFACE=bridge0 QMT_INTERVAL=1 sh "$SAMPLER" >/dev/null 2>&1
eq "upload delta converts to bits/s" "4000000" "$(sed -n 's/.*"tx_bps":\([0-9]*\).*/\1/p' "$OUT")"

rm -rf "$TMP"

echo
if [ "$FAIL" -eq 0 ]; then printf 'PASS  %d assertions\n' "$PASS"; exit 0; fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED"; exit 1
