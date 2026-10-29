#!/bin/sh
# =============================================================================
# install.sh — keep simcom-gnss.service off on a ZLT X16
# =============================================================================
# Host-side installer. Installs:
#   /data/zlt-gnss-off/gnss-off.sh      the controller (apply/revert/check/quiet-stop)
#   one line in /etc/initscripts/StartTZApp  (AFTER the shebang) that stops the unit
#                                            at every boot and logs that it did
# and, right now: stops the unit and masks it.
#
# Why: docs/47 §2–§4 — the GNSS engine starts and never fixes on this unit (no
# assistance data was ever downloaded, and a mast-mounted ODU needs sky), while the
# daemon costs 16 threads and ~3 MB on a one-core box. Nothing depends on it.
#
# Safe to re-run: the hook is stripped and re-inserted, the unit is already stopped.
#
# Usage:  ./install.sh [--check|--uninstall]
# Env:    ZLT_HOST (default zlt-root), ZLT_TRIES (default 10)
# =============================================================================
set -u
HOST="${ZLT_HOST:-zlt-root}" ; TRIES="${ZLT_TRIES:-10}"
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CTL_DST=/data/zlt-gnss-off/gnss-off.sh
HOOK_SCRIPT=/etc/initscripts/StartTZApp
DAY=$(date +%Y%m%d) ; BK=/data/zlt-backups/$DAY/gnss-off

die() { echo "ERROR: $*" >&2 ; exit 1 ; }
rsh() { n=0 ; while [ "$n" -lt "$TRIES" ]; do if out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$1" 2>&1); then printf '%s\n' "$out"; return 0; fi; n=$((n+1)); sleep 3; done; printf '%s\n' "$out" >&2; return 1 ; }
push() { rsh "mkdir -p \$(dirname '$2')" >/dev/null || return 1 ; ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "cat > '$2'" < "$1" ; }
backup_if_present() { _b=${1##*/} ; _t=$(date +%H%M%S)
    if rsh "[ -e '$1' ] && echo yes" | grep -q yes; then
        rsh "mkdir -p $BK && cp -p '$1' '$BK/${_b}.${_t}' && ls -l '$BK/${_b}.${_t}'" >/dev/null || die "backup of $1 failed"
    fi ; }

case "${1:-}" in
  --check)
    rsh "$CTL_DST check 2>&1 || echo '  (controller not deployed yet)'" || true
    rsh "P=\$(pgrep -x simcom_gnss | head -1); echo  daemon_pid=\${P:-none}; echo  threads=\$(awk '{print \$20}' /proc/\$P/stat 2>/dev/null || echo -)" || true
    exit 0 ;;
  --uninstall)
    rsh "[ -x $CTL_DST ] && $CTL_DST revert || echo 'nothing to revert'" || true
    rsh "rm -rf /data/zlt-gnss-off; echo removed" || true
    exit 0 ;;
esac

echo "== preflight"
rsh "[ -f $HOOK_SCRIPT ] && echo 'StartTZApp present'" || die "not an X16 (no $HOOK_SCRIPT)"
echo "   before: $(rsh "P=\$(pgrep -x simcom_gnss | head -1); awk '/^Threads|^VmRSS/{printf \"%s \", \$0}' /proc/\$P/status 2>/dev/null || echo 'daemon not running'")"

echo "== payload -> $CTL_DST"
backup_if_present "$CTL_DST"
push "$SRC_DIR/gnss-off.sh" "$CTL_DST" || die "push failed"
rsh "chmod 755 $CTL_DST && sh -n $CTL_DST && echo 'syntax OK'" || die "controller does not parse on device"

echo "== hook + stop + mask (device-side controller)"
backup_if_present "$HOOK_SCRIPT"
rsh "$CTL_DST apply" || die "apply failed"

echo
echo "== verify"
rsh "$CTL_DST check"
rsh "pgrep -x simcom_gnss >/dev/null && echo '  daemon  : RUNNING (bad)' || echo '  daemon  : gone'"
rsh "echo \"  line1   : \$(head -1 $HOOK_SCRIPT)\""
rsh "echo \"  log     : \$(tail -1 /data/log/zlt-gnss-off.log 2>/dev/null || echo '(nothing at boot yet)')\""
echo "  rollback  : ./install.sh --uninstall    (or: $CTL_DST revert)"
