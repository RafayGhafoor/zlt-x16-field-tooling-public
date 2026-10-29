#!/bin/sh
# =============================================================================
# qmanager_traffic.sh — Live Traffic sampler for the ZLT X16 (shell edition)
# =============================================================================
# Upstream ships a Rust sampler that reads ETHTOOL_GSTATS from the LAN NIC,
# because on the GreenPacket the Qualcomm IPA path bypassed /proc/net/dev for
# its counters. On this device /proc/net/dev is authoritative for both the LAN
# bridge and the WAN rmnet interface (verified: rmnet_ipa0 and bridge0 both
# advance under load), so a 1 Hz shell sampler is enough — and it needs no
# cross-compiled binary and no glibc/musl matching.
#
# Output schema is byte-compatible with the Rust daemon, because the dashboard
# reads it directly:
#   {"ok":true,"iface":"bridge0","rx_bps":<download>,"tx_bps":<upload>,
#    "window_ms":1000,"warming":false,"counter_reset":false,"ts":<epoch>}
# rx_bps = DOWNLOAD (WAN -> LAN), tx_bps = UPLOAD (LAN -> WAN), in bits/second.
#
# Counters: the LAN bridge is summed with its member eth0? NO — the same packet
# appears in both paths, so summing double-counts. bridge0 alone is used when it
# exists and is moving; otherwise the first non-zero of eth0/rmnet_data0.
#
# Env:
#   QMT_OUT      output path            (default /tmp/qmanager_traffic.json)
#   QMT_PROC     alternative /proc/net/dev file (used by the unit tests)
#   QMT_IFACE    force an interface name
#   QMT_INTERVAL seconds between samples (default 1)
#   QMT_ITER     stop after N samples (tests); unset = run forever
#   QMT_SEQ_DIR  directory of numbered /proc/net/dev snapshots: consume them in
#                order, emit one sample per pair, no sleeping, then exit. This is
#                the deterministic mode the unit tests drive.
# =============================================================================
set -u

OUT="${QMT_OUT:-/tmp/qmanager_traffic.json}"
PROC="${QMT_PROC:-/proc/net/dev}"
IFACE_FORCED="${QMT_IFACE:-}"
INTERVAL="${QMT_INTERVAL:-1}"
ITER="${QMT_ITER:-0}"

# read rx/tx bytes for one interface from a /proc/net/dev-shaped file
read_counters() {
    # $1 iface, $2 optional file (defaults to $PROC) -> "rx tx" or empty
    _f=${2:-$PROC}
    awk -v want="$1" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            n = index(line, ":")
            if (n == 0) next
            name = substr(line, 1, n - 1)
            gsub(/[ \t]/, "", name)
            if (name != want) next
            rest = substr(line, n + 1)
            split(rest, f, /[ \t]+/)
            # fields after the colon: rx_bytes ... tx_bytes is field 9
            c = 0
            for (i = 1; i <= length(f); i++) if (f[i] != "") { c++; v[c] = f[i] }
            print v[1], v[9]
            exit
        }' "$_f" 2>/dev/null
}

pick_iface() {
    if [ -n "$IFACE_FORCED" ]; then printf '%s' "$IFACE_FORCED"; return 0; fi
    for i in bridge0 eth0 rmnet_data0 rmnet_ipa0 wwan0; do
        set -- $(read_counters "$i")
        [ $# -eq 2 ] || continue
        [ "$1" -gt 0 ] 2>/dev/null && { printf '%s' "$i"; return 0; }
    done
    printf 'bridge0'
}

emit() {
    # $1 iface $2 rx_delta $3 tx_delta $4 window_ms $5 warming $6 reset
    ts=$(date +%s)
    rx_bps=$(( $2 * 8000 / ($4 / 1) ))
    tx_bps=$(( $3 * 8000 / ($4 / 1) ))
    printf '{"ok":true,"iface":"%s","rx_bps":%d,"tx_bps":%d,"window_ms":%d,"warming":%s,"counter_reset":%s,"ts":%d}\n' \
        "$1" "$rx_bps" "$tx_bps" "$4" "$5" "$6" "$ts" > "$OUT.tmp" 2>/dev/null \
        && mv "$OUT.tmp" "$OUT" 2>/dev/null
}

IFACE=$(pick_iface)
prev=""
warm=1
count=0

# --- deterministic replay mode (tests) --------------------------------------
if [ -n "${QMT_SEQ_DIR:-}" ]; then
    for snap in "$QMT_SEQ_DIR"/*; do
        [ -f "$snap" ] || continue
        cur=$(read_counters "$IFACE" "$snap")
        [ -n "$prev" ] || { prev="$cur"; continue; }
        set -- $prev; prx=$1; ptx=$2
        set -- $cur;  crx=$1; ctx=$2
        drx=$((crx - prx)); dtx=$((ctx - ptx))
        reset=false
        [ "$drx" -lt 0 ] && { drx=0; reset=true; }
        [ "$dtx" -lt 0 ] && { dtx=0; reset=true; }
        emit "$IFACE" "$drx" "$dtx" $((INTERVAL * 1000)) false "$reset"
        prev="$cur"
    done
    exit 0
fi

while :; do
    cur=$(read_counters "$IFACE")
    now_ms=$(date +%s)
    if [ -n "$cur" ]; then
        if [ -n "$prev" ]; then
            set -- $prev
            prx=$1; ptx=$2
            set -- $cur
            crx=$1; ctx=$2
            drx=$((crx - prx)); dtx=$((ctx - ptx))
            reset=false
            # a counter that went backwards means the interface was recreated
            [ "$drx" -lt 0 ] && { drx=0; reset=true; }
            [ "$dtx" -lt 0 ] && { dtx=0; reset=true; }
            if [ "$warm" = "1" ]; then
                warm=0
            else
                emit "$IFACE" "$drx" "$dtx" $((INTERVAL * 1000)) false "$reset"
            fi
        fi
        prev="$cur"
    else
        IFACE=$(pick_iface)
    fi

    count=$((count + 1))
    [ "$ITER" -gt 0 ] && [ "$count" -ge "$ITER" ] && break
    sleep "$INTERVAL"
done
