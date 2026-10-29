#!/bin/sh
# =============================================================================
# install.sh — browser call terminal for the ZLT X16 (VoLTE audio over WebRTC)
# =============================================================================
# Host-side installer. Run from your workstation, not on the router.
#
# What lands on the device, and why each piece exists:
#
#   /data/webrtc/bin/x16-audio        the PCMIO call-audio pump. The X16 has no
#                                     ALSA call device (card 0 is stub/dummy
#                                     only), so call audio is reached through the
#                                     vendor tap libolinterface.so.1 ->
#                                     alsa_daemon. This binary turns that into
#                                     two loopback UDP PCM streams.
#   /data/webrtc/bin/x16-webrtc       the WebRTC bridge: PCMU in/out, call
#                                     control through /bin/atcmd, and the page.
#   /data/webrtc/bin/zlt-webrtc.sh    cert generation, start/stop, status and
#                                     the boot-hook plumbing.
#   /data/webrtc/etc/server.crt|.key  self-signed TLS: getUserMedia() needs a
#                                     secure context and the page is on a LAN IP.
#   /etc/systemd/system/zlt-webrtc.service
#                                     for `systemctl restart zlt-webrtc`; it is
#                                     NOT what starts the bridge at boot.
#   /etc/initscripts/StartTZApp      + one hook line, because units under
#                                     /etc/systemd/system get no boot job on this
#                                     firmware (AGENTS.md §4).
#
# Nothing vendor-owned is replaced. The only file edited in place is
# /etc/initscripts/StartTZApp, backed up before the first edit.
#
# Usage:
#   ./install.sh              # build, deploy, start, verify   (alias: --install)
#   ./install.sh --check      # verify only, change nothing
#   ./install.sh --uninstall  # stop, unwire, remove
#   ./install.sh --build-only # cross-build bin/ without touching the device
#
# Environment:
#   ZLT_HOST     ssh target              (default: zlt-x16-root)
#   ZLT_TRIES    ssh attempts per call   (default: 8; this link drops often)
#   ZLT_PORT     HTTPS port              (default: 8443)
#
# Device quirks absorbed here (AGENTS.md §1/§4):
#   * scp fails (dropbear has no sftp-server)  -> stream with `ssh 'cat > dst'`
#   * the link drops connections regularly     -> every ssh call retries
#   * `systemctl enable` is not a boot guarantee -> the StartTZApp hook is
#   * /data is small and slow                  -> binaries go to /data/webrtc,
#                                                 logs to /data/log, both capped
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-8}"
PORT="${ZLT_PORT:-8443}"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=/data/webrtc
BIN="$ROOT/bin"
BACKUP_ROOT="/data/zlt-backups/$(date +%Y%m%d)/voip-bridge"
BOOT_SCRIPT=/etc/initscripts/StartTZApp
UNIT=zlt-webrtc.service
HOOK_MARK='### Call terminal / WebRTC audio (added by router-fix/voip-bridge'

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $* =="; }

# ---------------------------------------------------------------- transport --
ssh_try() {
    n=0
    while [ "$n" -lt "$TRIES" ]; do
        if out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$1" 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        n=$((n + 1))
        sleep 3
    done
    printf '%s\n' "$out" >&2
    return 1
}

# Pushed gzipped: the Go binary is ~10 MB and dropbear on this link drops the
# connection often enough that a plain stream routinely fails. gunzip refuses a
# truncated stream, so the move only happens once the bytes are all there.
push() {
    n=0
    while [ "$n" -lt "$TRIES" ]; do
        if gzip -c "$1" | ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
                "gunzip > '$2.part' && mv -f '$2.part' '$2'" 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        sleep 3
    done
    return 1
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ------------------------------------------------------------------ build -----
build_only() {
    say "cross-building (zig for the C pump, go for the bridge)"
    ( cd "$SRC_DIR" && ./build.sh ) || die "build failed"
}

# ------------------------------------------------------------------ check -----
check() {
    say "service state"
    ssh_try "'$BIN/zlt-webrtc.sh' status" || die "status failed on the device"

    say "from the LAN side (what a browser will do)"
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://192.168.3.1:$PORT/" 2>/dev/null)
    echo "  HTTPS https://192.168.3.1:$PORT/ -> ${code:-no answer}"
    [ "$code" = "200" ] || echo "  NOTE: not 200 — check the firewall and that the bridge is running"

    say "boot wiring"
    ssh_try "grep -n -A1 'Call terminal / WebRTC audio' '$BOOT_SCRIPT' | sed 's/^/  /'" || echo "  NOT WIRED"
    ssh_try "systemctl is-enabled $UNIT 2>/dev/null | sed 's/^/  unit: /'"
}

# --------------------------------------------------------------- uninstall ----
uninstall() {
    say "stopping and removing"
    ssh_try "
        systemctl stop $UNIT >/dev/null 2>&1
        systemctl disable $UNIT >/dev/null 2>&1
        [ -x '$BIN/zlt-webrtc.sh' ] && '$BIN/zlt-webrtc.sh' stop
        [ -x '$BIN/zlt-webrtc.sh' ] && '$BIN/zlt-webrtc.sh' hook-remove
        rm -f '/etc/systemd/system/$UNIT'
        systemctl daemon-reload >/dev/null 2>&1
        # Keep the certificate and the logs: they are useful if the module comes
        # back, and neither is vendor state.
        rm -f '$BIN/x16-webrtc' '$BIN/x16-audio' '$BIN/zlt-webrtc.sh'
        sh -n '$BOOT_SCRIPT' && echo 'StartTZApp parses'
        echo 'uninstalled'
    " || die "uninstall failed"

    echo
    echo "Certificates kept at $ROOT/etc/, logs at /data/log/x16-webrtc*.log."
    echo "The vendor StartTZApp copy, if this was the first edit, is at"
    echo "  $BOOT_SCRIPT.pre-webrtc"
}

# ----------------------------------------------------------------- install ----
install() {
    say "target"
    ssh_try 'uname -n; uname -m; uptime | sed "s/^/   /"' || die "cannot reach $HOST (ZLT_HOST=$HOST)"

    if [ ! -x "$SRC_DIR/bin/x16-audio" ] || [ ! -x "$SRC_DIR/bin/x16-webrtc" ]; then
        build_only
    else
        say "using existing build in $SRC_DIR/bin (delete it or run --build-only to rebuild)"
    fi
    [ -x "$SRC_DIR/bin/x16-audio" ] || die "missing bin/x16-audio"
    [ -x "$SRC_DIR/bin/x16-webrtc" ] || die "missing bin/x16-webrtc"

    say "device preflight"
    ssh_try "
        test -f /usr/lib/libolinterface.so.1.0.0 && echo '   tap library: present' || echo '   tap library: MISSING'
        test -x /usr/bin/alsa_daemon && echo '   alsa_daemon: present' || echo '   alsa_daemon: MISSING'
        test -x /bin/atcmd && echo '   atcmd: present' || echo '   atcmd: MISSING'
        command -v openssl >/dev/null && echo \"   openssl: \$(openssl version | cut -d' ' -f1-2)\" || echo '   openssl: MISSING (cert step will fail)'
        command -v curl >/dev/null && echo '   curl: present' || echo '   curl: MISSING'
        echo \"   free: \$(free -m | awk '/Mem:/{print \$7\" MB available\"}')\"
    " || die "preflight failed"

    say "backing up what this module touches"
    ssh_try "
        mkdir -p '$BACKUP_ROOT/bin' '$BACKUP_ROOT/etc'
        cp -f '$BOOT_SCRIPT' '$BACKUP_ROOT/StartTZApp' 2>/dev/null
        [ -f '/etc/systemd/system/$UNIT' ] && cp -f '/etc/systemd/system/$UNIT' '$BACKUP_ROOT/' 2>/dev/null
        # Keep the pre-update payload byte-for-byte before replacing it. This
        # makes a failed WebRTC/multi-peer change reversible without asking the
        # browser to find an older build or changing call/modem state.
        # Preserve every existing payload/certificate byte-for-byte before an
        # upgrade. The service is restarted after upload; this directory is the
        # rollback if a new build fails its read-only verification.
        for f in x16-audio x16-webrtc zlt-webrtc.sh; do
            [ ! -f '$BIN/'\$f ] || cp -f '$BIN/'\$f '$BACKUP_ROOT/bin/'\$f
        done
        for f in server.crt server.key ca.crt ca.key; do
            [ ! -f '$ROOT/etc/'\$f ] || cp -f '$ROOT/etc/'\$f '$BACKUP_ROOT/etc/'\$f
        done
        echo '   $BACKUP_ROOT:' \$(find '$BACKUP_ROOT' -type f | sed 's|^|   |')
    " || die "backup failed"

    say "installing binaries"
    ssh_try "mkdir -p '$BIN' '$ROOT/etc' /data/log" || die "could not create $ROOT"
    push "$SRC_DIR/bin/x16-audio"  "$BIN/x16-audio"  || die "push of x16-audio failed"
    push "$SRC_DIR/bin/x16-webrtc" "$BIN/x16-webrtc" || die "push of x16-webrtc failed"
    push "$SRC_DIR/zlt-webrtc.sh"  "$BIN/zlt-webrtc.sh" || die "push of zlt-webrtc.sh failed"
    ssh_try "chmod 755 '$BIN/x16-audio' '$BIN/x16-webrtc' '$BIN/zlt-webrtc.sh'
        chown root:root '$BIN/x16-audio' '$BIN/x16-webrtc' '$BIN/zlt-webrtc.sh'
        echo \"   audio:  \$(sha256sum '$BIN/x16-audio'  | cut -c1-16)\"
        echo \"   webrtc: \$(sha256sum '$BIN/x16-webrtc' | cut -c1-16)\"" || die "chmod failed"
    echo "   local:"
    echo "   audio:  $(sha256_of "$SRC_DIR/bin/x16-audio" | cut -c1-16)"
    echo "   webrtc: $(sha256_of "$SRC_DIR/bin/x16-webrtc" | cut -c1-16)"

    say "certificate (self-signed; required for getUserMedia)"
    ssh_try "'$BIN/zlt-webrtc.sh' cert" || die "certificate step failed"

    say "unit + boot hook"
    push "$SRC_DIR/$UNIT" "/etc/systemd/system/$UNIT" || die "push of unit failed"
    ssh_try "
        systemctl daemon-reload
        systemctl enable $UNIT >/dev/null 2>&1
        echo '   unit installed (starting it is the hook job)'" || die "unit install failed"

    ssh_try "'$BIN/zlt-webrtc.sh' hook-install" || die "could not wire the boot hook"
    ssh_try "sh -n '$BOOT_SCRIPT' && grep -n -A1 'Call terminal / WebRTC audio' '$BOOT_SCRIPT' | sed 's/^/   /'" \
        || die "boot hook is not in $BOOT_SCRIPT"

    say "restarting the updated bridge (the StartTZApp hook remains the boot path)"
    ssh_try "'$BIN/zlt-webrtc.sh' restart" || die "restart failed — see /data/log/x16-webrtc.log"

    say "verifying on the device"
    ssh_try "'$BIN/zlt-webrtc.sh' verify" || die "verify failed"

    say "firewall rules present"
    ssh_try "iptables -S INPUT 2>/dev/null | grep -E '$PORT|50000:50100' | sed 's/^/   /'" \
        || echo "   (iptables not readable here; the LAN side accepts by default on this firmware)"

    echo
    echo "Open  https://192.168.3.1:$PORT  (accept the self-signed certificate once)"
    echo "  1. Connect audio  -> grants the browser microphone, opens the WebRTC link"
    echo "  2. Dial a number  -> the tap opens by itself the moment the call is answered"
    echo "  Both directions run at 8 kHz G.711/PCMU: no transcoding, no resampling."
    echo
    echo "Prove the boot hook (AGENTS.md §6): reboot, then"
    echo "  ssh $HOST '$BIN/zlt-webrtc.sh' status"
    echo "Rollback: ./install.sh --uninstall"
}

# -------------------------------------------------------------------- main ----
case "${1:---install}" in
    --install|"") install ;;
    --check)     check ;;
    --uninstall) uninstall ;;
    --build-only) build_only ;;
    *) die "usage: $0 [--install|--check|--uninstall|--build-only]" ;;
esac
