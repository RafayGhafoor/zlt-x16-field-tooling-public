#!/bin/sh
# =============================================================================
# zlt-ttlnorm.sh -- normalise TTL on cellular (rmnet) egress
# =============================================================================
# Installed to /etc/initscripts/zlt-ttlnorm. Runs at boot from StartTZApp right
# after /etc/initscripts/ddos.sh (the last vendor step that builds the rule
# set), and is re-runnable by hand.
#
# WHY THIS EXISTS
#   The working GreenPacket O5A on the same carrier ships
#       -A POSTROUTING -o rmnet_data+ -j TTL --ttl-set 65
#   The X16 shipped nothing, so tethered traffic left with TTL 63 (one hop
#   decremented) while router-originated traffic left with 64. That difference is
#   a hotspot signature, and anti-tethering enforcement on Pakistani mobile
#   networks is documented behaviour. Normalising it makes tethered traffic
#   indistinguishable from router-originated traffic. See
#   docs/13-greenpacket-comparison.md and docs/14-config-defects-and-fixes.md §6.
#
#   65 (not 64) is deliberate: it is the exact value the working device uses, so
#   this reproduces a configuration known good on this carrier instead of
#   inventing a new one.
#
# SCOPE
#   `rmnet_data+` covers every rmnet_dataN, matching the GreenPacket. The
#   internet bearer's index is not stable (the dialer has been seen tearing down
#   rmnet_data5 while rmnet_data0 carried data), so pinning one index would
#   silently stop matching after a reconnect.
#
# Only the mangle table is touched. The modem, dialer, filter/nat tables and all
# persistent vendor config are left alone, so `remove` restores vendor behaviour
# exactly.
#
# Device actions:
#   zlt-ttlnorm boot          apply (called from StartTZApp)
#   zlt-ttlnorm apply         apply now
#   zlt-ttlnorm status        is the rule present, and is it matching traffic?
#   zlt-ttlnorm remove        delete the rule (vendor behaviour)
#   zlt-ttlnorm install-hook  add the StartTZApp hook (idempotent, self-healing)
#   zlt-ttlnorm remove-hook   remove the StartTZApp hook
# =============================================================================
set -u

# /usr/sbin is NOT in the default PATH on this firmware (a plain root shell says
# "iptables: not found"), so set it explicitly rather than trusting the caller.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

IPT=/usr/sbin/iptables
WAN_IF="${WAN_IF:-rmnet_data+}"
TTL_SET="${TTL_SET:-65}"

HOOK_SCRIPT=/etc/initscripts/StartTZApp
HOOK_BEGIN='# >>> ZLT-TTLNORM-HOOK'
HOOK_END='# <<< ZLT-TTLNORM-HOOK'
BACKUP_DIR=/data/zlt-backups/$(date +%Y%m%d)/ttl-normalise

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ---------------------------------------------------------------- the rule --
# -w: the vendor's own iptables_config uses it. Without it a concurrent xtables
# lock (firewalltools runs during boot) makes the insert fail with "Resource
# temporarily unavailable" and the rule would be silently lost.
have_rule() {
    "$IPT" -w -t mangle -C POSTROUTING -o "$WAN_IF" -j TTL --ttl-set "$TTL_SET" 2>/dev/null
}

apply() {
    if have_rule; then
        log "already applied (-o $WAN_IF --ttl-set $TTL_SET)"
        return 0
    fi
    if ! "$IPT" -w -t mangle -A POSTROUTING -o "$WAN_IF" -j TTL --ttl-set "$TTL_SET"; then
        log "ERROR: could not add the TTL rule (is xt_TTL available?)"
        return 1
    fi
    log "applied (-o $WAN_IF --ttl-set $TTL_SET)"
    return 0
}

remove() {
    _n=0
    while have_rule; do
        "$IPT" -w -t mangle -D POSTROUTING -o "$WAN_IF" -j TTL --ttl-set "$TTL_SET" || break
        _n=$((_n + 1))
    done
    log "removed $_n rule(s); vendor behaviour restored"
}

status() {
    if have_rule; then
        echo "ttl-normalise: ACTIVE (-o $WAN_IF, --ttl-set $TTL_SET)"
    else
        echo "ttl-normalise: NOT ACTIVE (rule absent)"
    fi
    # Counters are the real proof: a rule that exists but matches nothing is not
    # normalising anything.
    "$IPT" -w -t mangle -L POSTROUTING -n -v 2>/dev/null \
        | awk '/TTL/ { printf "  matched: %s packets, %s bytes\n", $1, $2 }'
    for _i in /sys/class/net/rmnet_data*; do
        [ -e "$_i" ] || continue
        echo "  $(basename "$_i"): state=$(cat "$_i/operstate" 2>/dev/null) mtu=$(cat "$_i/mtu" 2>/dev/null)"
    done
}

# ------------------------------------------------------------- boot wiring --
# The hook is inserted AFTER /etc/initscripts/ddos.sh because that is the last
# vendor step that builds the rule set at boot. Busybox sed on this firmware has
# no GNU `\|` address delimiter, so the anchor is a BRE with escaped slashes.
hook_snippet() {
    echo "$HOOK_BEGIN"
    echo "# TTL normalisation on cellular egress (router-fix/ttl-normalise)."
    echo "# Placed directly AFTER ddos.sh on purpose: ddos.sh is the last vendor step"
    echo "# that builds the rule set at boot, so nothing rebuilds the table under us."
    echo "# Effect: -t mangle -A POSTROUTING -o $WAN_IF -j TTL --ttl-set $TTL_SET"
    echo "# See router-fix/ttl-normalise/README.md."
    echo "/etc/initscripts/zlt-ttlnorm boot >> /data/log/zlt-ttlnorm.log 2>&1"
    echo "$HOOK_END"
}

install_hook() {
    [ -f "$HOOK_SCRIPT" ] || { log "ERROR: $HOOK_SCRIPT not found"; return 1; }

    mkdir -p "$BACKUP_DIR" 2>/dev/null
    [ -f "$BACKUP_DIR/StartTZApp.orig" ] || cp -f "$HOOK_SCRIPT" "$BACKUP_DIR/StartTZApp.orig"

    _tmp=/tmp/zlt-ttlnorm-hook.$$
    hook_snippet > "$_tmp"

    # Strip any previous block first, so re-running cannot duplicate it.
    sed -i "/$HOOK_BEGIN/,/$HOOK_END/d" "$HOOK_SCRIPT"

    _anchor=$(grep -c '^[[:space:]]*/etc/initscripts/ddos\.sh' "$HOOK_SCRIPT")
    if [ "$_anchor" = "1" ]; then
        sed -i '/^[[:space:]]*\/etc\/initscripts\/ddos\.sh/r '"$_tmp" "$HOOK_SCRIPT"
        log "hook inserted after ddos.sh"
    else
        # Fallback: after the shebang. Still effective (nothing flushes mangle
        # POSTROUTING at runtime), but the boot ordering is no longer ideal.
        awk 'NR==FNR { h = h $0 "\n"; next }
             FNR == 1 { print; printf "%s", h; next }
             { print }' "$_tmp" "$HOOK_SCRIPT" > /tmp/zlt-ttlnorm.out
        cat /tmp/zlt-ttlnorm.out > "$HOOK_SCRIPT"
        rm -f /tmp/zlt-ttlnorm.out
        log "WARNING: ddos.sh anchor not found; hook inserted after shebang"
    fi
    rm -f "$_tmp"

    # A broken StartTZApp would cost the next boot, so verify and roll back.
    if ! sh -n "$HOOK_SCRIPT" 2>/dev/null; then
        cp -f "$BACKUP_DIR/StartTZApp.orig" "$HOOK_SCRIPT"
        log "ERROR: StartTZApp failed syntax check; restored from backup"
        return 1
    fi
    log "StartTZApp syntax ok"
    return 0
}

remove_hook() {
    [ -f "$HOOK_SCRIPT" ] || return 0
    sed -i "/$HOOK_BEGIN/,/$HOOK_END/d" "$HOOK_SCRIPT"
    sh -n "$HOOK_SCRIPT" 2>/dev/null && log "hook removed, StartTZApp syntax ok"
}

case "${1:-status}" in
boot)
    # Runs after ddos.sh. The rule is interface-name based, so installing it
    # before the WAN address exists is correct: it matches nothing until
    # rmnet_dataN comes up, then every subsequent packet is normalised.
    apply
    ;;
apply)       apply ;;
remove)      remove ;;
status)      status ;;
install-hook) install_hook ;;
remove-hook)  remove_hook ;;
*)
    echo "usage: $0 {boot|apply|status|remove|install-hook|remove-hook}" >&2
    exit 2
    ;;
esac
