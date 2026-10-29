#!/bin/sh
# zlt-ipacm.sh -- controller for the IPACM supervisor (router-fix/ipacm/)
#
#   boot      start the supervisor if it is not running (used by the boot hook)
#   start     same, for manual use
#   reassert  restart a dead supervisor (scheduled 90 s after boot)
#   status    report supervisor / ipacm / vendor unit state
#   stop      stop everything and let software routing take over again
#
# The supervisor is deliberately NOT a systemd unit. Two reasons:
#   * / (rootfs) is read-only and the writable /etc volume is mounted ~10 s into
#     boot, AFTER systemd has loaded its units, so a unit or drop-in under
#     /etc/systemd/system is invisible during that boot;
#   * `systemd-run` is rejected until the initial boot transaction settles
#     ("Transaction ... is destructive (shutdown.target has 'start' job
#     queued)"), which is ~36 s -- far too late: ipacm must be running before
#     the dialer assigns the WAN address (~27 s) or it misses the rtnetlink
#     RTM_NEWADDR event that tells it the WAN IP.
# So it is spawned detached with setsid(1) from the boot hook and tracked with
# a pidfile. The supervisor itself restarts ipacm on failure.

STARTER=/etc/initscripts/ipacm-starter.sh
PIDFILE=/var/run/zlt-ipacm.pid
BOOTLOG=/data/log/zlt-ipacm-boot.log

say() { echo "[zlt-ipacm] $*" >>"$BOOTLOG" 2>/dev/null; echo "[zlt-ipacm] $*" >&2; }

alive() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    return 0
}

kill_vendor() {
    # The vendor unit (or its udev rule) may have started /usr/bin/ipacm in the
    # boot race. Two instances fight over IPA rules; the supervisor must win.
    systemctl stop ipacm.service 2>/dev/null
    systemctl reset-failed ipacm.service 2>/dev/null
    n=0
    while [ "$n" -lt 10 ] && pidof ipacm >/dev/null 2>&1; do
        killall ipacm 2>/dev/null
        n=$((n + 1))
        sleep 1
    done
    [ "$n" -gt 0 ] && say "cleared a vendor ipacm after ${n}s"
    return 0
}

spawn() {
    if alive; then
        say "supervisor already running (pid $(cat "$PIDFILE"))"
        return 0
    fi
    kill_vendor
    mkdir -p /data/log 2>/dev/null
    chown radio:radio /data/log 2>/dev/null
    setsid nohup "$STARTER" >>"$BOOTLOG" 2>&1 &
    echo $! >"$PIDFILE"
    say "spawned supervisor pid $(cat "$PIDFILE")"
    return 0
}

case "$1" in
boot | start | reassert)
    spawn
    ;;

status)
    if alive; then
        printf 'supervisor   running (pid %s)\n' "$(cat "$PIDFILE")"
    else
        printf 'supervisor   stopped\n'
    fi
    printf 'ipacm        %s\n' "$(pidof ipacm 2>/dev/null || echo none)"
    printf 'vendor unit  %s\n' "$(systemctl is-active ipacm.service 2>/dev/null)"
    ;;

stop)
    if alive; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        sleep 2
        kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    killall ipacm 2>/dev/null
    say "stopped"
    exit 0
    ;;

*)
    echo "usage: $0 {boot|start|reassert|status|stop}" >&2
    exit 2
    ;;
esac
