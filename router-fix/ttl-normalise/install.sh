#!/bin/sh
# =============================================================================
# install.sh -- deploy TTL normalisation to a ZLT X16
# =============================================================================
# Host-side installer (run from your workstation, not on the router).
#
# Installs:
#   /etc/initscripts/zlt-ttlnorm        controller: apply/status/remove + the
#                                       StartTZApp boot hook (idempotent)
#
# Effect: adds exactly one rule,
#     -t mangle -A POSTROUTING -o rmnet_data+ -j TTL --ttl-set 65
# which is what the working GreenPacket O5A on the same carrier ships. Tethered
# traffic stops leaving with TTL 63 (a hotspot signature operators act on).
#
# WHY THE HOOK GOES AFTER ddos.sh, AND WHY THERE IS NO GUARD TIMER
#   ddos.sh (StartTZApp line ~108) is the last vendor step that builds the rule
#   set, so a hook placed after it cannot be overwritten by the boot sequence.
#   A periodic guard was considered and deliberately NOT added: the vendor's
#   /etc/tzscript/iptables_config only ever touches its own `tcprst` chain in
#   `mangle FORWARD`, and its whole-table flushes are commented out, so nothing
#   flushes `mangle POSTROUTING` at runtime. This repo only ships a guard when a
#   measurement justifies it (see the SmartDNS and QManager guards).
#
# The device-side controller owns the boot wiring (action `install-hook`), so all
# quoting and sed dialect handling lives on the device where it is exercised,
# not in a nested ssh string. It strips any previous block before inserting,
# asserts the ddos.sh anchor is unique, and rolls back from
# /data/zlt-backups/<date>/ttl-normalise/StartTZApp.orig if `sh -n` fails.
#
# Safe to re-run: the rule is checked with `iptables -C` before `-A`.
#
# Usage:
#   ./install.sh                  # deploy + apply + verify
#   ./install.sh --check          # verify only, change nothing
#   ./install.sh --uninstall      # remove rule + hook, restore vendor behaviour
#
# Environment:
#   ZLT_HOST   ssh target (default: zlt-root)
#   ZLT_TRIES  ssh attempts per command (default: 10; the LAN link is flaky)
#   WAN_IF     egress pattern (default: rmnet_data+)
#   TTL_SET    TTL value (default: 65, matching the GreenPacket)
#
# Device quirks this script works around:
#   * scp fails ("/usr/libexec/sftp-server: not found") -> stream with `cat >`.
#   * The link drops connections regularly -> every ssh call retries.
#   * `iptables` is not in the default root PATH -> the payload sets its own.
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-10}"
WAN_IF="${WAN_IF:-rmnet_data+}"
TTL_SET="${TTL_SET:-65}"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
PAYLOAD_SRC="$SRC_DIR/zlt-ttlnorm.sh"

PAYLOAD_DST=/etc/initscripts/zlt-ttlnorm
HOOK_SCRIPT=/etc/initscripts/StartTZApp
LOG=/data/log/zlt-ttlnorm.log

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
[ -f "$PAYLOAD_SRC" ] || die "missing $PAYLOAD_SRC"

verify() {
    echo "== verifying =="
    ssh_try "set -u
        printf 'controller:  '; [ -x '$PAYLOAD_DST' ] && echo present || echo MISSING
        printf 'boot hook:   '; grep -q 'ZLT-TTLNORM-HOOK' '$HOOK_SCRIPT' && echo present || echo 'MISSING (will not survive reboot)'
        printf 'hook markers:'; grep -c 'ZLT-TTLNORM-HOOK' '$HOOK_SCRIPT'
        printf 'starttzapp:  '; sh -n '$HOOK_SCRIPT' && echo 'syntax ok' || echo 'SYNTAX ERROR'
        echo 'rule:'
        '$PAYLOAD_DST' status | sed 's/^/  /'
        printf 'log:         '; [ -f '$LOG' ] && echo \"\$(wc -l < '$LOG') lines\" || echo 'no entries yet'
        exit 0
    " || die "verification failed"
    echo
    echo "hook markers 2 = one block (open + close). 4 = duplicated; re-run --install."
    echo "The counters are the proof: a rule that exists but matches nothing is not"
    echo "normalising anything. Send traffic from a LAN client, then re-run"
    echo "./install.sh --check and confirm the packet count grows."
}

uninstall() {
    echo "== uninstalling =="
    ssh_try "set -u
        [ -x '$PAYLOAD_DST' ] && '$PAYLOAD_DST' remove
        [ -x '$PAYLOAD_DST' ] && '$PAYLOAD_DST' remove-hook
        rm -f '$PAYLOAD_DST'
        sh -n '$HOOK_SCRIPT' && echo 'StartTZApp syntax ok'
        exit 0
    " || die "uninstall failed"
    echo "Vendor behaviour restored: WAN egress TTL is no longer rewritten."
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
    ssh_try 'uname -n; exit 0' >/dev/null || die "cannot reach $HOST"

    echo "== pushing controller =="
    push "$PAYLOAD_SRC" "$PAYLOAD_DST" || die "push of controller failed"
    ssh_try "chmod 755 '$PAYLOAD_DST'; sh -n '$PAYLOAD_DST' && echo 'shell syntax ok'; exit 0" >/dev/null \
        || die "controller failed shell syntax check"

    echo "== wiring the boot hook =="
    hook_out=$(ssh_try "WAN_IF='$WAN_IF' TTL_SET='$TTL_SET' '$PAYLOAD_DST' install-hook; exit 0") \
        || die "could not wire the boot hook"
    printf '%s\n' "$hook_out" | sed 's/^/   /'
    printf '%s\n' "$hook_out" | grep -qi 'ERROR' \
        && die "boot hook wiring failed (see above); StartTZApp was rolled back"

    echo "== applying now =="
    ssh_try "WAN_IF='$WAN_IF' TTL_SET='$TTL_SET' '$PAYLOAD_DST' boot; exit 0" \
        || die "could not apply the rule"

    verify
    ;;

*)
    die "unknown option: $1 (use --install, --check or --uninstall)"
    ;;
esac
