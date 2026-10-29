#!/bin/sh
# =============================================================================
# qm_serve.sh — run the QManager web UI on port 8080 (ZLT X16)
# =============================================================================
# Adapted from QManager's deploy/qm_serve.sh (GreenPacket). Port 8080 is
# deliberate: :80 and :443 are the vendor UI (/bin/mini_httpd), which is left
# untouched. busybox 1.31 httpd supports CGI natively and is already on the
# device, so no packages are installed.
#
# httpd runs as ROOT (no -u): CGI helpers write /etc/qmanager and must reach
# the modem through /bin/atcmd. /data/qmanager/bin/sudo is a passthrough shim.
#
# Usage: qm_serve.sh {start|stop|restart|status}
# =============================================================================
set -u

QM_ROOT=/data/qmanager
PORT="${QM_PORT:-8080}"
PIDFILE=/run/qmanager-httpd.pid
DOCROOT="$QM_ROOT/www"

PATH="$QM_ROOT/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

check_root() {
    [ -d "$DOCROOT" ] || { echo "missing docroot: $DOCROOT" >&2; exit 1; }
    [ -d "$DOCROOT/cgi-bin/quecmanager" ] || {
        echo "missing CGI tree under $DOCROOT/cgi-bin" >&2; exit 1; }
}

is_running() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    return 0
}

# busybox httpd writes no pidfile; find it by the exact argv we passed.
# The pattern is assembled at runtime so this script cannot match itself.
find_pids() {
    pattern="httpd -p $PORT -h $DOCROOT"
    ps w 2>/dev/null | grep -F "$pattern" | grep -v grep | awk '{print $1}'
}

do_stop() {
    if is_running; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        kill "$pid" 2>/dev/null
        sleep 1
        kill -9 "$pid" 2>/dev/null
    fi
    for p in $(find_pids); do
        [ "$p" = "$$" ] && continue
        kill "$p" 2>/dev/null
    done
    rm -f "$PIDFILE"
    echo "stopped"
}

do_start() {
    check_root
    if is_running; then
        echo "already running (pid $(cat "$PIDFILE")) on port $PORT"
        return 0
    fi
    do_stop >/dev/null 2>&1

    busybox httpd -p "$PORT" -h "$DOCROOT" >/dev/null 2>&1 </dev/null

    for p in $(find_pids); do
        printf '%s\n' "$p" > "$PIDFILE"
        break
    done

    sleep 1
    if netstat -tln 2>/dev/null | grep -q ":$PORT "; then
        echo "listening on port $PORT (pid $(cat "$PIDFILE" 2>/dev/null))"
    else
        echo "failed to bind port $PORT" >&2
        exit 1
    fi
}

do_status() {
    if is_running; then
        echo "running (pid $(cat "$PIDFILE")) on port $PORT"
    else
        echo "stopped"
    fi
}

case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)  do_status ;;
    *) echo "usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
