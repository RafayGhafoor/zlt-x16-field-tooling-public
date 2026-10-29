#!/bin/sh
# =============================================================================
# zlt-smartdns.sh — SmartDNS resolver plumbing for the ZLT X16
# =============================================================================
# The resolver itself (smartdns-rs 0.13.1) and the QManager page that drives it
# are unchanged QManager code. This script is the X16 adaptation layer: the three
# things this firmware does differently from the O5A the feature was written on.
#
#   1. BOOT. /etc is a separate ubi volume mounted ~10 s in, after systemd has
#      loaded its unit graph, so units under /etc/systemd/system get no boot job
#      (proven on this unit 2026-10-26, and the reason deploy-x16 has a boot hook
#      at all). `boot` is called from /etc/initscripts/StartTZApp and starts the
#      resolver and its timers by hand.
#
#   2. dnsmasq's CONFIG IS IN /tmp AND NOBODY OWNS ITS RESTART. The vendor runs
#      `dnsmasq -C /tmp/dnsmasq.conf -x /tmp/dnsmasq.pid`; the file is generated
#      per boot (start_cfgd's ModifyDnsmasqConf is dead code on this build) and
#      NOTHING supervises the process — measured 2026-10-26: `killall dnsmasq`
#      left LAN DNS dead indefinitely, lan_mgr did not respawn it. So the LAN
#      wiring (strict-order + server=127.0.0.1#5353, which is what makes clients
#      actually use the resolver) has to be (a) appended to that file, (b)
#      activated by restarting dnsmasq ourselves, and (c) re-applied when the
#      vendor regenerates the file. `wire` does all three and is idempotent;
#      zlt-smartdns.timer runs it every minute.
#
#   3. THERE IS NO /var/log/syslog. /var/log -> /var/volatile/log, and that
#      directory does not exist, so the busybox syslogd that IS running writes
#      nowhere. QManager's smartdns_stats.sh and its sampler read dnsmasq's
#      SIGUSR1 dump from /var/log/syslog by that exact path. Rather than enable
#      system-wide logging (a write load this box does not have today), the
#      dnsmasq dump is pointed at /tmp/dnsmasq.log with `log-facility` and
#      /var/log/syslog is a symlink to it — a compatibility shim, bounded below.
#
# USAGE: zlt-smartdns.sh {boot|wire|start|stop|restart|status|verify|unwire|hook-install|hook-remove}
# =============================================================================

QM_ROOT=/data/qmanager
BIN="$QM_ROOT/bin/smartdns"
CONF="$QM_ROOT/etc/smartdns.conf"
UNIT=qmanager-dns.service
TIMERS="qmanager-dns-stats.timer qmanager-dns-edge.timer zlt-smartdns.timer"

DNSMASQ_CONF=/tmp/dnsmasq.conf
DNSMASQ_LOG=/tmp/dnsmasq.log
DNSMASQ_PID=/tmp/dnsmasq.pid
VENDOR_COPY=/tmp/dnsmasq.conf.vendor
SYSLOG_LINK=/var/volatile/log/syslog

LAN_IP=192.168.3.1
PORT=5353

BOOT_SCRIPT=/etc/initscripts/StartTZApp
BOOT_BACKUP=/etc/initscripts/StartTZApp.pre-smartdns
HOOK_MARK='### SmartDNS resolver (added by deploy-x16/smartdns; see /data/qmanager/bin/zlt-smartdns.sh)'
HOOK_LINE='/data/qmanager/bin/zlt-smartdns.sh boot >> /data/log/zlt-smartdns.log 2>&1 &'

MARK_B="# BEGIN ZLT-SMARTDNS v1"
MARK_E="# END ZLT-SMARTDNS v1"

# The dump is ~15 lines per SIGUSR1 (one per 5 min) plus dnsmasq's own messages.
# 256 kB is weeks of it; the cap exists so a tmpfs (322 MB shared with /run) can
# never be eaten by a diagnostic file.
LOG_MAX_BYTES=262144
LOG_KEEP_BYTES=65536

log() { printf '%s zlt-smartdns: %s\n' "$(date '+%F %T')" "$*"; }

# ---------------------------------------------------------------- probes ----
# `netstat -lnu` is the only socket view this firmware has (no ss, no ip).
listening() { netstat -lnu 2>/dev/null | grep -q "127.0.0.1:$1"; }
dnsmasq_up() { netstat -lnu 2>/dev/null | grep -q ':53 '; }
smartdns_up() { listening "$PORT"; }

dig_ok() {
    # $1 = resolver, $2... = extra dig args
    dig +short +time=3 +tries=1 "$@" debian.org 2>/dev/null | grep -qE '^[0-9]'
}

# ------------------------------------------------------------ dnsmasq start --
# Same invocation the vendor uses (see /proc/<dnsmasq>/cmdline on a fresh boot).
# keep-in-foreground is in the config, so it must be detached from this shell.
start_dnsmasq() {
    _try=0
    while [ "$_try" -lt 5 ]; do
        ( setsid /usr/bin/dnsmasq -C "$DNSMASQ_CONF" -x "$DNSMASQ_PID" >/dev/null 2>&1 & )
        _i=0
        while [ "$_i" -lt 5 ]; do
            dnsmasq_up && return 0
            sleep 1
            _i=$((_i + 1))
        done
        _try=$((_try + 1))
    done
    return 1
}

# ------------------------------------------------------------------- wire ---
# Idempotent: appends the forwarding block to the vendor's dnsmasq config, proves
# the result parses BEFORE dnsmasq is touched, restarts dnsmasq only when the file
# actually changed, and keeps a copy of the vendor's own file for --uninstall.
#
# THE ASSEMBLY MUST BE CANONICAL. An earlier revision stripped the block and
# re-appended it with a `echo` separator, so every run grew the file by one blank
# line, `cmp` never matched, and this function killed + restarted dnsmasq EVERY
# MINUTE — a DNS blip a minute on the LAN, measured 2026-10-26. Trailing blank
# lines are now dropped before the block is appended, so a second run is a no-op.
#
# Exit: 0 wired, 2 not ready yet (no dnsmasq config: LAN has not come up).
wire() {
    # --- the /var/log/syslog shim (see the header) ---
    if [ ! -e "$SYSLOG_LINK" ] || [ "$(readlink "$SYSLOG_LINK" 2>/dev/null)" != "$DNSMASQ_LOG" ]; then
        # /var/log -> /var/volatile/log; the directory is absent on this build.
        mkdir -p "${SYSLOG_LINK%/*}" 2>/dev/null
        [ -f "$SYSLOG_LINK" ] && [ ! -L "$SYSLOG_LINK" ] && \
            mv -f "$SYSLOG_LINK" "$SYSLOG_LINK.pre-smartdns" 2>/dev/null
        ln -sfn "$DNSMASQ_LOG" "$SYSLOG_LINK" 2>/dev/null && \
            log "linked $SYSLOG_LINK -> $DNSMASQ_LOG"
    fi

    [ -f "$DNSMASQ_CONF" ] || { log "no $DNSMASQ_CONF yet (LAN/dnsmasq not up)"; return 2; }

    _blk=/tmp/.zlt-sd-block.$$
    _want=/tmp/.zlt-sd-want.$$
    # A quoted heredoc, not a stack of printf calls: an apostrophe in a comment
    # ("dnsmasq's front cache") silently closed a printf string and produced a
    # config whose `strict-order` and `server=` lines had been swallowed — and
    # `dnsmasq --test` ACCEPTED it, because the mangled result was still valid
    # syntax. That is why the assertion below exists.
    {
        printf '%s\n' "$MARK_B"
        cat <<'TXT'
# Added by deploy-x16/smartdns/zlt-smartdns.sh; removed by --uninstall.
# strict-order keeps dnsmasq's servers in the order they appear here, so the
# resolver below is tried first and the carrier resolvers from /tmp/resolv.conf
# stay as the fallback tier. That is what makes the SmartDNS toggle safe: a
# stopped resolver degrades DNS, it does not break it.
strict-order
TXT
        printf 'server=127.0.0.1#%s\n' "$PORT"
        cat <<'TXT'
# dnsmasq's front cache. The default is 150; 2000 measured better for the warm
# path on the O5A and costs roughly 200 kB of this box's RAM.
cache-size=2000
# There is no syslog file on this firmware; see the header of zlt-smartdns.sh.
TXT
        printf 'log-facility=%s\n' "$DNSMASQ_LOG"
        printf '%s\n' "$MARK_E"
    } > "$_blk" || { rm -f "$_blk"; log "ERROR: could not build the config block"; return 1; }

    # Assert our own output before it can reach the daemon. `dnsmasq --test`
    # cannot: a block that lost its directives is still a valid config.
    if ! grep -qx 'strict-order' "$_blk" || ! grep -qx "server=127.0.0.1#$PORT" "$_blk"; then
        log "ERROR: generated block is missing its directives; refusing to write it"
        sed 's/^/    /' "$_blk"
        rm -f "$_blk"
        return 1
    fi

    # Everything except our own block, and without trailing blank lines — see
    # "THE ASSEMBLY MUST BE CANONICAL" above. A vendor file we do not touch.
    awk -v b="$MARK_B" -v e="$MARK_E" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        { line[n++] = $0 }
        END {
            last = n - 1
            while (last >= 0 && line[last] == "") last--
            for (i = 0; i <= last; i++) print line[i]
        }
    ' "$DNSMASQ_CONF" > "$_want.stripped" 2>/dev/null || { rm -f "$_blk" "$_want.stripped"; return 1; }

    { cat "$_want.stripped"; echo; cat "$_blk"; } > "$_want"
    rm -f "$_blk" "$_want.stripped"

    if cmp -s "$_want" "$DNSMASQ_CONF"; then
        rm -f "$_want"
        # The config is already right, but dnsmasq itself may not be running —
        # measured 2026-10-26: `killall dnsmasq` on this firmware leaves LAN DNS
        # dead indefinitely, because nothing supervises it. This branch is the
        # safety net that makes the guard a supervisor as well as a patcher.
        if ! dnsmasq_up; then
            log "dnsmasq is not running (config already wired) — starting it"
            start_dnsmasq && log "dnsmasq started" || \
                log "ERROR: dnsmasq did not start — LAN DNS is DOWN"
        fi
        cap_log
        return 0
    fi

    # Validate the CANDIDATE, never the live file: dnsmasq takes its config at
    # startup only, so a bad edit would be discovered by a dead LAN resolver.
    if ! /usr/bin/dnsmasq --test -C "$_want" >/tmp/.zlt-sd-test.$$ 2>&1; then
        log "ERROR: candidate dnsmasq config rejected, leaving the live one alone:"
        sed 's/^/    /' /tmp/.zlt-sd-test.$$
        rm -f "$_want" /tmp/.zlt-sd-test.$$
        return 1
    fi
    rm -f /tmp/.zlt-sd-test.$$

    # Second gate, independent of the tester: the marker block must be in the
    # candidate with its directives intact.
    if ! grep -qF "$MARK_B" "$_want" || ! grep -qx "server=127.0.0.1#$PORT" "$_want"; then
        log "ERROR: candidate lost the SmartDNS block after assembly; leaving the live file alone"
        rm -f "$_want"
        return 1
    fi

    # Keep the vendor's own file the first time we touch it in a boot.
    grep -qF "$MARK_B" "$DNSMASQ_CONF" || cp -f "$DNSMASQ_CONF" "$VENDOR_COPY" 2>/dev/null

    cat "$_want" > "$DNSMASQ_CONF" || { log "ERROR: could not write $DNSMASQ_CONF"; rm -f "$_want"; return 1; }
    rm -f "$_want"
    log "dnsmasq config now forwards to 127.0.0.1#$PORT"

    # Config changes need a restart — SIGHUP only re-reads hosts/resolv.conf.
    # One kill+start, with the replacement verified below; if dnsmasq was not
    # running at all, this is a plain start, not a restart.
    #
    # KillMode=process on zlt-smartdns.service is load-bearing here: without it
    # systemd tears down this unit's whole cgroup on exit and SIGTERMs the dnsmasq
    # we just started (measured 2026-10-26 — dnsmasq logged "exiting on receipt of
    # SIGTERM" one second after starting, leaving the LAN without DNS).
    if dnsmasq_up; then
        killall dnsmasq 2>/dev/null
        _i=0
        while [ "$_i" -lt 10 ]; do dnsmasq_up || break; sleep 1; _i=$((_i + 1)); done
    fi
    if start_dnsmasq; then
        log "dnsmasq restarted with the new config"
    else
        log "ERROR: dnsmasq did not come back up — LAN DNS is DOWN, run: $0 status"
        return 1
    fi

    cap_log
    return 0
}

# Bound /tmp/dnsmasq.log (see LOG_MAX_BYTES).
cap_log() {
    [ -f "$DNSMASQ_LOG" ] || return 0
    _sz=$(wc -c < "$DNSMASQ_LOG" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_sz" -le "$LOG_MAX_BYTES" ] && return 0
    # Keep the newest slice: the stats sampler and the panel only ever read the tail.
    tail -c "$LOG_KEEP_BYTES" "$DNSMASQ_LOG" > "$DNSMASQ_LOG.tmp" 2>/dev/null && \
        mv -f "$DNSMASQ_LOG.tmp" "$DNSMASQ_LOG" && \
        log "capped $DNSMASQ_LOG to ${LOG_KEEP_BYTES}B"
    return 0
}

# ------------------------------------------------------------------- boot ---
# Runs from /etc/initscripts/StartTZApp (backgrounded). Every step is independent
# so one failure cannot cost the rest — same rule as start_qmanager.
boot() {
    _i=0
    while [ "$_i" -lt 60 ]; do
        [ -x "$BIN" ] && [ -f "$CONF" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    if [ ! -x "$BIN" ] || [ ! -f "$CONF" ]; then
        log "payload missing ($BIN / $CONF) after 60 s; not starting"
        return 1
    fi

    # /etc mounted after systemd loaded its graph: make the units known now.
    systemctl daemon-reload >/dev/null 2>&1

    # `disable` is the operator's way to make "off" survive a reboot, because the
    # QManager toggle only stops the unit (upstream design: D3 in the spec).
    case "$(systemctl is-enabled "$UNIT" 2>/dev/null)" in
        disabled|masked)
            log "$UNIT is $(systemctl is-enabled "$UNIT" 2>/dev/null) — not starting the resolver"
            ;;
        *)
            systemctl start "$UNIT" >/dev/null 2>&1
            _i=0
            while [ "$_i" -lt 25 ]; do
                smartdns_up && break
                sleep 1
                _i=$((_i + 1))
            done
            smartdns_up && log "resolver listening on 127.0.0.1:$PORT" || \
                log "ERROR: resolver did not bind 127.0.0.1:$PORT"
            ;;
    esac

    for _t in $TIMERS; do
        systemctl start "$_t" >/dev/null 2>&1 || log "could not start $_t"
    done

    # dnsmasq is started later in this same boot chain (start_lan_mgr), so wait
    # for its config instead of assuming it exists.
    _i=0
    while [ "$_i" -lt 90 ]; do
        wire
        [ $? -eq 2 ] || break
        sleep 2
        _i=$((_i + 2))
    done
    verify
    return 0
}

# ----------------------------------------------------------------- verify ---
verify() {
    _bad=0
    if smartdns_up; then
        log "ok   resolver listening 127.0.0.1:$PORT"
    else
        log "FAIL resolver not listening on 127.0.0.1:$PORT"; _bad=1
    fi

    if grep -qE "^server=127\.0\.0\.1#$PORT$" "$DNSMASQ_CONF" 2>/dev/null; then
        log "ok   dnsmasq forwards to the resolver (strict-order -> carrier fallback)"
    else
        log "FAIL dnsmasq is not wired to the resolver"; _bad=1
    fi

    if dig_ok @127.0.0.1 -p "$PORT"; then
        log "ok   resolver answers (debian.org)"
    else
        log "WARN resolver did not answer debian.org (upstream/WAN?)"
    fi

    if dig_ok @"$LAN_IP"; then
        log "ok   LAN path answers (dig @$LAN_IP)"
    else
        log "FAIL LAN path on $LAN_IP does not answer"; _bad=1
    fi

    if [ -r "$SYSLOG_LINK" ]; then
        log "ok   $SYSLOG_LINK readable (dnsmasq counters reach the panel)"
    else
        log "WARN $SYSLOG_LINK unreadable — cache/history figures will read null"
    fi

    return "$_bad"
}

# ----------------------------------------------------------------- status ---
status() {
    echo "== smartdns =="
    printf '%-26s %s\n' "binary" "$([ -x "$BIN" ] && echo "$BIN" || echo MISSING)"
    printf '%-26s %s\n' "config" "$([ -f "$CONF" ] && echo "$CONF ($(wc -c < "$CONF") B)" || echo MISSING)"
    printf '%-26s %s\n' "unit" "$(systemctl is-enabled "$UNIT" 2>/dev/null)/$(systemctl is-active "$UNIT" 2>/dev/null)"
    printf '%-26s %s\n' "listener" "$(smartdns_up && echo "127.0.0.1:$PORT" || echo down)"
    _pid=""
    for _p in /proc/[0-9]*; do
        [ "$(cat "$_p/comm" 2>/dev/null)" = "smartdns" ] || continue
        case "$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)" in
            *"$CONF"*) _pid=${_p#/proc/} ;;
        esac
    done
    printf '%-26s %s\n' "pid/rss" "${_pid:-none}$([ -n "$_pid" ] && echo " / $(awk '/VmRSS/{print $2" kB"}' /proc/$_pid/status 2>/dev/null)")"
    for _t in $TIMERS; do
        printf '%-26s %s\n' "$_t" "$(systemctl is-active "$_t" 2>/dev/null)"
    done
    echo
    echo "== dnsmasq wiring =="
    printf '%-26s %s\n' "dnsmasq process" "$(dnsmasq_up && echo up || echo DOWN)"
    printf '%-26s %s\n' "vendor config" "$([ -f "$VENDOR_COPY" ] && echo "$VENDOR_COPY" || echo "(not saved this boot)")"
    grep -nE 'strict-order|^server=127\.0\.0\.1#|^cache-size=|^log-facility=' "$DNSMASQ_CONF" 2>/dev/null | sed 's/^/  /'
    printf '%-26s %s\n' "syslog shim" "$(readlink "$SYSLOG_LINK" 2>/dev/null || echo MISSING)"
    printf '%-26s %s\n' "dnsmasq log" "$([ -f "$DNSMASQ_LOG" ] && echo "$(wc -c < "$DNSMASQ_LOG") B" || echo MISSING)"
    echo
    echo "== samples =="
    printf '%-26s %s\n' "history ring" "$([ -f /tmp/qmanager_dns_stats_history.json ] && \
        echo "$(Q=/data/qmanager/bin/jq; [ -x $Q ] && $Q 'length' /tmp/qmanager_dns_stats_history.json 2>/dev/null || echo '?') samples" || echo "none yet")"
    printf '%-26s %s\n' "edge ledger" "$([ -f /tmp/qmanager_dns_edge.json ] && echo present || echo "no refresh yet")"
    verify
}

# ---------------------------------------------------------------- unwire ----
# Restore the vendor's dnsmasq behaviour exactly: their file if we kept one, else
# our block stripped out, then a restart.
unwire() {
    [ -f "$DNSMASQ_CONF" ] || { log "no $DNSMASQ_CONF"; return 0; }
    if ! grep -qF "$MARK_B" "$DNSMASQ_CONF"; then
        log "dnsmasq config has no SmartDNS block; nothing to remove"
    else
        if [ -f "$VENDOR_COPY" ] && ! grep -qF "$MARK_B" "$VENDOR_COPY"; then
            cat "$VENDOR_COPY" > "$DNSMASQ_CONF"
            log "restored $DNSMASQ_CONF from $VENDOR_COPY"
        else
            awk -v b="$MARK_B" -v e="$MARK_E" '
                $0 == b { skip = 1; next }
                $0 == e { skip = 0; next }
                !skip
            ' "$DNSMASQ_CONF" > "$DNSMASQ_CONF.pre-unwire" 2>/dev/null && \
                cat "$DNSMASQ_CONF.pre-unwire" > "$DNSMASQ_CONF" && \
                rm -f "$DNSMASQ_CONF.pre-unwire" && log "stripped the SmartDNS block"
        fi
        if dnsmasq_up; then killall dnsmasq 2>/dev/null; sleep 1; fi
        start_dnsmasq && log "dnsmasq restarted (vendor behaviour)" || \
            log "ERROR: dnsmasq did not come back up"
    fi
    [ -L "$SYSLOG_LINK" ] && rm -f "$SYSLOG_LINK" && log "removed $SYSLOG_LINK shim"
    return 0
}

# ------------------------------------------------------------ boot hook ----
# Insert the hook line into the vendor boot chain. /etc/systemd/system gets no boot
# job on this firmware, so this line IS the start mechanism (same reason
# deploy-x16 wires start_qmanager into the same file).
#
# Placed directly above the QManager hook when that exists, so QManager's units are
# up first; otherwise above start_lan_mgr (the anchor deploy-x16 falls back to).
# Never appended at the end of the file: the vendor runs one case block.
hook_install() {
    [ -f "$BOOT_SCRIPT" ] || { log "$BOOT_SCRIPT missing"; return 1; }
    if grep -qF "$HOOK_MARK" "$BOOT_SCRIPT"; then
        log "boot hook already wired"
        return 0
    fi
    [ -f "$BOOT_BACKUP" ] || cp -f "$BOOT_SCRIPT" "$BOOT_BACKUP"

    _tab=$(printf '\t')
    awk -v mark="${_tab}$HOOK_MARK" -v line="${_tab}$HOOK_LINE" '
        placed == 0 && index($0, "start_qmanager start") {
            print mark; print line; print; placed = 1; next
        }
        { print }
    ' "$BOOT_SCRIPT" > "$BOOT_SCRIPT.new" || return 1

    if ! grep -qF "$HOOK_LINE" "$BOOT_SCRIPT.new"; then
        # No QManager hook: retry above start_lan_mgr, which is where dnsmasq's LAN
        # bring-up happens.
        _tab=$(printf '\t')
        awk -v mark="${_tab}$HOOK_MARK" -v line="${_tab}$HOOK_LINE" '
            placed == 0 && index($0, "start_lan_mgr start") {
                print mark; print line; print; placed = 1; next
            }
            { print }
        ' "$BOOT_SCRIPT" > "$BOOT_SCRIPT.new" || return 1
    fi
    grep -qF "$HOOK_LINE" "$BOOT_SCRIPT.new" || { rm -f "$BOOT_SCRIPT.new"; log "could not find an anchor in $BOOT_SCRIPT"; return 1; }

    sh -n "$BOOT_SCRIPT.new" || { rm -f "$BOOT_SCRIPT.new"; log "edited $BOOT_SCRIPT would not parse; left the vendor file alone"; return 1; }
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
    sh -n "$BOOT_SCRIPT.new" || { rm -f "$BOOT_SCRIPT.new"; log "edited $BOOT_SCRIPT would not parse; left it alone"; return 1; }
    cat "$BOOT_SCRIPT.new" > "$BOOT_SCRIPT" && rm -f "$BOOT_SCRIPT.new"
    log "boot hook removed from $BOOT_SCRIPT"
    return 0
}

# ------------------------------------------------------------------- main ---
case "${1:-status}" in
    boot)    boot ;;
    wire)    wire ;;
    verify)  verify ;;
    status)  status ;;
    start)
        systemctl start "$UNIT"
        for _t in $TIMERS; do systemctl start "$_t" >/dev/null 2>&1; done
        wire
        verify
        ;;
    stop)
        # Stop only. The dnsmasq block stays on purpose: strict-order falls through
        # to the carrier resolvers, which is the documented "off" behaviour.
        systemctl stop "$UNIT"
        for _t in qmanager-dns-stats.timer qmanager-dns-edge.timer; do
            systemctl stop "$_t" >/dev/null 2>&1
        done
        log "resolver stopped; LAN DNS falls back to the carrier resolvers"
        dig_ok @"$LAN_IP" && log "ok   LAN path still answers" || log "FAIL LAN path stopped answering"
        ;;
    restart) systemctl restart "$UNIT"; wire; verify ;;
    unwire)  unwire ;;
    hook-install) hook_install ;;
    hook-remove)  hook_remove ;;
    *) echo "usage: $0 {boot|wire|verify|status|start|stop|restart|unwire|hook-install|hook-remove}" >&2; exit 1 ;;
esac
