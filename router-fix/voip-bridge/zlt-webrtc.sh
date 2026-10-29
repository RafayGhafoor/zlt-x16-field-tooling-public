#!/bin/sh
# =============================================================================
# zlt-webrtc.sh — control script for the X16 browser call terminal
# =============================================================================
# Runs on the device. Everything the WebRTC bridge needs to exist at boot is
# here: the TLS certificate, the process lifetime, the boot hook and the status
# report. install.sh only copies files and calls this script.
#
# USAGE: zlt-webrtc.sh {boot|start|stop|restart|status|verify|run|cert|ca|recover|hook-install|hook-remove}
#
# Why the boot hook and not `systemctl enable`: /etc is mounted ~10.6 s into
# boot, after systemd has loaded its unit set, so a unit under
# /etc/systemd/system gets no job on this firmware (AGENTS.md §4). The hook line
# at the top of /etc/initscripts/StartTZApp is what actually starts the bridge;
# the unit exists so an operator can restart it by hand.
# =============================================================================

ROOT=/data/webrtc
BIN="$ROOT/bin"
ETC="$ROOT/etc"
LOG=/data/log/x16-webrtc.log
AUDIO_LOG=/data/log/x16-webrtc-audio.log
PIDFILE=/tmp/x16-webrtc.pid
PORT=8443
PORT_QM=8444
LAN_IP=192.168.3.1
MEDIA_UDP=50000:50100

BOOT_SCRIPT=/etc/initscripts/StartTZApp
BOOT_BACKUP=/etc/initscripts/StartTZApp.pre-webrtc
HOOK_MARK='### Call terminal / WebRTC audio (added by router-fix/voip-bridge; see /data/webrtc/bin/zlt-webrtc.sh)'
HOOK_LINE='/data/webrtc/bin/zlt-webrtc.sh boot >> /data/log/x16-webrtc.log 2>&1 &'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ------------------------------------------------------------------- cert ----
# A self-signed certificate is required, not optional: getUserMedia() only
# exists in a secure context, and http://192.168.3.1 is not one.
#
# The certificate is minted by the bridge binary itself (--gen-cert), not by
# openssl. The device's openssl 1.1.1 applies its own v3_ca section on top of any
# requested extensions, which yields a duplicate basicConstraints and a CA:TRUE
# cert without an EKU — rejected by both Go and the macOS/Safari verifier as
# "certificate is not standards compliant". The Go generator writes exactly the
# extensions a browser needs, and an ECDSA P-256 key pair (cheap on one core).
cert_ok() {
    [ -s "$ETC/server.crt" ] && [ -s "$ETC/server.key" ]
}

gen_cert() {
    mkdir -p "$ETC" || return 1
    [ -x "$BIN/x16-webrtc" ] || { log "bridge binary missing; cannot generate a certificate"; return 1; }
    _force=""
    [ "${1:-}" = "--force" ] && _force="--force-cert"
    _msg=$("$BIN/x16-webrtc" --gen-cert $_force \
        --cert "$ETC/server.crt" --key "$ETC/server.key" --lan-ip "$LAN_IP" 2>&1)
    _rc=$?
    log "certificate: $_msg"
    return $_rc
}

# -------------------------------------------------------------- firewall -----
# TZApp builds the rule set before this hook runs; on this firmware the LAN side
# is accepted, but the media ports are stated explicitly so a vendor rule change
# cannot break audio silently.
open_ports() {
    command -v iptables >/dev/null 2>&1 || return 0
    for _p in "$PORT" "$PORT_QM"; do
        iptables -C INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
    done
    iptables -C INPUT -p udp --dport "$MEDIA_UDP" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p udp --dport "$MEDIA_UDP" -j ACCEPT 2>/dev/null
    return 0
}

# ------------------------------------------------------------- lifecycle -----
running_pid() {
    [ -f "$PIDFILE" ] || return 1
    _p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && echo "$_p"
}

port_open() {
    netstat -ln 2>/dev/null | grep -q ":$PORT "
}

run_foreground() {
    exec "$BIN/x16-webrtc" \
        --addr ":$PORT" \
        --qm-addr ":$PORT_QM" \
        --qm-upstream "http://127.0.0.1:8080" \
        --data "$ROOT" \
        --tap "$BIN/x16-audio" \
        --at /bin/atcmd \
        --dl-port 50006 --ul-port 50005
}

start() {
    mkdir -p "$BIN" "$ETC" /data/log
    gen_cert || log "WARNING: no certificate — the HTTPS listener will refuse to start"
    open_ports

    if _p=$(running_pid); then
        log "already running (pid $_p)"
        return 0
    fi
    if port_open; then
        # A process from an earlier start that the pidfile no longer names (an
        # operator restarting a wedged bridge is the common case). Replace it only
        # if it is OUR binary: killing an unknown listener would be a different
        # bug than the one being fixed.
        _stale=$(ps w 2>/dev/null | grep "$BIN/x16-webrtc --addr" | grep -v grep | awk '{print $1}' | head -1)
        if [ -n "$_stale" ]; then
            log "replacing stale bridge (pid $_stale) still holding :$PORT"
            kill -TERM "$_stale" 2>/dev/null
            _n=0
            while kill -0 "$_stale" 2>/dev/null && [ "$_n" -lt 16 ]; do
                sleep 0.5
                _n=$((_n + 1))
            done
            kill -0 "$_stale" 2>/dev/null && kill -9 "$_stale" 2>/dev/null
            # The bridge's own shutdown is bounded, but the helper can outlive it.
            pkill -f "$BIN/x16-audio --ul-port 50005" 2>/dev/null
            sleep 1
        fi
    fi
    if port_open; then
        log "port $PORT already in use by something else — not starting"
        return 1
    fi

    # The bridge log carries one line per state change, so it grows slowly — but
    # a device that is up for months should not depend on that.
    if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 524288 ]; then
        mv -f "$LOG" "$LOG.1"
    fi

    # Detached, own session, no controlling terminal: the boot hook must not
    # hold StartTZApp open.
    nohup "$0" run >>"$LOG" 2>&1 &
    _pid=$!
    echo "$_pid" >"$PIDFILE"
    sleep 1
    if kill -0 "$_pid" 2>/dev/null; then
        log "started (pid $_pid) on :$PORT"
        return 0
    fi
    log "failed to start — see $LOG"
    rm -f "$PIDFILE"
    return 1
}

stop() {
    if _p=$(running_pid); then
        log "stopping (pid $_p)"
        kill -TERM "$_p" 2>/dev/null
        _n=0
        while kill -0 "$_p" 2>/dev/null && [ "$_n" -lt 20 ]; do
            sleep 0.5
            _n=$((_n + 1))
        done
        kill -0 "$_p" 2>/dev/null && kill -9 "$_p" 2>/dev/null
    else
        log "not running"
    fi
    rm -f "$PIDFILE"
    # The bridge stops the tap on SIGTERM; this is the belt-and-braces sweep for
    # a crashed bridge that left the PCM helper behind. The bridge's own argv
    # contains `--tap $BIN/x16-audio`, so require the helper's `--ul-port` too
    # or pkill can self-match the process that owns the web listeners.
    pkill -f "$BIN/x16-audio --ul-port" 2>/dev/null
    return 0
}

# --------------------------------------------------------------- recover -----
# The vendor PCMIO tap is single-client and alsa_daemon keeps a client that died
# without PCMIO_Close. The visible symptom is a tap that starts, never reports an
# open, and is killed by its own watchdog (exit status 7), so no call audio
# flows. Restarting alsa.service drops the stale client. This is a *voice-only*
# daemon: the data call, QMI and the modem are untouched (docs/22 §6). It must be
# done with no call up, which is why this refuses when one is.
recover() {
    _st=$(timeout 8 /bin/atcmd 'AT+CLCC' 2>/dev/null | tr -d '\r' \
          | sed -n 's/.*+CLCC: *[0-9]*, *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$_st" ]; then
        echo "refusing: a call is up (CLCC state $_st). Hang up first." >&2
        return 1
    fi
    log "restarting alsa.service to drop a stale PCMIO client"
    systemctl restart alsa 2>&1 | sed 's/^/   /'
    sleep 3
    if systemctl is-active alsa >/dev/null 2>&1; then
        log "alsa.service active (pid $(pidof alsa_daemon))"
    else
        log "WARNING: alsa.service is not active — check 'systemctl status alsa'"
        return 1
    fi
    # Drop the bridge's wedge latch by restarting it: it clears on the next call
    # anyway, but an operator-visible restart is easier to reason about.
    "$0" restart >/dev/null 2>&1
    echo "recovered: redial to reopen the tap"
    return 0
}

# ---------------------------------------------------------------- report -----
status() {
    echo "== process =="
    if _p=$(running_pid); then echo "   running, pid $_p"; else echo "   not running (pidfile $PIDFILE)"; fi
    echo "== listener =="
    netstat -ln 2>/dev/null | grep -E ":$PORT |:$PORT_QM " || echo "   nothing on :$PORT or :$PORT_QM"
    echo "== certificate =="
    if [ -s "$ETC/server.crt" ]; then
        openssl x509 -in "$ETC/server.crt" -noout -subject -enddate 2>/dev/null | sed 's/^/   /'
        openssl x509 -in "$ETC/server.crt" -noout -text 2>/dev/null \
            | sed -n '/Subject Alternative Name/,+1p' | tail -1 | sed 's/^ */   SAN:/'
        cert_ok && echo '   present (regenerated by the bridge if unusable)' \
                || echo '   WARNING: missing — the HTTPS listener will refuse connections'
        if [ -s "$ETC/ca.crt" ] && [ -s "$ETC/server.crt" ]; then
            if openssl verify -CAfile "$ETC/ca.crt" "$ETC/server.crt" >/dev/null 2>&1; then
                echo '   chains to the local CA — install /ca.crt once per client to end browser warnings'
            else
                echo '   NOT signed by the local CA (externally provisioned, or stale)'
            fi
            echo "   CA SHA-256: $(openssl x509 -in "$ETC/ca.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
        fi
    else
        echo "   missing"
    fi
    echo "== bridge state =="
    _s=$(curl -sk --max-time 5 "https://127.0.0.1:$PORT/api/state" 2>/dev/null)
    if [ -n "$_s" ]; then echo "   $_s"; else echo "   /api/state did not answer"; fi
    echo "== pcm tap =="
    # match the helper's own argv, not the bridge's "--tap .../x16-audio" flag
    ps w | grep "[x]16-audio --ul-port" | sed 's/^/   /' || echo "   not running (expected while no call is answered)"
    echo "== boot hook =="
    if grep -qF "$HOOK_MARK" "$BOOT_SCRIPT" 2>/dev/null; then echo "   wired in $BOOT_SCRIPT"; else echo "   NOT WIRED"; fi
    echo "== last log lines =="
    tail -n 8 "$LOG" 2>/dev/null | sed 's/^/   /'
}

verify() {
    _fail=0
    running_pid >/dev/null || { echo "FAIL: bridge not running"; _fail=1; }
    port_open || { echo "FAIL: nothing listening on :$PORT"; _fail=1; }
    [ -s "$ETC/server.crt" ] || { echo "FAIL: no certificate"; _fail=1; }
    [ -s "$ETC/ca.crt" ] || { echo "FAIL: no local CA (run: zlt-webrtc.sh ca)"; _fail=1; }
    if [ -s "$ETC/ca.crt" ] && [ -s "$ETC/server.crt" ]; then
        openssl verify -CAfile "$ETC/ca.crt" "$ETC/server.crt" >/dev/null 2>&1 \
            || { echo "FAIL: leaf does not chain to the local CA"; _fail=1; }
    fi
    _ca=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:$PORT_QM/ca.crt" 2>/dev/null)
    [ "$_ca" = "200" ] || { echo "FAIL: /ca.crt not served ($_ca)"; _fail=1; }
    grep -qF "$HOOK_MARK" "$BOOT_SCRIPT" 2>/dev/null || { echo "FAIL: boot hook missing"; _fail=1; }
    [ -x "$BIN/x16-audio" ] || { echo "FAIL: tap binary missing"; _fail=1; }

    _code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:$PORT/" 2>/dev/null)
    [ "$_code" = "200" ] || { echo "FAIL: UI over HTTPS returned $_code"; _fail=1; }

    # The QManager front: the Calls page lives in QManager's own export, so this
    # listener is what gives it a secure context (and therefore a microphone).
    _qm=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:$PORT_QM/cellular/calls/" 2>/dev/null)
    [ "$_qm" = "200" ] || { echo "FAIL: QManager Calls page over HTTPS returned $_qm"; _fail=1; }
    _api=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:$PORT_QM/callapi/state" 2>/dev/null)
    [ "$_api" = "200" ] || { echo "FAIL: /callapi/state through the QManager origin returned $_api"; _fail=1; }
    _state=$(curl -sk --max-time 5 "https://127.0.0.1:$PORT/api/state" 2>/dev/null)
    case "$_state" in
        *'"call"'*) : ;;
        *) echo "FAIL: /api/state did not return JSON"; _fail=1 ;;
    esac
    [ "$_fail" -eq 0 ] && echo "OK: :$PORT standalone UI 200, :$PORT_QM QManager + /callapi 200, state JSON, hook wired"
    return $_fail
}

# -------------------------------------------------------------- boot hook ----
# Inserted directly above the QManager hook when present (so the QManager units
# come up first), else above start_lan_mgr. Never appended: the vendor runs one
# case block, so lines after it do not execute.
hook_install() {
    [ -f "$BOOT_SCRIPT" ] || { log "$BOOT_SCRIPT missing"; return 1; }
    if grep -qF "$HOOK_MARK" "$BOOT_SCRIPT"; then
        log "boot hook already wired"
        return 0
    fi
    [ -f "$BOOT_BACKUP" ] || cp -f "$BOOT_SCRIPT" "$BOOT_BACKUP"

    _tab=$(printf '\t')
    awk -v mark="${_tab}$HOOK_MARK" -v line="${_tab}$HOOK_LINE" '
        placed == 0 && index($0, "start_qmanager start") { print mark; print line; print; placed = 1; next }
        { print }
    ' "$BOOT_SCRIPT" > "$BOOT_SCRIPT.new" || return 1

    if ! grep -qF "$HOOK_LINE" "$BOOT_SCRIPT.new"; then
        awk -v mark="${_tab}$HOOK_MARK" -v line="${_tab}$HOOK_LINE" '
            placed == 0 && index($0, "start_lan_mgr start") { print mark; print line; print; placed = 1; next }
            { print }
        ' "$BOOT_SCRIPT" > "$BOOT_SCRIPT.new" || return 1
    fi
    grep -qF "$HOOK_LINE" "$BOOT_SCRIPT.new" || { rm -f "$BOOT_SCRIPT.new"; log "no anchor in $BOOT_SCRIPT"; return 1; }

    sh -n "$BOOT_SCRIPT.new" || { rm -f "$BOOT_SCRIPT.new"; log "edited $BOOT_SCRIPT would not parse; vendor file left alone"; return 1; }
    cat "$BOOT_SCRIPT.new" > "$BOOT_SCRIPT" && rm -f "$BOOT_SCRIPT.new"
    log "boot hook wired into $BOOT_SCRIPT (vendor copy: $BOOT_BACKUP)"
    return 0
}

hook_remove() {
    [ -f "$BOOT_SCRIPT" ] || return 0
    grep -qF "$HOOK_MARK" "$BOOT_SCRIPT" || { log "no boot hook present"; return 0; }
    awk -v mark="$HOOK_MARK" -v line="$HOOK_LINE" '
        index($0, mark) { skip = 1; next }
        skip == 1 { skip = 0; if (index($0, line)) next }
        { print }
    ' "$BOOT_SCRIPT" > "$BOOT_SCRIPT.new" || return 1
    sh -n "$BOOT_SCRIPT.new" || { rm -f "$BOOT_SCRIPT.new"; log "unwired file would not parse"; return 1; }
    cat "$BOOT_SCRIPT.new" > "$BOOT_SCRIPT" && rm -f "$BOOT_SCRIPT.new"
    log "boot hook removed from $BOOT_SCRIPT"
    return 0
}

# ------------------------------------------------------------------- main ----
case "${1:-status}" in
    boot)
        # boot path: idempotent, never blocks StartTZApp.
        #
        # WHY systemd FIRST. /etc is mounted ~10.6 s into boot, after systemd has
        # already loaded its unit set, so this unit is unknown at that moment and
        # the hook had to spawn the binary directly — which left an ORPHAN: the
        # process ran, `systemctl is-active` said inactive, and nothing supervised
        # it (verified after the 2026-10-28 reboot: pid 2015 serving :8443 with
        # MainPID=0). A daemon-reload here is what makes systemd learn the unit
        # that has been on disk all along; after it, `systemctl start` gives the
        # bridge Restart=on-failure and a real MainPID.
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload 2>/dev/null
            if systemctl start zlt-webrtc 2>/dev/null; then
                sleep 1
                if systemctl is-active zlt-webrtc >/dev/null 2>&1; then
                    log "started under systemd (hook)"
                    exit 0
                fi
            fi
            log "systemd start refused at boot; falling back to a detached spawn"
        fi
        start
        ;;
    start)  start ;;
    stop)   stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    verify) verify ;;
    run)    run_foreground ;;
    cert)   gen_cert "${2:-}" && echo "leaf present: $ETC/server.crt" ;;
    ca)
        # Publish the root: install this once on a phone or laptop and every page
        # here is trusted (no warning, microphone allowed, no repeated clicks).
        [ -s "$ETC/ca.crt" ] || gen_cert || exit 1
        echo "root CA:        $ETC/ca.crt"
        echo "download:       https://$LAN_IP:$PORT_QM/ca.crt"
        echo "SHA-256:        $(openssl x509 -in "$ETC/ca.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
        echo "leaf SANs:      $(openssl x509 -in "$ETC/server.crt" -noout -text 2>/dev/null | sed -n '/Subject Alternative Name/,+1p' | tail -1 | sed 's/^ *//')"
        echo
        echo "Install it once per client:"
        echo "  macOS/iOS: open the file -> Keychain/Profile -> trust it for SSL"
        echo "  Windows:   import into 'Trusted Root Certification Authorities'"
        echo "  Linux:     cp to /usr/local/share/ca-certificates/ && update-ca-certificates"
        echo "  Firefox:   Settings -> Privacy & Security -> Certificates -> Import"
        echo "  Chrome:    uses the OS store (macOS/Windows/Linux)"
        ;;
    recover) recover ;;
    hook-install) hook_install ;;
    hook-remove)  hook_remove ;;
    *) echo "usage: $0 {boot|start|stop|restart|status|verify|run|cert|ca|recover|hook-install|hook-remove}" >&2; exit 1 ;;
esac
