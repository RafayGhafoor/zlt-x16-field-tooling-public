#!/bin/sh
# ipacm-starter.sh -- supervisor for the vendor IPACM daemon.
#
# Problem (v1.0.39.11, ZLT X16 / SDXLEMUR-LITE):
#   /usr/bin/ipacm is exec'd by ipacm.service while the IPA subsystem / modem
#   bring-up is still in progress. It returns -1 (exit code 255) and the unit
#   ends the boot permanently failed, so nothing ever programs IPA:
#   /sys/kernel/debug/ipa/ip{4,6}_{rt,nat,flt} stay empty and all LAN<->WAN
#   forwarding runs as software NAT on the CPU.
#
# This supervisor:
#   * waits for /dev/ipa and /dev/ipaNatTable (not rmnet, which appears later),
#   * runs ipacm in the foreground so the exit code stays meaningful,
#   * retries short (boot-race) runs with exponential backoff,
#   * honours SIGTERM for a clean stop,
#   * records receipt of the WAN RTM_NEWADDR event in a persistent marker,
#   * logs to /data/log/ipacm.log through a FIFO filter -- ipacm dumps ~10
#     conntrack lines per flow plus one log-socket error per line (~570
#     lines/10 s under churn), which is real flash wear on the ubi2_0 volume
#     that also holds /etc. Only WAN-related conntrack lines survive.
#   * trims the log to its newest half once it exceeds MAX_LOG.
#
# Runs as root (setsid/nohup from the vendor boot script); ipacm can manage IPA
# device nodes and netlink. The persistent /data/log directory is created here.

LOG=/data/log/ipacm.log
FIFO=/tmp/ipacm.fifo
MAX_LOG=262144        # 256 KiB, then keep the newest half
MIN_UPTIME=120        # a shorter run counts as a boot race, not a crash
MAX_BACKOFF=30

NOISE_FILTER='
/Received wan ipv4-addr/ {
    print;
    system("touch /data/log/ipacm-wan-learned");
    next;
}
/IPACM_Conntrack/ {
    if ($0 ~ /Received wan|WAN IP/) print;
    next;
}
/Send Failed|^ ATTR_|create ipacm_log socket|ProcessCTMessage|PostEvt\(\)|CmdQueue|EvtDispatcher/ { next }
# Per-flow NAT/FIREWALL debug (6+ lines per connection: AddIface,
# AddORDeleteNatEntry, PopulateTCPorUDPEntry, Private/Target IP, checking
# ipv4_address, ProcessTCPorUDPMsg). These carry no IPACM_Conntrack marker, so
# the rules above never see them and they used to reach `{ print }`.
# Measured 2026-10-26: ~12,900 lines/min (~770 KiB/min) of this, all triggered
# by ordinary browsing from one LAN client -- sustained ubifs writes on the same
# volume as /etc, plus an awk process per line on a 1-core box. They are
# per-connection bookkeeping with no diagnostic value once the flow is known to
# work, so drop them. The WAN marker rule above still fires (it is matched
# first), and real errors (Send Failed, ATTR_) are still dropped only for the
# known-noisy forms.
/AddIface|AddORDeleteNatEntry|PopulateTCPorUDPEntry|ProcessTCPorUDPMsg|checking ipv4_address|Private IP\(|Target IP\(/ { next }
{ print }
'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [starter] $*" >> "$LOG" 2>/dev/null
}

trim() {
    [ -f "$LOG" ] || return 0
    size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "${size:-0}" -gt "$MAX_LOG" ] || return 0
    if tail -c $((MAX_LOG / 2)) "$LOG" > /tmp/ipacm.trim 2>/dev/null; then
        cat /tmp/ipacm.trim > "$LOG" 2>/dev/null   # same inode: writer keeps appending
    fi
    rm -f /tmp/ipacm.trim
}

janitor() {
    while :; do
        sleep 60
        trim
    done
}

wait_ready() {
    n=0
    while [ "$n" -lt 90 ]; do
        if [ -c /dev/ipa ] && [ -c /dev/ipaNatTable ]; then
            [ "$n" -gt 0 ] && log "IPA device nodes ready after $((n * 2))s"
            return 0
        fi
        [ $((n % 5)) -eq 0 ] && log "waiting for IPA devices ($((n * 2))s / 180s)..."
        n=$((n + 1))
        sleep 2
    done
    log "timeout after 180s waiting for IPA; starting ipacm anyway"
    return 0
}

# The vendor unit can start its own /usr/bin/ipacm (same user, so we can kill
# it). Two instances fight over IPA rules, and the supervisor must be the one
# that survives so it keeps the WAN address it learned from rtnetlink.
guard() {
    while :; do
        sleep 10
        for p in $(pidof ipacm 2>/dev/null); do
            [ "$p" = "${CHILD:-}" ] && continue
            log "killing foreign ipacm pid $p"
            kill -9 "$p" 2>/dev/null
        done
    done
}

cleanup() {
    [ -n "${CHILD:-}" ] && kill "$CHILD" 2>/dev/null
    [ -n "${GUARD:-}" ] && kill "$GUARD" 2>/dev/null
    [ -n "${FILTER:-}" ] && kill "$FILTER" 2>/dev/null
    [ -n "${JANITOR:-}" ] && kill "$JANITOR" 2>/dev/null
    rm -f "$FIFO"
    log "stopping (signal)"
    exit 0
}
trap cleanup TERM INT

mkdir -p /data/log 2>/dev/null
rm -f /data/log/ipacm-wan-learned
trim
janitor &
JANITOR=$!

backoff=5
while :; do
    trim
    wait_ready

    # Never run two IPACMs: the vendor unit may have won the boot race.
    OTHER=$(pidof ipacm 2>/dev/null)
    if [ -n "$OTHER" ]; then
        log "an ipacm is already running (pid $OTHER); not starting a second one"
        sleep 15
        continue
    fi

    rm -f "$FIFO"
    if mkfifo "$FIFO" 2>/dev/null; then
        awk "$NOISE_FILTER" < "$FIFO" >> "$LOG" 2>/dev/null &
        FILTER=$!
    else
        FIFO=
        FILTER=
    fi

    log "starting /usr/bin/ipacm${FIFO:+ (filtered)}"
    started=$(date +%s)
    if [ -n "${FIFO:-}" ]; then
        /usr/bin/ipacm > "$FIFO" 2>&1 &
    else
        /usr/bin/ipacm >> "$LOG" 2>&1 &
    fi
    CHILD=$!
    guard &            # keep exactly one ipacm alive
    GUARD=$!
    wait "$CHILD"
    rc=$?
    kill "$GUARD" 2>/dev/null
    GUARD=
    if [ -n "${FILTER:-}" ]; then
        sleep 1
        kill "$FILTER" 2>/dev/null
        FILTER=
    fi
    rm -f "$FIFO"

    runtime=$(( $(date +%s) - started ))
    log "ipacm exited rc=$rc after ${runtime}s"

    if [ "$runtime" -ge "$MIN_UPTIME" ]; then
        # Healthy run then died: a real crash. Exit and let systemd restart us.
        [ "$rc" -eq 255 ] && rc=1
        exit "$rc"
    fi

    log "short run (${runtime}s), retrying in ${backoff}s"
    sleep "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
done
