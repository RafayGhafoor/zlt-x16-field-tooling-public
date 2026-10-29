#!/bin/sh
# =============================================================================
# install.sh -- deploy the IPACM supervisor to a ZLT X16
# =============================================================================
# Host-side installer (run from your workstation, not on the router).
#
# Installs:
#   /etc/initscripts/ipacm-starter.sh   supervisor for /usr/bin/ipacm
#   /etc/initscripts/zlt-ipacm.sh       start/reassert/status/stop controller
#   /etc/initscripts/start_cfgd         + boot hook at the top of the script
#
# Why a transient unit instead of a systemd unit/drop-in:
#   / (rootfs) is read-only, and the writable /etc volume is mounted ~10 s into
#   boot -- AFTER systemd has loaded its unit files. Any unit or drop-in placed
#   under /etc/systemd/system is therefore invisible for that boot. The vendor
#   boot-script chain runs from /etc. start_cfgd is the earliest script we can
#   patch: userdata-ubi-mount.sh (which mounts /etc) is already executing from
#   the read-only rootfs copy when the volume is swapped, so edits to it never
#   run. The hook goes at the TOP of start_cfgd (it starts the moment /etc is
#   mounted), because ipacm only learns the WAN address from an rtnetlink event
#   and must be running before the dialer assigns it (~27 s).
#
# Safe to re-run: every step is idempotent, and replaced files are backed up to
# /data/zlt-backups/<date>/ipacm/.
#
# Usage:
#   ./install.sh                  # deploy + start + verify
#   ./install.sh --check          # verify only, change nothing
#   ./install.sh --uninstall      # remove the fix, restore vendor behaviour
#
# Environment:
#   ZLT_HOST   ssh target (default: zlt-root, falls back to root@192.168.3.1)
#   ZLT_TRIES  ssh attempts per command (default: 10; the LAN link is flaky)
#
# Device quirks this script works around:
#   * scp fails ("/usr/libexec/sftp-server: not found") -> stream with `cat >`.
#   * The link drops connections regularly -> every ssh call retries.
#   * no `ip`, no `getent`, busybox ifconfig only.
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-10}"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
STARTER_SRC="$SRC_DIR/ipacm-starter.sh"
HELPER_SRC="$SRC_DIR/zlt-ipacm.sh"
HOOK_SRC="$SRC_DIR/boot-hook.txt"

STARTER_DST=/etc/initscripts/ipacm-starter.sh
HELPER_DST=/etc/initscripts/zlt-ipacm.sh
HOOK_SCRIPT=/etc/initscripts/start_cfgd
HOOK_SCRIPT_OLD=/etc/initscripts/userdata-ubi-mount.sh
HOOK_BEGIN='# >>> ZLT-IPACM-HOOK'
HOOK_END='# <<< ZLT-IPACM-HOOK'
# Left over from the first iteration of this fix; a drop-in here is useless at
# boot (see above) but would let a second supervisor be started by hand.
LEGACY_DROPIN=/etc/systemd/system/ipacm.service.d/10-resilience.conf
LOG=/data/log/ipacm.log

die() { echo "ERROR: $*" >&2; exit 1; }

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

push() {
    n=0
    while [ "$n" -lt "$TRIES" ]; do
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "cat > '$2'" < "$1" 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        sleep 3
    done
    return 1
}

# ------------------------------------------------------------------- checks --
[ -f "$STARTER_SRC" ] || die "missing $STARTER_SRC"
[ -f "$HELPER_SRC" ] || die "missing $HELPER_SRC"
[ -f "$HOOK_SRC" ] || die "missing $HOOK_SRC"

verify() {
    echo "== verifying =="
    ssh_try 'set -u
        /etc/initscripts/zlt-ipacm.sh status 2>/dev/null | sed "s/^/            /"
        printf "starter:    "; [ -x /etc/initscripts/ipacm-starter.sh ] && echo present || echo MISSING
        printf "helper:     "; [ -x /etc/initscripts/zlt-ipacm.sh ] && echo present || echo MISSING
        printf "boot hook:  "; grep -q "ZLT-IPACM-HOOK" /etc/initscripts/start_cfgd && echo present || echo "MISSING (fix will not survive reboot)"
        printf "process:    "; pidof ipacm >/dev/null 2>&1 && echo "running (pid $(pidof ipacm))" || echo "not running"
        printf "log:        "; [ -f /data/log/ipacm.log ] && echo "$(wc -l < /data/log/ipacm.log) lines" || echo MISSING
        printf "wan event:  "; [ -f /data/log/ipacm-wan-learned ] && echo observed || echo "not observed since supervisor start"
        awk "/AddORDeleteNatEntry/ { n++ }
             END { printf \"NAT entries logged: %d\\n\", n }" /data/log/ipacm.log 2>/dev/null
        # debugfs ip4_* read as empty on this build; IPA TX counters are the
        # reliable ground truth for hardware datapath activity.
        printf "IPA stats:  "; cat /sys/kernel/debug/ipa/stats 2>/dev/null
        printf "wan:        "; head -2 /proc/net/route | tail -1 | awk "{print \$1\" default via \"\$3}" 2>/dev/null || true
    ' || die "verification failed"
    echo
    echo "ipacm learns the WAN IP only from an rtnetlink RTM_NEWADDR event; the"
    echo "persistent marker records that event even after the bounded log rotates."
    echo "See docs/18-ipacm-enablement.md for activation and rollback details."
}

uninstall() {
    echo "== uninstalling =="
    ssh_try '/etc/initscripts/zlt-ipacm.sh stop >/dev/null 2>&1
             systemctl stop zlt-ipacm-reassert.timer zlt-ipacm-reassert.service 2>/dev/null
             sed -i "/# >>> ZLT-IPACM-HOOK/,/# <<< ZLT-IPACM-HOOK/d" /etc/initscripts/start_cfgd /etc/initscripts/userdata-ubi-mount.sh
             rm -f /etc/initscripts/ipacm-starter.sh /etc/initscripts/zlt-ipacm.sh
             rm -f /etc/systemd/system/ipacm.service.d/10-resilience.conf
             rmdir /etc/systemd/system/ipacm.service.d 2>/dev/null
             echo "removed"' || die "uninstall failed"
    echo "Vendor behaviour restored (ipacm.service will fail at boot as before)."
    echo "Log kept at $LOG on the device."
}

# --------------------------------------------------------------------- main --
case "${1:---install}" in
--check)
    verify
    ;;

--uninstall)
    uninstall
    ;;

--install)
    echo "== target: $HOST =="
    ssh_try 'uname -n' >/dev/null || die "cannot reach $HOST"

    echo "== backing up =="
    ssh_try 'B=/data/zlt-backups/$(date +%Y%m%d)/ipacm; mkdir -p $B
             [ -f $B/ipacm-starter.sh ] || cp -f /etc/initscripts/ipacm-starter.sh $B/ 2>/dev/null || true
             [ -f $B/zlt-ipacm.sh ] || cp -f /etc/initscripts/zlt-ipacm.sh $B/ 2>/dev/null || true
             [ -f $B/start_cfgd.orig ] || cp -f /etc/initscripts/start_cfgd $B/start_cfgd.orig
             [ -f $B/ipacm.service.orig ] || cp -f /lib/systemd/system/ipacm.service $B/ipacm.service.orig
             echo "$B"' || die "backup failed"

    echo "== pushing supervisor =="
    push "$STARTER_SRC" "$STARTER_DST" || die "push of supervisor failed"
    ssh_try "chmod 755 '$STARTER_DST'; sh -n '$STARTER_DST' && echo ok" >/dev/null \
        || die "supervisor failed shell syntax check"

    echo "== pushing helper =="
    push "$HELPER_SRC" "$HELPER_DST" || die "push of helper failed"
    ssh_try "chmod 755 '$HELPER_DST'; sh -n '$HELPER_DST' && echo ok" >/dev/null \
        || die "helper failed shell syntax check"

    echo "== wiring the boot hook =="
    # Inserted directly after the shebang of start_cfgd: it is the first script
    # that runs from /etc (it starts as soon as the volume is mounted) and it
    # finishes long before the dialer assigns the WAN address.
    push "$HOOK_SRC" /tmp/zlt-ipacm-hook.txt || die "could not push the hook snippet"
    ssh_try "sed -i '/# >>> ZLT-IPACM-HOOK/,/# <<< ZLT-IPACM-HOOK/d' '$HOOK_SCRIPT_OLD' '$HOOK_SCRIPT'
        awk 'NR==FNR { h = h \$0 \"\\n\"; next }
             FNR == 1 { print; next }
             !done { printf \"%s\", h; done = 1 }
             { print }
             END { if (!done) printf \"%s\", h }' /tmp/zlt-ipacm-hook.txt '$HOOK_SCRIPT' > /tmp/zlt-ipacm-hook.out
        cat /tmp/zlt-ipacm-hook.out > '$HOOK_SCRIPT'
        rm -f /tmp/zlt-ipacm-hook.txt /tmp/zlt-ipacm-hook.out
        sh -n '$HOOK_SCRIPT' && echo 'hook wired'" || die "could not wire the boot hook"

    echo "== removing legacy drop-in =="
    ssh_try "rm -f '$LEGACY_DROPIN'; rmdir /etc/systemd/system/ipacm.service.d 2>/dev/null
             systemctl daemon-reload; echo cleaned" >/dev/null

    echo "== starting supervisor =="
    ssh_try '/etc/initscripts/zlt-ipacm.sh stop >/dev/null 2>&1
             /etc/initscripts/zlt-ipacm.sh start
             sleep 6
             pidof ipacm >/dev/null 2>&1 && echo "ipacm running"' || die "could not start the supervisor"

    verify
    ;;

*)
    die "unknown option: $1 (use --install, --check or --uninstall)"
    ;;
esac
