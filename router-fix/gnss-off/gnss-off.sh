#!/bin/sh
# =============================================================================
# gnss-off.sh — keep simcom-gnss.service stopped, across reboots
# =============================================================================
# WHY THIS EXISTS (docs/47 §2–§4)
#   `/usr/bin/simcom_gnss` is the vendor's GNSS daemon: 16 threads, ~3 MB RSS, and a
#   QMI LOC client that on this unit has never produced a fix — no assistance data was
#   ever downloaded (`/data/localxtra.bin` absent) and the engine was verified to start
#   (`gnss start success!!`) and then emit nothing in 60 s and 180 s windows. It is a
#   mast-mounted ODU; without sky it cannot fix, and this box has one core.
#
# WHY NOT JUST `systemctl stop`
#   It comes back on the next boot: the enable symlink lives on the READ-ONLY rootfs
#   (`/lib/systemd/system/multi-user.target.wants/simcom-gnss.service`), so it cannot
#   be removed, and `is-enabled` is unreliable for vendor units (AGENTS §5.6).
#   `systemctl disable` cannot touch that symlink.
#
# WHY NOT ONLY `systemctl mask`
#   A mask is a unit file under /etc/systemd/system, and this firmware mounts /etc at
#   ~10.6 s — AFTER systemd has loaded its units — so a mask can be invisible for a
#   boot (AGENTS §4). The mask is applied anyway (it is free and it stops `systemctl
#   start` from working), but the guarantee comes from a boot hook, which runs from the
#   mounted /etc:
#
#       /etc/initscripts/StartTZApp  (after the shebang!)
#
#   That is also the rule that cost a deploy once: the shebang must stay on line 1,
#   because systemd execve's this file (`docs/43` §2.0). This script asserts it.
#
# Usage (on the device):
#   gnss-off.sh apply     stop it now, mask it, and wire the boot hook
#   gnss-off.sh revert    remove the hook, unmask, start it again
#   gnss-off.sh check     exit 0 when off + wired, 2 otherwise
# =============================================================================
set -u

UNIT=${GNSS_UNIT:-simcom-gnss.service}
F=${HOOK_FILE:-/etc/initscripts/StartTZApp}
MARK='gnss-off: simcom-gnss is not used (no fix obtainable, docs/47)'
LINE='[ -x /data/zlt-gnss-off/gnss-off.sh ] && /data/zlt-gnss-off/gnss-off.sh quiet-stop'
SC=${GNSS_SYSTEMCTL:-systemctl}

die() { echo "gnss-off: $*" >&2 ; exit 1 ; }

count() { grep -c -- "$MARK" "$F" 2>/dev/null || true ; }

strip() {
    grep -v -- "$MARK" "$F" | grep -v -F -x "$LINE" > "$F.tmp" || true
    cat "$F.tmp" > "$F" ; rm -f "$F.tmp"
}

fix_shebang() {
    head -1 "$F" | grep -q '^#!' && return 0
    sb=$(grep -m1 '^#!' "$F" 2>/dev/null || true)
    [ -n "$sb" ] || return 0
    { printf '%s\n' "$sb" ; grep -v '^#!' "$F" ; } > "$F.tmp"
    cat "$F.tmp" > "$F" ; rm -f "$F.tmp"
}

install_hook() {
    [ -f "$F" ] || die "$F not found"
    _mode=$(stat -c %a "$F" 2>/dev/null || echo 755)
    strip ; fix_shebang
    if head -1 "$F" | grep -q '^#!'; then
        { head -1 "$F"
          printf '# %s\n' "$MARK"
          printf '%s\n' "$LINE"
          tail -n +2 "$F"
        } > "$F.new"
    else
        die "refusing to install: $F has no shebang to keep on line 1"
    fi
    sh -n "$F.new" || { rm -f "$F.new" ; die "new $F does not parse — old one kept" ; }
    head -1 "$F.new" | grep -q '^#!' || { rm -f "$F.new" ; die "line 1 would not be a shebang" ; }
    # busybox chmod has NO --reference, so this file silently reverted to 644 after a
    # rewrite — and systemd execve's it. Apply the saved mode explicitly.
    chmod "$_mode" "$F.new" 2>/dev/null || chmod 755 "$F.new"
    [ -x "$F.new" ] || { rm -f "$F.new" ; die "$F would not be executable (systemd execve's it)" ; }
    mv "$F.new" "$F"
    [ "$(count)" = "1" ] || die "hook installed but marker count is $(count)"
}

do_stop() {
    "$SC" stop "$UNIT" 2>/dev/null || true
    "$SC" mask "$UNIT" >/dev/null 2>&1 || echo "gnss-off: mask failed (continuing; the hook is the guarantee)" >&2
}

# The hook calls this: stop if it is running, say nothing when it is not.
quiet_stop() {
    if "$SC" is-active --quiet "$UNIT" 2>/dev/null; then
        "$SC" stop "$UNIT" 2>/dev/null || true
        printf '%s %s stopped at boot\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$UNIT" >> /data/log/zlt-gnss-off.log 2>/dev/null
    fi
}

check() {
    act=$("$SC" is-active "$UNIT" 2>&1)
    # systemd 244 has no `is-masked`; LoadState=masked is the portable signal.
    msk=$("$SC" show -p LoadState --value "$UNIT" 2>/dev/null || echo '?')
    echo "gnss-off: unit=$act masked=$msk hook=$(count) line1=$(head -1 "$F" 2>/dev/null)"
    [ "$act" = "inactive" ] || { echo "gnss-off: WRONG — $UNIT is $act" >&2 ; return 2 ; }
    [ "$(count)" = "1" ] || { echo "gnss-off: WRONG — expected 1 hook line, found $(count)" >&2 ; return 2 ; }
    case "$(head -1 "$F" 2>/dev/null)" in
        '#!'*) : ;;
        *) echo "gnss-off: WRONG — $F line 1 is not a shebang (execve will fail)" >&2 ; return 2 ;;
    esac
    sh -n "$F" || { echo "gnss-off: WRONG — $F does not parse" >&2 ; return 2 ; }
    [ -x "$F" ] || { echo "gnss-off: WRONG — $F is not executable (systemd execve's it)" >&2 ; return 2 ; }
    echo "gnss-off: ok"
    return 0
}

case "${1:-}" in
    apply)
        install_hook
        do_stop
        sleep 1
        check
        ;;
    revert)
        strip ; fix_shebang
        "$SC" unmask "$UNIT" >/dev/null 2>&1 || true
        "$SC" start "$UNIT" 2>/dev/null || true
        sleep 1
        echo "gnss-off: reverted — $UNIT is $("$SC" is-active "$UNIT" 2>&1), hook count $(count)"
        ;;
    check)      check ;;
    quiet-stop) quiet_stop ;;
    *)          echo "Usage: $0 { apply | revert | check | quiet-stop }" >&2 ; exit 1 ;;
esac
