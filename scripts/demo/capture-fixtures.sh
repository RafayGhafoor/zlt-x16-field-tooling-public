#!/bin/sh
# =============================================================================
# capture-fixtures.sh — snapshot a live QManager's CGI answers for the demo server
# =============================================================================
# The demo server (demo_server.py) answers the UI's /cgi-bin/... fetches from
# captured JSON. Capturing instead of hand-writing mocks is the whole point: the
# shapes are whatever the shipped CGIs actually emit, so a fixture cannot drift
# from the component contract the way a hand-built mock does.
#
# USAGE
#   scripts/demo/capture-fixtures.sh [fixtures-dir] [device]
#
#   fixtures-dir  default scripts/demo/fixtures   (git-ignored: it carries IMSI,
#                 ICCID and IMEI — a real SIM's identifiers, not lorem ipsum)
#   device        default zlt-root
#   QM_PASS       QManager admin password (default <redacted-password>)
#
# Transport follows AGENTS.md §1: no scp (dropbear has no sftp-server), every ssh
# call retried, directories pulled with a tar stream.
# =============================================================================
set -u

OUT=${1:-$(cd "$(dirname "$0")" && pwd)/fixtures}
HOST=${2:-${ZLT_HOST:-zlt-root}}
PASS=${QM_PASS:-<redacted-password>}
BASE="http://127.0.0.1:8080/cgi-bin/quecmanager"
TRIES=${ZLT_TRIES:-10}

ssh_try() {
    _n=0
    while [ "$_n" -lt "$TRIES" ]; do
        if out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$1" 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        _n=$((_n + 1))
        sleep 3
    done
    printf '%s\n' "$out" >&2
    return 1
}

# GET endpoints the UI fetches on load. Add one here and re-run — the sanitiser
# (path '/' -> '_', plus a suffix for the query) is shared with demo_server.py.
ENDPOINTS="
public/overview.sh
public/hostname.sh
public/units.sh
at_cmd/fetch_data.sh
at_cmd/fetch_events.sh
at_cmd/fetch_ping_history.sh
at_cmd/fetch_signal_history.sh
device/about.sh
cellular/settings.sh
cellular/apn.sh
cellular/imei.sh
cellular/sms.sh
cellular/network_priority.sh
bands/current.sh
bands/failover_status.sh
frequency/status.sh
monitoring/alerts.sh
monitoring/sites.sh
monitoring/watchdog.sh
network/custom_dns.sh
network/data_used.sh
network/mtu.sh
network/ttl.sh
network/ethernet.sh
network/ip_passthrough.sh
network/smartdns.sh
network/smartdns_stats.sh
network/video_optimizer.sh
profiles/list.sh
profiles/current_settings.sh
scenarios/list.sh
scenarios/active.sh
settings/ping_profile.sh
settings/quality_thresholds.sh
system/settings.sh
system/logs.sh
system/known_sims.sh
system/sim_registry.sh
system/modem-subsys.sh
system/health-check/status.sh
tower/status.sh
at_cmd/cell_scan_status.sh
at_cmd/neighbour_scan_status.sh
at_cmd/speedtest_status.sh
at_cmd/speedtest_check.sh
"

echo "== capturing from $HOST into $OUT =="
ssh_try "rm -rf /tmp/qm-fx && mkdir -p /tmp/qm-fx
    B='$BASE'; C=/tmp/qm-fx-cookie; rm -f \$C
    curl -s -m 20 -c \$C -X POST -H 'Content-Type: application/json' \
        -d '{\"password\":\"$PASS\"}' \$B/auth/login.sh >/dev/null
    while read -r p; do
        [ -n \"\$p\" ] || continue
        n=\$(printf '%s' \"\$p\" | tr '/' '_')
        curl -s -m 25 -b \$C \"\$B/\$p\" > \"/tmp/qm-fx/\$n.json\" 2>/dev/null
    done <<'LIST'
$ENDPOINTS
LIST
    # query-shaped answers the History page asks for, keyed the way demo_server
    # looks them up (<stem>__<view><range>.json, then <stem>__<range>.json)
    curl -s -m 40 -b \$C \"\$B/at_cmd/fetch_signal_history.sh?view=cells&range=24h\" \
        > /tmp/qm-fx/at_cmd_fetch_signal_history.sh__cells24h.json
    curl -s -m 40 -b \$C \"\$B/at_cmd/fetch_signal_history.sh?range=1h\" \
        > /tmp/qm-fx/at_cmd_fetch_signal_history.sh__1h.json
    ls /tmp/qm-fx | wc -l" || { echo "capture failed" >&2; exit 1; }

mkdir -p "$OUT"
_n=0
until ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" 'cd /tmp/qm-fx && tar cf - .' 2>/dev/null | tar xf - -C "$OUT"; do
    _n=$((_n + 1))
    [ "$_n" -ge "$TRIES" ] && { echo "pull failed" >&2; exit 1; }
    sleep 3
done

echo "   $(ls "$OUT" | wc -l | tr -d ' ') fixtures, $(du -sh "$OUT" | cut -f1)"
echo "   NOTE: these carry the device's real IMSI/ICCID/IMEI — never commit them."
