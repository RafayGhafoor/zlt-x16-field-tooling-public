#!/bin/sh
# =============================================================================
# install.sh — deploy the atcmd_daemon health guard to a ZLT X16
# =============================================================================
# Host-side installer (run from your workstation, not on the router).
#
# Installs:
#   /data/zlt-atcmd-guard/guard.sh          the guard (payload; replaceable)
#   /etc/systemd/system/zlt-atcmd-guard.service
#   /etc/systemd/system/zlt-atcmd-guard.timer
#   one line at the TOP of /etc/initscripts/StartTZApp that starts the timer
#
# Why it exists: docs/38 §1. atcmd_daemon's indication thread reopens /dev/smd3 —
# a node this firmware does not have — on any read error, then loops at 10 Hz
# without logging. AT keeps answering; URCs (call state, SMS, USSD) stop. Nothing
# supervises it, so the guard does: process absent → restart, or /dev/smd9 fd lost
# after being seen → restart, with the documented recovery (kill -9 + setsid
# start_atcmd_daemon), rate-limited, logged to /data/log/zlt-atcmd-guard.log.
#
# Safe to re-run: every step is idempotent; replaced files are backed up under
# /data/zlt-backups/<date>/atcmd-guard/.
#
# Usage:
#   ./install.sh                # deploy + start + verify
#   ./install.sh --check        # verify only, change nothing (guard runs dry)
#   ./install.sh --uninstall    # stop + remove units, payload and hook line
#
# Environment:
#   ZLT_HOST   ssh target (default: zlt-root)
#   ZLT_TRIES  ssh attempts per command (default: 10; the LAN link is flaky)
#
# Device quirks worked around here:
#   * scp fails (dropbear has no sftp-server)      -> stream with `ssh 'cat >'`
#   * the link drops ~1 connection in 3            -> every ssh call retries
#   * units under /etc/systemd/system get no boot job (the /etc volume mounts at
#     ~10.6 s, after systemd has loaded units)     -> the hook starts the timer
#   * `systemctl enable` alone is not enough on systemd 244 (no manager reload)
#                                                  -> enable AND start, from the hook
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-10}"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD_SRC="$SRC_DIR/guard.sh"
HOOK_SRC="$SRC_DIR/hook.sh"
SVC_SRC="$SRC_DIR/zlt-atcmd-guard.service"
TIMER_SRC="$SRC_DIR/zlt-atcmd-guard.timer"

GUARD_DST=/data/zlt-atcmd-guard/guard.sh
HOOK_DST=/data/zlt-atcmd-guard/hook.sh
UNIT_DIR=/etc/systemd/system
HOOK_SCRIPT=/etc/initscripts/StartTZApp
HOOK_MARK='zlt-atcmd-guard: start the atcmd_daemon health timer'
DAY=$(date +%Y%m%d)
BK=/data/zlt-backups/$DAY/atcmd-guard
LOG=/data/log/zlt-atcmd-guard.log

die() { echo "ERROR: $*" >&2 ; exit 1 ; }

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

push() {   # push <local> <remote>
    ssh_try "mkdir -p \$(dirname '$2')" >/dev/null || return 1
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "cat > '$2'" < "$1"
}

backup_if_present() {   # backup_if_present <remote-path>
    # Expand the name HERE: inside single quotes the remote shell would not, and the
    # first deploy failed exactly that way (cp: cannot create .../$(basename ...)).
    _base=${1##*/}
    _when=$(date +%H%M%S)
    if ssh_try "[ -e '$1' ] && echo yes" | grep -q yes; then
        ssh_try "mkdir -p $BK && cp -p '$1' '$BK/${_base}.${_when}' && ls -l '$BK/${_base}.${_when}'" \
            || die "backup of $1 failed"
    fi
}

# ------------------------------------------------------------------- actions --
do_check() {
    echo "== files"
    ssh_try "ls -l $GUARD_DST $UNIT_DIR/zlt-atcmd-guard.service $UNIT_DIR/zlt-atcmd-guard.timer 2>&1" || true
    echo "== timer"
    ssh_try "systemctl is-enabled zlt-atcmd-guard.timer 2>&1; systemctl is-active zlt-atcmd-guard.timer 2>&1" || true
    echo "== hook"
    ssh_try "$HOOK_DST check 2>&1 || echo '  (hook.sh not deployed yet)'" || true
    echo "== guard, dry run (changes nothing)"
    ssh_try "GUARD_DRY_RUN=1 GUARD_STATE=/tmp/zlt-aguard-check GUARD_LOGDIR=/tmp $GUARD_DST; echo rc=\$?; cat /tmp/zlt-aguard-check/../zlt-atcmd-guard.log 2>/dev/null | tail -2; rm -rf /tmp/zlt-aguard-check /tmp/zlt-atcmd-guard.log" || true
    echo "== live daemon"
    ssh_try "P=\$(pgrep -f '^atcmd_daemon\$' | head -1); echo pid=\$P; [ -n \"\$P\" ] && ls -l /proc/\$P/fd | grep -E 'smd8|smd9'" || true
    echo "== guard log (last 5)"
    ssh_try "tail -5 $LOG 2>/dev/null" || true
}

do_install() {
    echo "== preflight"
    ssh_try "[ -x /etc/initscripts/start_atcmd_daemon ] && echo 'start_atcmd_daemon present'" \
        || die "start_atcmd_daemon missing — this is not an X16"
    ssh_try "command -v pgrep >/dev/null && echo 'pgrep present'" || die "pgrep missing on device"

    echo "== payload -> $GUARD_DST"
    backup_if_present "$GUARD_DST"
    push "$GUARD_SRC" "$GUARD_DST" || die "push of guard.sh failed"
    push "$HOOK_SRC"  "$HOOK_DST"  || die "push of hook.sh failed"
    ssh_try "chmod 755 $GUARD_DST $HOOK_DST && sh -n $GUARD_DST && sh -n $HOOK_DST && echo 'syntax OK'" \
        || die "guard.sh/hook.sh do not parse on device"

    echo "== units -> $UNIT_DIR"
    for u in zlt-atcmd-guard.service zlt-atcmd-guard.timer; do
        base=${u##*/}
        backup_if_present "$UNIT_DIR/$base"
    done
    push "$SVC_SRC"   "$UNIT_DIR/zlt-atcmd-guard.service" || die "push of the service failed"
    push "$TIMER_SRC" "$UNIT_DIR/zlt-atcmd-guard.timer"   || die "push of the timer failed"

    echo "== boot hook: top of $HOOK_SCRIPT (device-side controller)"
    backup_if_present "$HOOK_SCRIPT"
    # All quoting and "where is the top" handling lives in hook.sh ON THE DEVICE:
    # the first version of this did it inside this nested ssh string and silently
    # wrote the hook ABOVE the shebang, which makes systemd's execve() fail with
    # ENOEXEC and takes the whole boot wiring with it.
    ssh_try "$HOOK_DST install" || die "hook insertion failed ($HOOK_DST install)"

    echo "== enable + start"
    ssh_try "systemctl daemon-reload && systemctl enable zlt-atcmd-guard.timer >/dev/null 2>&1 && systemctl start zlt-atcmd-guard.timer && echo started" \
        || die "could not start the timer"

    echo "== first run (so the baseline marker exists before any fault)"
    ssh_try "systemctl start zlt-atcmd-guard.service; sleep 1; echo 'guard service rc='\$?" || true
    verify
}

do_uninstall() {
    echo "== stop + disable"
    ssh_try "systemctl disable --now zlt-atcmd-guard.timer >/dev/null 2>&1; systemctl stop zlt-atcmd-guard.service >/dev/null 2>&1; echo done" || true
    echo "== remove units + payload"
    ssh_try "rm -f $UNIT_DIR/zlt-atcmd-guard.service $UNIT_DIR/zlt-atcmd-guard.timer; systemctl daemon-reload; rm -rf /data/zlt-atcmd-guard; echo removed" || true
    echo "== remove the hook line"
    ssh_try "[ -x $HOOK_DST ] && $HOOK_DST remove || echo 'hook.sh already gone'" || true
    echo "NOTE: $LOG is kept (it is the record of what was restarted)."
}

verify() {
    echo
    echo "== verify"
    # Plain echoes, one per line: a pipeline here reports "nothing" when any part of
    # it exits non-zero (is-enabled on a not-yet-installed unit returns 1), which is
    # how the first version of this block printed empty fields instead of "no".
    ssh_try "echo \"  timer enabled: \$(systemctl is-enabled zlt-atcmd-guard.timer 2>&1) \"; \
             echo \"  timer active : \$(systemctl is-active  zlt-atcmd-guard.timer 2>&1) \"; \
             echo \"  hook         : \$($HOOK_DST check 2>&1 | tr '\\n' ' ') \"; \
             P=\$(pgrep -f '^atcmd_daemon\$' | head -1); \
             echo \"  daemon pid   : \${P:-none} \"; \
             for f in \$([ -n \"\$P\" ] && ls /proc/\$P/fd 2>/dev/null | grep -E '^[0-9]+\$'); do \
                 t=\$(readlink /proc/\$P/fd/\$f 2>/dev/null); case \"\$t\" in /dev/smd*) echo \"  holds         : fd \$f -> \$t\";; esac; \
             done" || true
    ssh_try "GUARD_DRY_RUN=1 $GUARD_DST; echo '  guard dry run rc='\$?" || true
    echo "  log: $LOG"
    ssh_try "tail -3 $LOG 2>/dev/null | sed 's/^/    /'" || true
    echo
    echo "  If the daemon is healthy the guard stays silent — no line is written at all."
    echo "  To prove it acts:  ssh $HOST 'kill -9 \$(pgrep -f \"^atcmd_daemon\$\")'"
    echo "  then within 60 s:  tail -3 $LOG   ->  RESTART ... OK pid=... holds /dev/smd9 again"
}

case "${1:-}" in
    ''|--install) do_install ;;
    --check)      do_check ;;
    --uninstall)  do_uninstall ;;
    -h|--help)    sed -n '2,40p' "$0" ; exit 0 ;;
    *)            die "unknown option: $1 (use --install, --check or --uninstall)" ;;
esac
