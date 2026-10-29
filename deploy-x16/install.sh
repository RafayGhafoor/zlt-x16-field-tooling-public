#!/bin/sh
# =============================================================================
# install.sh -- deploy QManager to a ZLT X16 (SIMCom SIM8260E, SDX65)
# =============================================================================
# Host-side installer. Run from your workstation, not on the router.
#
# Installs:
#   /data/qmanager/                       payload root (www + cgi-bin + lib + bin)
#   /data/qmanager/bin/atcli_smd11        AT transport + Quectel<->SIMCom dialect
#   /data/qmanager/bin/sms_tool           AT-broker SMS shim (status/at/delete)
#   /data/qmanager/bin/qm_serve.sh        busybox httpd manager (port 8080)
#   /data/qmanager/bin/qmanager_traffic.sh  1 Hz live-traffic sampler
#   /data/qmanager/bin/qm_pathfix_x16.sh  relocates QManager's hardcoded paths
#   /etc/systemd/system/qmanager-{httpd,poller,ping,traffic}.service
#   /etc/systemd/system/qmanager-tower-schedule-{apply,clear}.service
#   /etc/initscripts/start_qmanager       boot hook (waits for /data, starts units + rearms saved timers)
#   /etc/initscripts/StartTZApp           + one line invoking the hook
#
# Why a boot hook at all: the units are `enabled` with correct symlinks, but this
# firmware starts services from /etc/initscripts/StartTZApp (TZApp.service,
# RemainAfterExit=yes) and a real reboot on 2026-10-26 started none of them.
# systemd 244 also does not reload the manager on `systemctl enable`, so the
# units stay out of multi-user.target's graph until a daemon-reload follows.
# Both are handled here; tests/check_boot_wiring.sh asserts them.
#
# Safe to re-run: every step is idempotent and replaced files are backed up to
# /data/zlt-backups/<date>/qmanager/.
#
# Usage:
#   ./install.sh --build        # bun build + stage the payload (needs QM_SRC)
#   ./install.sh                # deploy + start + verify   (alias: --install)
#   ./install.sh --check        # verify only, change nothing
#   ./install.sh --uninstall    # remove QManager, restore the vendor boot file
#
# Environment:
#   ZLT_HOST    ssh target (default: zlt-root, falls back to root@192.168.3.1)
#   ZLT_TRIES   ssh attempts per command (default: 10; the link is flaky)
#   QM_SRC      QManager source tree (default: the vendored qmanager/ in this
#               repo; falls back to /tmp/qm only if that is absent)
#   STAGE_DIR   staged payload directory    (default: /tmp/qm-stage)
#
# Device quirks worked around here:
#   * scp fails (dropbear has no sftp-server) -> stream with `ssh 'cat > dst'`
#   * the link drops ~1 connection in 3      -> every ssh call retries
#   * `systemctl enable` alone is not enough -> daemon-reload + boot hook
#   * macOS tar stamps uid 501 and exec bits -> chown/chmod pass after extract
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-10}"
STAGE_DIR="${STAGE_DIR:-/tmp/qm-stage}"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)

# The QManager source tree. It is VENDORED IN THIS REPOSITORY (`qmanager/`, a
# git subtree carrying its full history), so a fresh clone of this one repo is
# enough to deploy. QM_SRC still overrides for a checkout kept elsewhere.
#
# Before the subtree, the default was /tmp/qm -- a scratch copy that is not a
# git checkout and is wiped when the host reboots. That default silently built
# OLD behaviour, so the vendored tree is preferred over it and /tmp/qm is now
# only a last resort.
if [ -z "${QM_SRC:-}" ]; then
    if [ -d "$SRC_DIR/../qmanager/scripts" ]; then
        QM_SRC=$(cd "$SRC_DIR/../qmanager" && pwd)
    else
        QM_SRC=/tmp/qm
    fi
fi
QM_ROOT=/data/qmanager
BACKUP_ROOT=/data/zlt-backups/$(date +%Y%m%d)/qmanager
HOOK=/etc/initscripts/start_qmanager
BOOT_SCRIPT=/etc/initscripts/StartTZApp
BOOT_BACKUP=/etc/initscripts/StartTZApp.pre-qmanager
UNITS="qmanager-httpd qmanager-poller qmanager-ping qmanager-traffic"
# The healer runs as a timer: it puts back a unit that something else stopped
# (measured 2026-10-26: qmanager-poller was SIGTERMed and stayed dead — see
# qmanager-guard.service). Pushed/enabled with the units, started by the hook.
GUARD="qmanager-guard"
# Traffic Engine (tpws DPI). The engine is a long-running process plus a loop
# that re-asserts its nat REDIRECT: QCMAP flushes the nat table on every
# re-dial, and without the loop the bypass disappears silently while the UI
# still says "on". Shipping these units is the fix for "Video Optimizer does
# not turn on": video_optimizer.sh writes the setting and then calls
# `systemctl restart qmanager-dpi`, which failed with "No files found" because
# the X16 module never installed it (upstream ships it; this adaptation did
# not). tpws itself is already on the device — only the units were missing.
DPI_UNITS="qmanager-dpi qmanager-dpi-ensure"
DPI_TIMER="qmanager-dpi-ensure"
TOWER_SCHEDULE_UNITS="qmanager-tower-schedule-apply qmanager-tower-schedule-clear"

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

# ---------------------------------------------------------------- build -----
build_payload() {
    echo "== building the frontend from $QM_SRC =="
    [ -d "$QM_SRC" ] || die "QManager source not found at $QM_SRC (set QM_SRC=...)"

    # WHICH TREE IS BEING BUILT IS THE MOST CONSEQUENTIAL CHOICE HERE.
    #
    # The historical default is /tmp/qm, which is a scratch copy: not a git
    # repo, and wiped when the host reboots. All of this batch's QManager fixes
    # live in the QManager git checkout (ethernet, sms, apn, bands/current,
    # cgi_at, qmanager_poller, use-modem-status) -- and /tmp/qm has none of
    # them. Building the default therefore does not fail; it happily deploys the
    # OLD behaviour and silently undoes verified device fixes.
    #
    # A git work tree, not necessarily a .git of its own: the vendored
    # qmanager/ subtree belongs to THIS repository, so `-d $QM_SRC/.git` alone
    # would wrongly warn that a vendored tree predates the module's fixes.
    if ! git -C "$QM_SRC" rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "   NOTE: $QM_SRC is not in a git work tree."
        echo "         If it is the /tmp scratch copy it predates this module's"
        echo "         fixes (sms file store, apn active-cid, band capability,"
        echo "         CCAINFO SINR, staleness). Point QM_SRC at the QManager"
        echo "         tree before building, e.g.:"
        echo "           QM_SRC=$SRC_DIR/../qmanager ./install.sh --build"
    else
        # "dirty" means files that reach the build. Uncommitted docs/ notes do
        # not, and flagging those would train the reader to ignore the warning.
        _sha=$(cd "$QM_SRC" && git rev-parse --short HEAD 2>/dev/null || echo '?')
        _dirty=$(cd "$QM_SRC" && git status --porcelain 2>/dev/null | grep -v '^.. docs/' | head -1)
        echo "   source tree: $_sha$([ -n "$_dirty" ] && echo ' (uncommitted changes outside docs/)')"
    fi
    ( cd "$QM_SRC" && bun install --frozen-lockfile && bun run build ) || die "bun build failed"
    [ -d "$QM_SRC/out" ] || die "no $QM_SRC/out after build"

    echo "== staging $STAGE_DIR =="
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR/www/cgi-bin" "$STAGE_DIR/lib" "$STAGE_DIR/bin"

    cp -a "$QM_SRC/out/." "$STAGE_DIR/www/"
    cp -a "$QM_SRC/scripts/www/cgi-bin/quecmanager" "$STAGE_DIR/www/cgi-bin/"
    cp -a "$QM_SRC/scripts/usr/lib/qmanager/." "$STAGE_DIR/lib/"
    cp -a "$QM_SRC/scripts/usr/bin/." "$STAGE_DIR/bin/"
    # X16-specific native neighbour scan worker, kept alongside the AT shim.
    cp -a "$SRC_DIR/qmanager_neighbour_scanner" "$STAGE_DIR/bin/"
    cp -a "$QM_SRC/deploy/sudo" "$STAGE_DIR/bin/"

    # libqmi CLI + its two private shared libraries. This is the ONLY transport
    # for the neighbour page's "Live" range: qmanager_poller's
    # neighbours_live_tick() returns early unless qm_qmi_available succeeds, and
    # qmi_read.sh resolves /data/qmanager/lib/qmi/bin/qmicli. Upstream stages
    # the same three files (deploy/README.md); the X16 adaptation had dropped
    # that step, so the poller logged "QMI unavailable - live view idle" once a
    # minute and the Live range showed an empty table forever.
    #
    # LGPL-2.1-or-later: shipped as separate, dynamically linked, replaceable
    # .so files on purpose (dependencies/NOTICE). Do not amalgamate them, and
    # do not symlink the firmware's own libqmi.so.1/libqrtr.so.1 - those are
    # Qualcomm's C QMI, a different ABI that qmicli cannot use.
    # cp -a preserves the two version symlinks that LD_LIBRARY_PATH needs.
    if [ -d "$QM_SRC/dependencies/qmi/bin" ]; then
        mkdir -p "$STAGE_DIR/lib/qmi"
        cp -a "$QM_SRC/dependencies/qmi/bin" "$STAGE_DIR/lib/qmi/"
        cp -a "$QM_SRC/dependencies/qmi/lib" "$STAGE_DIR/lib/qmi/"
        chmod 755 "$STAGE_DIR/lib/qmi/bin/qmicli"
    else
        die "$QM_SRC/dependencies/qmi/bin missing - the live neighbour range needs qmicli"
    fi

    # The History page's durable archive must not depend on optional QMI/ubus
    # hardware: retain real Tier-1 LTE context on SIMCom devices. These patches
    # are idempotently skipped when QM_SRC already contains the fix.
    if ! grep -q 'qm_phy_archive_has_source' "$STAGE_DIR/lib/phy_metrics.sh" || \
       ! grep -q 'qm_phy_archive_has_source "$md" "$at" "$ctx"' "$STAGE_DIR/bin/qmanager_poller"; then
        command -v patch >/dev/null 2>&1 || die "patch is required to apply the X16 history fallback"
        if ! grep -q 'qm_phy_archive_has_source' "$STAGE_DIR/lib/phy_metrics.sh"; then
            ( cd "$STAGE_DIR/lib" && patch -p1 < "$SRC_DIR/phy_metrics_history_context.patch" ) || die "PHY history patch failed"
        fi
        if ! grep -q 'qm_phy_archive_has_source "$md" "$at" "$ctx"' "$STAGE_DIR/bin/qmanager_poller"; then
            ( cd "$STAGE_DIR/bin" && patch -p1 < "$SRC_DIR/qmanager_poller_history_archive.patch" ) || die "poller history patch failed"
        fi
    fi

    # Tier 3 (Detailed Metrics: CQI/RI/MCS on both PHY cards, plus `registered`)
    # needs a modem daemon this firmware does not have and speaks AT+QNWCFG,
    # which is Quectel -- SIMCom has no such command. Both halves therefore
    # published null and every metric on the page was a dash while the stock UI
    # showed the numbers. This patch adds the vendor dialer's devinfo dump
    # (/tmp/.devinfo_module_data) as a third, fail-soft source: the fields the
    # stock UI renders, read with one `cat` and no AT lock.
    if ! grep -q 'the vendor devinfo store (ZLT X16' "$STAGE_DIR/lib/phy_metrics.sh"; then
        command -v patch >/dev/null 2>&1 || die "patch is required for the devinfo PHY source"
        ( cd "$STAGE_DIR/lib" && patch -p1 < "$SRC_DIR/phy_metrics_x16_devinfo.patch" ) \
            || die "phy_metrics devinfo patch failed"
    fi

    # qmi_read.sh runs qmicli through platform.sh's qm_timeout, which is a shell
    # FUNCTION. This firmware's sh is ash, where `VAR=val func` does not export
    # VAR to the function's children, so LD_LIBRARY_PATH never reached qmicli
    # and every QMI call returned 3 ("unavailable") even with the libraries in
    # place. The patch switches to an explicit export/restore. Idempotent: it is
    # skipped once the marker comment is present.
    if ! grep -q 'LD_LIBRARY_PATH must be EXPORTED' "$STAGE_DIR/lib/qmi_read.sh"; then
        command -v patch >/dev/null 2>&1 || die "patch is required for the QMI LD_LIBRARY_PATH fix"
        ( cd "$STAGE_DIR/lib" && patch -p1 < "$SRC_DIR/qmi_read_ld_library_path.patch" ) \
            || die "qmi_read LD_LIBRARY_PATH patch failed"
    fi

    # X16 overrides: these replace their GreenPacket counterparts.
    cp -a "$SRC_DIR/atcli_smd11" "$SRC_DIR/sms_tool" "$STAGE_DIR/bin/"
    cp -a "$SRC_DIR/qm_serve.sh" "$SRC_DIR/qm_pathfix_x16.sh" \
          "$SRC_DIR/qmanager_traffic.sh" "$SRC_DIR/speedtest" "$STAGE_DIR/bin/"

    # jq is not on the device and is needed by 142 files. The jq release build
    # is statically linked, so the device's glibc 2.31 is irrelevant.
    if [ ! -x "$STAGE_DIR/bin/jq" ]; then
        curl -fsSL -o "$STAGE_DIR/bin/jq" \
            https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-armhf \
            || die "could not fetch jq"
    fi
    chmod +x "$STAGE_DIR/bin/jq"

    # The device's CA store is from 2023 and cannot validate GitHub's issuer.
    [ -s "$STAGE_DIR/etc-cacert.pem" ] || \
        curl -fsSL -o "$STAGE_DIR/etc-cacert.pem" https://curl.se/ca/cacert.pem \
            || die "could not fetch the CA bundle"

    # 85 of 87 CGIs are stored non-executable; busybox httpd would 404 them.
    find "$STAGE_DIR/www/cgi-bin" -type f -exec chmod 755 {} +

    COPYFILE_DISABLE=1 tar czf /tmp/qm-payload.tar.gz -C "$STAGE_DIR" . || die "tar failed"
    echo "   payload: $(du -sh "$STAGE_DIR" | cut -f1) staged, $(ls -l /tmp/qm-payload.tar.gz | awk '{print $5}') bytes compressed"
}

# ---------------------------------------------------------------- verify ----
verify() {
    echo "== verifying =="
    ssh_try '
        echo "payload:    $(du -sh /data/qmanager 2>/dev/null | cut -f1) at /data/qmanager"
        printf "shim:       "; sh -n /data/qmanager/bin/atcli_smd11 2>/dev/null && echo "parses" || echo "MISSING/BROKEN"
        printf "jq:         "; /data/qmanager/bin/jq --version 2>/dev/null || echo MISSING
        printf "qmicli:     "; if [ -x /data/qmanager/lib/qmi/bin/qmicli ]; then
            LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib \
                /data/qmanager/lib/qmi/bin/qmicli --version 2>/dev/null | head -1 || echo "present, will not run"
        else echo MISSING; fi
        printf "qmi live:   "; sh -c ". /data/qmanager/lib/qmi_read.sh; qm_qmi_available && echo available || echo unavailable" 2>/dev/null || echo unavailable
        printf "qmi cells:  "; sh -c ". /data/qmanager/lib/qmi_read.sh; qm_qmi_neighbours" 2>/dev/null | head -c 140; echo
        for u in qmanager-httpd qmanager-poller qmanager-ping qmanager-traffic; do
            printf "%-18s active=%-9s enabled=%s\n" "$u" \
                "$(systemctl is-active $u.service 2>/dev/null)" \
                "$(systemctl is-enabled $u.service 2>/dev/null)"
        done
        for u in qmanager-tower-schedule-apply qmanager-tower-schedule-clear; do
            printf "%-36s " "$u.service"; [ -f /etc/systemd/system/$u.service ] && echo installed || echo MISSING
        done
        printf "%-18s active=%-9s enabled=%s\n" "qmanager-guard.timer" \
            "$(systemctl is-active qmanager-guard.timer 2>/dev/null)" \
            "$(systemctl is-enabled qmanager-guard.timer 2>/dev/null)"
        printf "guard last: "; systemctl status qmanager-guard.service 2>/dev/null | grep -o 'status=[0-9]*/SUCCESS' | head -1 || echo "not run yet"
        printf "in target:  "; systemctl list-dependencies multi-user.target --no-pager 2>/dev/null | grep -q qmanager && echo "yes (daemon-reload since boot)" || echo "no (expected: /etc mounts after systemd; the boot hook is what starts it)"
        printf "boot hook:  "; grep -q start_qmanager /etc/initscripts/StartTZApp 2>/dev/null && echo wired || echo "NOT WIRED"
        printf "httpd:      "; netstat -tln 2>/dev/null | grep -q ":8080 " && echo "listening on :8080" || echo "NOT LISTENING"
        printf "index:      "; curl -s -o /dev/null -m 10 -w "%{http_code}\n" http://127.0.0.1:8080/
        printf "status:     "; /data/qmanager/bin/jq -c "{errors:.errors,carrier:.network.carrier,band:.lte.band,rsrp:.lte.rsrp}" \
            /tmp/qmanager_status.json 2>/dev/null || echo "no status yet"
        printf "ping:       "; /data/qmanager/bin/jq -c "{reachable,last_rtt_ms}" /tmp/qmanager_ping.json 2>/dev/null || echo "not running yet"
        printf "traffic:    "; cat /tmp/qmanager_traffic.json 2>/dev/null || echo "not running yet"
        printf "at clients: "; ps w 2>/dev/null | grep -c "[/]bin/atcmd "
        printf "dialer AT:  "; grep -c "AT send failed" /tmp/logs/DIALER.log 2>/dev/null || echo 0
    ' || die "verification failed"
    echo
    echo "Open http://<x16-lan-ip>:8080/ on the LAN. First run asks for a password."
    echo "The vendor UI on :80/:443 is never touched."
}

# ---------------------------------------------------------------- uninstall --
uninstall() {
    echo "== uninstalling =="
    ssh_try '
        /data/qmanager/bin/qmanager_tower_schedule_arm teardown >/dev/null 2>&1 || true
        for u in qmanager-tower-schedule-apply qmanager-tower-schedule-clear; do
            systemctl stop $u.timer >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/$u.timer /etc/systemd/system/timers.target.wants/$u.timer
            rm -f /etc/systemd/system/$u.service
        done
        for u in qmanager-httpd qmanager-poller qmanager-ping qmanager-traffic; do
            systemctl disable --now $u.service >/dev/null 2>&1
            rm -f /etc/systemd/system/$u.service
        done
        systemctl disable --now qmanager-guard.timer >/dev/null 2>&1
        rm -f /etc/systemd/system/qmanager-guard.service \
              /etc/systemd/system/qmanager-guard.timer \
              /etc/systemd/system/timers.target.wants/qmanager-guard.timer
        # Traffic Engine. Drain the nat REDIRECT before removing the unit: if the
        # rule survives without the engine behind it, every LAN client tcp/80
        # and tcp/443 is redirected to a port nothing is listening on.
        /data/qmanager/bin/qmanager_dpi_run --rule-down >/dev/null 2>&1 || true
        systemctl disable --now qmanager-dpi.service >/dev/null 2>&1
        systemctl disable --now qmanager-dpi-ensure.timer >/dev/null 2>&1
        systemctl stop qmanager-dpi-ensure.service >/dev/null 2>&1
        rm -f /etc/systemd/system/qmanager-dpi.service \
              /etc/systemd/system/qmanager-dpi-ensure.service \
              /etc/systemd/system/qmanager-dpi-ensure.timer \
              /etc/systemd/system/timers.target.wants/qmanager-dpi-ensure.timer \
              /etc/systemd/system/multi-user.target.wants/qmanager-dpi.service \
              /etc/systemd/system/multi-user.target.wants/qmanager-dpi-ensure.service
        systemctl daemon-reload
        sed -i "/start_qmanager start/d" /etc/initscripts/StartTZApp 2>/dev/null
        rm -f /etc/initscripts/start_qmanager
        rm -rf /data/qmanager /etc/qmanager
        echo "removed payload, units and boot hook"
        [ -f /etc/initscripts/StartTZApp.pre-qmanager ] && \
            echo "vendor file backup kept at /etc/initscripts/StartTZApp.pre-qmanager"
    ' || die "uninstall failed"
    echo "To restore the vendor boot file byte-for-byte:"
    echo "  ssh $HOST 'cp /etc/initscripts/StartTZApp.pre-qmanager /etc/initscripts/StartTZApp'"
}

# ------------------------------------------------------------------- main ---
[ -f "$SRC_DIR/atcli_smd11" ] || die "missing $SRC_DIR/atcli_smd11"

case "${1:---install}" in
--build)
    build_payload
    ;;

--check)
    ssh_try 'uname -n' >/dev/null || die "cannot reach $HOST"
    verify
    if [ -f "$SRC_DIR/../tests/check_boot_wiring.sh" ]; then
        echo "== boot wiring =="
        cat "$SRC_DIR/../tests/check_boot_wiring.sh" | \
            ssh -o ConnectTimeout=10 "$HOST" 'cat > /tmp/boot.sh && sh /tmp/boot.sh' || die "boot wiring test failed"
    fi
    ;;

--uninstall)
    uninstall
    ;;

--install)
    echo "== target: $HOST =="
    ssh_try 'uname -n' >/dev/null || die "cannot reach $HOST"

    [ -d "$STAGE_DIR" ] || die "no staged payload at $STAGE_DIR -- run: $0 --build"
    [ -f /tmp/qm-payload.tar.gz ] || die "run: $0 --build (payload tarball missing)"

    echo "== backing up =="
    ssh_try "B='$BACKUP_ROOT'; mkdir -p \$B
        for f in /etc/initscripts/StartTZApp /etc/initscripts/start_qmanager /etc/systemd/system/qmanager-httpd.service /etc/systemd/system/qmanager-tower-schedule-apply.service /etc/systemd/system/qmanager-tower-schedule-clear.service; do
            [ -f \$f ] && cp -f \$f \"\$B/\$(basename \$f).\$(date +%H%M%S)\" 2>/dev/null
        done
        echo \$B" || die "backup failed"

    echo "== pushing payload =="
    push /tmp/qm-payload.tar.gz /tmp/qm-payload.tar.gz || die "payload push failed"

    echo "== extracting =="
    ssh_try "mkdir -p '$QM_ROOT'
        tar xzf /tmp/qm-payload.tar.gz -C '$QM_ROOT'
        find '$QM_ROOT' -name '._*' -type f -delete
        chown -R root:root '$QM_ROOT'; chmod 755 '$QM_ROOT'
        find '$QM_ROOT/bin' '$QM_ROOT/www/cgi-bin' -type f -exec chmod 755 {} +
        find '$QM_ROOT/lib/qmi/bin' -type f -exec chmod 755 {} + 2>/dev/null
        mkdir -p '$QM_ROOT/etc'; [ -f '$QM_ROOT/etc-cacert.pem' ] && mv -f '$QM_ROOT/etc-cacert.pem' '$QM_ROOT/etc/cacert.pem'
        mkdir -p /etc/qmanager; chmod 777 /etc/qmanager
        echo extracted" || die "extract failed"

    echo "== relocating paths =="
    ssh_try "'$QM_ROOT/bin/qm_pathfix_x16.sh'" || die "path fix failed"

    echo "== installing X16 overrides =="
    # qmi-probe: read-only QMI over QRTR with no libqmi. qmi_read.sh prefers it for
    # the band readers when present (48 KB, static, our own code) and falls back to
    # qmicli then AT when it is missing, so a device without it behaves exactly as
    # before. Committed as payload the same way `speedtest` is; rebuild with
    # scripts/qmi-probe/build.sh (zig) after changing qmi-probe.c.
    if [ -f "$SRC_DIR/qmi-probe" ]; then
        push "$SRC_DIR/qmi-probe" "$QM_ROOT/bin/qmi-probe" || die "push of qmi-probe failed"
        ssh_try "chmod 755 '$QM_ROOT/bin/qmi-probe' && '$QM_ROOT/bin/qmi-probe' ports >/dev/null 2>&1 && echo 'qmi-probe answers QRTR' || echo 'qmi-probe: QRTR not answering (qmi_read.sh falls back to qmicli)'"
    fi

    for f in atcli_smd11 sms_tool qm_serve.sh qm_pathfix_x16.sh qmanager_traffic.sh qmanager_neighbour_scanner speedtest qmanager-timesync; do
        push "$SRC_DIR/$f" "$QM_ROOT/bin/$f" || die "push of $f failed"
    done
    ssh_try "chmod 755 '$QM_ROOT/bin/atcli_smd11' '$QM_ROOT/bin/sms_tool' '$QM_ROOT/bin/qm_serve.sh' \
                      '$QM_ROOT/bin/qm_pathfix_x16.sh' '$QM_ROOT/bin/qmanager_traffic.sh' '$QM_ROOT/bin/qmanager_neighbour_scanner' '$QM_ROOT/bin/speedtest'
        sh -n '$QM_ROOT/bin/atcli_smd11' && sh -n '$QM_ROOT/bin/qmanager_neighbour_scanner' && echo 'X16 overrides parse'" || die "override install failed"

    echo "== installing units =="
    for u in $UNITS; do
        push "$SRC_DIR/$u.service" "/etc/systemd/system/$u.service" || die "push of $u.service failed"
    done
    echo "== installing tower schedule service units =="
    for u in $TOWER_SCHEDULE_UNITS; do
        push "$SRC_DIR/$u.service" "/etc/systemd/system/$u.service" || die "push of $u.service failed"
    done
    echo "== installing Traffic Engine units =="
    for u in $DPI_UNITS; do
        push "$SRC_DIR/$u.service" "/etc/systemd/system/$u.service" || die "push of $u.service failed"
    done
    push "$SRC_DIR/$DPI_TIMER.timer" "/etc/systemd/system/$DPI_TIMER.timer" || die "push of $DPI_TIMER.timer failed"
    push "$SRC_DIR/video_domains.txt" "/tmp/video_domains.txt" || die "push of video_domains.txt failed"
    # The Traffic Engine's hostlist. dpi_build_args passes
    # --hostlist=/etc/qmanager/video_domains.txt unconditionally, and the seeder
    # that would create it (qmanager_setup) never runs on this device — so even
    # with the units in place the engine would start against a missing file and
    # the UI would report domains_loaded: 0. Seeded only when absent, so a list
    # the operator edited from the UI is never overwritten.
    ssh_try "
        for f in video_domains.txt video_domains_default.txt; do
            [ -s /etc/qmanager/\$f ] && continue
            cp -f /tmp/video_domains.txt /etc/qmanager/\$f
        done
        chown www-data:www-data /etc/qmanager/video_domains*.txt 2>/dev/null || true
        chmod 644 /etc/qmanager/video_domains*.txt 2>/dev/null || true
        # tpws drops privileges to nobody and then opens the hostlist by path,
        # so it needs TRAVERSE on the directory. /etc/qmanager is 700 (and
        # qmanager re-creates it that way), which made the engine die with
        # "cannot access hostlist file" -- the toggle then reported
        # engine_start_failed. 711 gives traverse without letting anyone list
        # what else is in there (the config and auth files stay unreadable).
        chmod 711 /etc/qmanager
        echo \"hostlist: \$(wc -l < /etc/qmanager/video_domains.txt 2>/dev/null || echo 0) lines\"" || true
    echo "== installing guard timer (the healer) =="
    push "$SRC_DIR/$GUARD.service" "/etc/systemd/system/$GUARD.service" || die "push of $GUARD.service failed"
    push "$SRC_DIR/$GUARD.timer" "/etc/systemd/system/$GUARD.timer" || die "push of $GUARD.timer failed"
    ssh_try "chmod 644 /etc/systemd/system/qmanager-*.service /etc/systemd/system/$GUARD.timer /etc/systemd/system/$DPI_TIMER.timer
        systemctl daemon-reload
        for u in $UNITS; do systemctl enable \$u.service >/dev/null 2>&1; done
        systemctl enable $GUARD.timer >/dev/null 2>&1
        if [ -x '$QM_ROOT/bin/tpws' ]; then
            for u in $DPI_UNITS; do systemctl enable \$u.service >/dev/null 2>&1; done
            systemctl enable $DPI_TIMER.timer >/dev/null 2>&1
        fi
        systemctl daemon-reload
        echo 'units enabled and tower schedule services loaded'" || die "could not enable units"

    echo "== wiring the boot hook =="
    push "$SRC_DIR/start_qmanager" "$HOOK" || die "push of start_qmanager failed"
    ssh_try "chmod 755 '$HOOK'
        [ -f '$BOOT_BACKUP' ] || cp -f '$BOOT_SCRIPT' '$BOOT_BACKUP'
        grep -q 'start_qmanager' '$BOOT_SCRIPT' || \\
            sed -i '/^[[:space:]]*\\/etc\\/initscripts\\/start_dialer start/a\\
\\t### QManager (added by the QManager deployment; see /etc/initscripts/start_qmanager)\\
\\t/etc/initscripts/start_qmanager start \\&' '$BOOT_SCRIPT'
        sh -n '$BOOT_SCRIPT' && echo 'boot hook wired'" || die "could not wire the boot hook"

    echo "== starting =="
    ssh_try "$HOOK start; sleep 8; systemctl is-active $UNITS $GUARD.timer | tr '\\n' ' '" || die "could not start"

    verify
    ;;

*)
    die "unknown option: $1 (use --build, --install, --check or --uninstall)"
    ;;
esac
