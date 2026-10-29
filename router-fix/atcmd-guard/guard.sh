#!/bin/sh
# =============================================================================
# zlt-atcmd-guard.sh — keep `atcmd_daemon`'s AT channel actually working
# =============================================================================
# WHAT THIS FIXES (decompiled + measured 2026-10-29, docs/38 §1)
#
#   atcmd_daemon owns /dev/smd8 (AT commands + replies) and, when cfg
#   `SYS_VOLTE_SW` is "1", reads indications from /dev/smd9 in `read_tty_thread`.
#   On a read error that thread closes the descriptor and loops
#
#       do { usleep(100000); fd = open("/dev/smd3", O_RDWR); } while (fd < 0);
#
#   — and **/dev/smd3 does not exist on this firmware** (it has smd7..smd11,
#   smd21, smd22, smd38, smdcntl0/1/8). So one bad read parks the thread at 10 Hz
#   forever, and it does not log while looping. AT keeps answering, so the UI
#   looks healthy; what silently stops is every URC: call state, SMS delivery,
#   USSD. Nothing on the box supervises that thread.
#
# WHAT IT CHECKS — two structural signals, no AT traffic in the steady state:
#
#   1. the process exists at all;
#   2. it still holds /dev/smd9 open, once it has been seen holding it.
#
#   (2) is self-calibrating rather than cfg-driven: the first healthy run records
#   `smd9.expected` in the state dir, so a unit with VoLTE off — where no such
#   reader ever exists — is never mistaken for a broken one. When the marker is
#   absent and the fd is missing, the daemon log is asked for the one line the
#   vendor does emit before the loop starts (`try to reopen pty devices`), and it
#   takes that line to restart; without it, VoLTE-off is assumed and recorded.
#
# RECOVERY is the documented recipe (docs/05, docs/33) — the daemon owns no PDP
# context, so this does not disturb the dialer or the WAN:
#
#       kill -9 <pid> ; setsid /etc/initscripts/start_atcmd_daemon start
#
# RATE LIMIT: one restart per COOLDOWN, at most MAX_PER_HOUR, then it logs
# "suppressed" instead. A guard that restarts in a loop is worse than the bug.
#
# Silent when healthy — one pgrep, one readlink per fd, one `cat /proc/uptime`.
# =============================================================================
set -u

PROC=${GUARD_PROC:-/proc}
PGREP=${GUARD_PGREP:-pgrep}
START=${GUARD_START:-/etc/initscripts/start_atcmd_daemon}
STATE=${GUARD_STATE:-/data/zlt-atcmd-guard}
LOGDIR=${GUARD_LOGDIR:-/data/log}
DAEMON_LOG=${GUARD_DAEMON_LOG:-/tmp/logs/ATCMD_DAEMON.log}
SMD9=${GUARD_SMD9:-/dev/smd9}         # the indication node (overridable for tests)
MIN_AGE=${GUARD_MIN_AGE:-60}          # seconds before a young daemon is judged
COOLDOWN=${GUARD_COOLDOWN:-900}       # seconds between restarts
MAX_PER_HOUR=${GUARD_MAX_PER_HOUR:-3}
WAIT=${GUARD_WAIT:-20}                # seconds to wait for a restarted daemon
DRY_RUN=${GUARD_DRY_RUN:-0}

LOG=$LOGDIR/zlt-atcmd-guard.log
MARK=$STATE/smd9.expected
STAMPS=$STATE/restarts

mkdir -p "$STATE" "$LOGDIR" 2>/dev/null

log() {
    # one line per event it acted on, with the time — this file is the only
    # record that the daemon was restarted, because journald does not persist.
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# daemon_pid -> stdout: pid or empty
#
# `pgrep -f '^atcmd_daemon$'` matches argv[0] exactly: the string also appears in
# start_atcmd_daemon's own command line and in this guard's path, so a looser
# match would find the wrong thing.
daemon_pid() {
    "$PGREP" -f '^atcmd_daemon$' 2>/dev/null | head -1
}

# holds_smd9 <pid> -> rc 0 when any fd of <pid> links to /dev/smd9
#
# By link target, not by number: fd order depends on boot state, and 5/6 were only
# the observed values on one boot.
holds_smd9() {
    for l in "$PROC/$1"/fd/*; do
        [ -e "$l" ] || continue
        case "$(readlink "$l" 2>/dev/null)" in
            "$SMD9") return 0 ;;
        esac
    done
    return 1
}

# age_of <pid> -> seconds the process has been alive (0 when unknown)
age_of() {
    # starttime is field 22 of /proc/<pid>/stat, i.e. field 20 after the comm field
    # (which may itself contain spaces and parentheses — hence the sub()).
    st=$(awk '{ sub(/^.*\) /,"") ; print $20 }' "$PROC/$1/stat" 2>/dev/null)
    [ -n "${st:-}" ] || { echo 9999 ; return 0 ; }
    up=$(awk '{print int($1)}' "$PROC/uptime" 2>/dev/null || echo 9999)
    echo $((up - st))
}

# log_says_urc_thread_failed -> rc 0 when the daemon recorded the reopen failure
#
# This is the one line the vendor writes *before* entering the silent loop, so it
# turns "no /dev/smd9 fd" from ambiguous into evidence.
log_says_urc_thread_failed() {
    [ -f "$DAEMON_LOG" ] || return 1
    grep -q 'try to reopen pty devices' "$DAEMON_LOG" 2>/dev/null
}

# recent_restarts -> stdout: two numbers: "since_last youngest_age_seconds"
recent_restarts() {
    [ -f "$STAMPS" ] || { echo "-1 999999" ; return 0 ; }
    now=$(date +%s)
    keep='' ; last=-1 ; young=999999
    while IFS= read -r t || [ -n "$t" ]; do
        case "$t" in ''|*[!0-9]*) continue ;; esac
        age=$((now - t))
        [ "$age" -gt 3600 ] && continue
        keep="$keep$t\n"
        last=$t
        [ "$age" -lt "$young" ] && young=$age
    done < "$STAMPS"
    [ -n "$keep" ] && printf "$keep" > "$STAMPS"
    echo "$last $young"
}

record_restart() {
    date +%s >> "$STAMPS" 2>/dev/null
}

# restart_daemon <reason>
restart_daemon() {
    pid=$1 ; reason=$2
    set -- $(recent_restarts)
    last=$1 ; young=$2
    if [ "$last" != "-1" ] && [ "$young" -lt "$COOLDOWN" ]; then
        log "SUPPRESSED restart (reason=$reason): last restart ${young}s ago, cooldown ${COOLDOWN}s"
        return 0
    fi
    n=$(grep -c . "$STAMPS" 2>/dev/null || echo 0)
    if [ "${n:-0}" -ge "$MAX_PER_HOUR" ]; then
        log "SUPPRESSED restart (reason=$reason): ${n} restarts in the last hour, limit ${MAX_PER_HOUR}"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "WOULD restart (reason=$reason, pid=$pid) [dry run]"
        return 0
    fi
    log "RESTART (reason=$reason, pid=$pid): kill -9 + start_atcmd_daemon"
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    sleep 1
    # Detached: this script exits immediately after, and the daemon must outlive
    # its cgroup (the unit is Type=oneshot — the ipacm module learned this).
    # setsid is the device's own recipe; the fallback exists so the host test can
    # exercise this path on a machine that has no setsid(1).
    if command -v setsid >/dev/null 2>&1; then
        setsid "$START" start >/dev/null 2>&1 &
    else
        "$START" start >/dev/null 2>&1 &
    fi
    i=0
    while [ "$i" -lt "$WAIT" ]; do
        i=$((i + 1))
        sleep 1
        new=$(daemon_pid)
        if [ -n "$new" ]; then
            record_restart
            # The process appears before it has opened /dev/smd9 (it opens /dev/smd8,
            # reads SYS_VOLTE_SW, then starts the reader) — measured 2026-10-29: the
            # fd lands ~1-2 s after the pid, so a single check reports PARTIAL on a
            # recovery that actually worked. Give it 3 more seconds before judging.
            j=0
            while [ "$j" -lt 3 ] && ! holds_smd9 "$new" 2>/dev/null; do
                j=$((j + 1)) ; sleep 1
            done
            if holds_smd9 "$new" 2>/dev/null; then
                : > "$MARK" 2>/dev/null || touch "$MARK" 2>/dev/null
                log "OK pid=$new holds /dev/smd9 again (after $((i + j))s)"
            else
                log "PARTIAL pid=$new is up but holds no /dev/smd9 fd (after $((i + j))s) — URCs may still be dead"
            fi
            return 0
        fi
    done
    record_restart
    log "FAILED: no atcmd_daemon ${i}s after restart -- AT is DOWN; manual recovery: kill -9 \$(pgrep -f '^atcmd_daemon$'); setsid $START start"
    return 1
}

# ---------------------------------------------------------------------------
pid=$(daemon_pid)

if [ -z "$pid" ]; then
    log "atcmd_daemon is not running"
    restart_daemon '' 'daemon-absent'
    exit 0
fi

# Give a daemon that has just started time to open /dev/smd9 on its own.
age=$(age_of "$pid")
if [ "$age" -lt "$MIN_AGE" ]; then
    exit 0
fi

if holds_smd9 "$pid"; then
    # Healthy. Record the baseline once so a later absence is unambiguous.
    [ -f "$MARK" ] || { : > "$MARK" 2>/dev/null ; }
    exit 0
fi

# No /dev/smd9 fd. Three cases, and only two of them are ours to repair.
if [ -f "$MARK" ]; then
    restart_daemon "$pid" 'urc-thread-lost'
    exit 0
fi

# No baseline yet. If /dev/smd9 is not even a device, there is no reader to lose
# (VoLTE off) — that is a healthy configuration, not a fault.
if [ ! -e "$SMD9" ]; then
    exit 0
fi

# /dev/smd9 exists and this boot has no baseline. The daemon's own log decides:
# the vendor writes the reopen failure before entering the silent loop.
if log_says_urc_thread_failed; then
    restart_daemon "$pid" 'urc-thread-lost-log'
    exit 0
fi

# Ambiguous and not our call: assume VoLTE is off for this boot and stay silent.
# (Restarting here would be a guess, and a needless restart costs a second of AT.)
exit 0
