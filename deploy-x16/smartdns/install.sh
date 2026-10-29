#!/bin/sh
# =============================================================================
# install.sh — enable SmartDNS on a ZLT X16 (QManager page /local-network/smartdns)
# =============================================================================
# Host-side installer. Run from your workstation, not on the router.
#
# What this deploys, and why each piece exists:
#
#   /data/qmanager/bin/smartdns              smartdns-rs 0.13.1 (GPL-3.0, static
#                                            armv7; takes the vm from the QManager
#                                            tree, sha256-checked — see NOTICE.md)
#   /data/qmanager/etc/smartdns.conf         seed config, root:root 0600
#   /data/qmanager/bin/zlt-smartdns.sh       boot + dnsmasq-wiring helper (the X16
#                                            adaptation; README explains the three
#                                            device differences it absorbs)
#   /etc/systemd/system/qmanager-dns.service         the resolver
#   /etc/systemd/system/qmanager-dns-stats.timer     history sampler (5 min)
#   /etc/systemd/system/qmanager-dns-edge.timer      measured edge refresh (30 min)
#   /etc/systemd/system/zlt-smartdns.timer           dnsmasq wiring guard (1 min)
#   /etc/initscripts/StartTZApp              + one line, because units under
#                                            /etc/systemd/system get no boot job
#                                            on this firmware (see deploy-x16/README)
#
# The QManager frontend and its four smartdns CGIs are NOT touched: they ship with
# deploy-x16 and already answer on this unit — they reported enabled:false and a
# null config because nothing was installed behind them.
#
# Safe to re-run: every step is idempotent, and everything replaced is backed up to
# /data/zlt-backups/<date>/smartdns/.
#
# Usage:
#   ./install.sh              # deploy + start + verify   (alias: --install)
#   ./install.sh --check      # verify only, change nothing
#   ./install.sh --uninstall  # remove, restore vendor dnsmasq behaviour
#
# Environment:
#   ZLT_HOST        ssh target            (default: zlt-root)
#   ZLT_TRIES       ssh attempts per call (default: 10; the link drops ~1 in 3)
#   QM_SRC          QManager source tree  (default: /tmp/qm)
#   SMARTDNS_SRC    the binary to install (default: $QM_SRC/dependencies/smartdns/smartdns)
#   QM_PASS         QManager admin password for the endpoint check (default: <redacted-password>)
#
# Device quirks worked around here (see AGENTS.md):
#   * scp fails (dropbear has no sftp-server) -> stream with `ssh 'cat > dst'`
#   * the link drops ~1 connection in 3        -> every ssh call retries
#   * `systemctl enable` is not a boot guarantee -> the hook line is what starts it
#   * /tmp/dnsmasq.conf is generated per boot and nothing supervises dnsmasq
#                                               -> the guard timer re-applies it
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-10}"
QM_SRC="${QM_SRC:-/tmp/qm}"
SMARTDNS_SRC="${SMARTDNS_SRC:-$QM_SRC/dependencies/smartdns/smartdns}"
QM_PASS="${QM_PASS:-<redacted-password>}"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
QM_ROOT=/data/qmanager
BACKUP_ROOT="/data/zlt-backups/$(date +%Y%m%d)/smartdns"
BOOT_SCRIPT=/etc/initscripts/StartTZApp

UNITS="qmanager-dns.service qmanager-dns-edge.service qmanager-dns-stats.service zlt-smartdns.service"
TIMERS="qmanager-dns-stats.timer qmanager-dns-edge.timer zlt-smartdns.timer"

# The published smartdns-rs 0.13.1 release asset every QManager install runs. A
# different hash is not automatically wrong — it is a different build, and one that
# has never been measured on this device class.
EXPECTED_SHA=2caca59f6c9a68a09de10c32414693b3eae3cc4ab6a42166343f8589070cb291

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

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ------------------------------------------------------------------- check ---
check() {
    say "SmartDNS state"
    ssh_try "'$QM_ROOT/bin/zlt-smartdns.sh' status" || die "status failed"

    say "panel payload (the page's own CGI, via a real login)"
    ssh_try "B=http://127.0.0.1:8080/cgi-bin/quecmanager; C=/tmp/sd-cookie.\$\$
        rm -f \$C
        L=\$(curl -s -m 20 -c \$C -X POST -H 'Content-Type: application/json' \
             -d '{\"password\":\"$QM_PASS\"}' \$B/auth/login.sh)
        case \"\$L\" in *'\"success\": true'*|*'\"success\":true'*) : ;;
            *) echo 'login failed — set QM_PASS=..., skipping the CGI check'; exit 0 ;;
        esac
        curl -s -m 40 -b \$C \$B/network/smartdns.sh | $QM_ROOT/bin/jq -c \
            '{enabled,running,pid,rss_kb,provider_count,blocked_count,error_count,config_size,edge_members:(.edge.members|length),logs:(.logs_tail|length)}'
        curl -s -m 60 -b \$C \$B/network/smartdns_stats.sh | $QM_ROOT/bin/jq -c \
            '{hit_rate:.cache.hit_rate_pct,forwarded:.forwarding.queries_forwarded,speedup:.latency.speedup_x,pool:.pool.members,history_samples:.history.samples}'
        rm -f \$C" || die "CGI check failed"

    say "boot wiring"
    ssh_try "grep -n -A1 'SmartDNS resolver (added by deploy-x16/smartdns' '$BOOT_SCRIPT' | sed 's/^/  /'" \
        || echo "  NOT WIRED"
    ssh_try "systemctl is-enabled qmanager-dns.service zlt-smartdns.timer qmanager-dns-stats.timer 2>/dev/null" \
        | sed 's/^/  /'
}

# --------------------------------------------------------------- uninstall ---
uninstall() {
    say "removing the resolver (in that order: stop, unwire, delete)"
    ssh_try "
        for u in $UNITS; do
            systemctl disable --now \$u >/dev/null 2>&1
        done
        for t in $TIMERS; do
            systemctl disable --now \$t >/dev/null 2>&1
        done
        # Put dnsmasq's own behaviour back BEFORE the helper disappears.
        [ -x '$QM_ROOT/bin/zlt-smartdns.sh' ] && '$QM_ROOT/bin/zlt-smartdns.sh' unwire
        [ -x '$QM_ROOT/bin/zlt-smartdns.sh' ] && '$QM_ROOT/bin/zlt-smartdns.sh' hook-remove
        rm -f /etc/systemd/system/qmanager-dns.service /etc/systemd/system/qmanager-dns-edge.service \
              /etc/systemd/system/qmanager-dns-stats.service /etc/systemd/system/zlt-smartdns.service \
              /etc/systemd/system/qmanager-dns-edge.timer /etc/systemd/system/qmanager-dns-stats.timer \
              /etc/systemd/system/zlt-smartdns.timer
        systemctl daemon-reload >/dev/null 2>&1
        rm -f '$QM_ROOT/bin/smartdns' '$QM_ROOT/bin/zlt-smartdns.sh'
        [ -f '$QM_ROOT/etc/smartdns.conf' ] && mv -f '$QM_ROOT/etc/smartdns.conf' '$QM_ROOT/etc/smartdns.conf.removed'
        sh -n '$BOOT_SCRIPT' && echo 'StartTZApp parses'
        echo 'uninstalled'
    " || die "uninstall failed"
    echo
    echo "The SmartDNS page stays in the UI (it belongs to QManager) and now reports"
    echo "enabled:false, which is the truth. Config kept as $QM_ROOT/etc/smartdns.conf.removed."
}

# ----------------------------------------------------------------- install ---
install() {
    [ -f "$SRC_DIR/smartdns.conf" ] || die "missing $SRC_DIR/smartdns.conf"
    [ -f "$SMARTDNS_SRC" ] || die "resolver binary not found: $SMARTDNS_SRC (set SMARTDNS_SRC=... or QM_SRC=...)"

    say "target"
    ssh_try 'uname -n; uptime | sed "s/^/   /"' || die "cannot reach $HOST (ZLT_HOST=$HOST)"

    say "payload preflight"
    _sha=$(sha256_of "$SMARTDNS_SRC")
    echo "   binary: $SMARTDNS_SRC"
    echo "   sha256: $_sha"
    if [ "$_sha" != "$EXPECTED_SHA" ]; then
        echo "   WARNING: not the release asset this module was built against"
        echo "            expected $EXPECTED_SHA"
        printf '   continue anyway? [y/N] '
        read -r _a
        case "$_a" in y|Y) : ;; *) die "aborted" ;; esac
    fi
    # The page and its CGIs come from deploy-x16; without them there is nothing to
    # enable. Fail loudly rather than install a resolver nobody can drive.
    ssh_try "[ -d '$QM_ROOT/www/cgi-bin/quecmanager/network' ] && \
             [ -x '$QM_ROOT/bin/qmanager_dns_apply' ] && echo '   QManager payload: present'" \
        || die "QManager is not installed at $QM_ROOT — run deploy-x16/install.sh first"

    say "backing up to $BACKUP_ROOT"
    ssh_try "B='$BACKUP_ROOT'; mkdir -p \$B
        for f in /tmp/dnsmasq.conf /etc/initscripts/StartTZApp '$QM_ROOT/etc/smartdns.conf'; do
            [ -f \"\$f\" ] && cp -f \"\$f\" \"\$B/\$(basename \$f)\" 2>/dev/null
        done
        cp -f /etc/systemd/system/qmanager-dns.service \"\$B/\" 2>/dev/null
        echo \"   \$B: \$(ls \$B | tr '\n' ' ')\"" || die "backup failed"

    say "installing the resolver and its config"
    push "$SMARTDNS_SRC" "$QM_ROOT/bin/smartdns" || die "push of smartdns failed"
    push "$SRC_DIR/smartdns.conf" "$QM_ROOT/etc/smartdns.conf" || die "push of smartdns.conf failed"
    push "$SRC_DIR/zlt-smartdns.sh" "$QM_ROOT/bin/zlt-smartdns.sh" || die "push of zlt-smartdns.sh failed"
    ssh_try "chmod 755 '$QM_ROOT/bin/smartdns' '$QM_ROOT/bin/zlt-smartdns.sh'
        chmod 600 '$QM_ROOT/etc/smartdns.conf'
        chown root:root '$QM_ROOT/bin/smartdns' '$QM_ROOT/bin/zlt-smartdns.sh' '$QM_ROOT/etc/smartdns.conf'
        sh -n '$QM_ROOT/bin/zlt-smartdns.sh' && echo '   helper parses'
        '$QM_ROOT/bin/smartdns' --version | sed 's/^/   /'" || die "resolver install failed"

    say "installing units"
    for f in $UNITS $TIMERS; do
        push "$SRC_DIR/$f" "/etc/systemd/system/$f" || die "push of $f failed"
    done
    ssh_try "chmod 644 $(for f in $UNITS $TIMERS; do printf '/etc/systemd/system/%s ' $f; done)
        systemctl daemon-reload
        systemctl enable qmanager-dns.service >/dev/null 2>&1
        for t in $TIMERS; do systemctl enable \$t >/dev/null 2>&1; done
        systemctl daemon-reload
        echo '   units installed and enabled (starting them is the hook job)'" || die "unit install failed"

    say "wiring the boot hook"
    ssh_try "'$QM_ROOT/bin/zlt-smartdns.sh' hook-install" || die "could not wire the boot hook"
    ssh_try "sh -n '$BOOT_SCRIPT' && grep -n -A1 'SmartDNS resolver (added by deploy-x16/smartdns' '$BOOT_SCRIPT' | sed 's/^/   /'" \
        || die "boot hook is not in $BOOT_SCRIPT"

    say "starting now (boot path, not a hand-rolled start)"
    ssh_try "mkdir -p /data/log
        '$QM_ROOT/bin/zlt-smartdns.sh' boot" || die "start failed — see /data/log/zlt-smartdns.log"

    say "verifying"
    ssh_try "'$QM_ROOT/bin/zlt-smartdns.sh' status" || die "status failed"

    echo
    echo "Open http://<x16-lan-ip>:8080/local-network/smartdns/ — the toggle, the"
    echo "provider table and the config editor are QManager's own; this module is what"
    echo "is behind them. First edge measurement lands ~5 min after boot."
    echo "Reboot to prove the boot hook (AGENTS.md rule 6): the resolver must be"
    echo "listening before you touch anything, with no manual step."
}

# ------------------------------------------------------------------- main ---
case "${1:---install}" in
--check)     check ;;
--uninstall) uninstall ;;
--install)   install ;;
*) die "unknown option: $1 (use --install, --check or --uninstall)" ;;
esac
