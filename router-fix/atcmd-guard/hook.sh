#!/bin/sh
# =============================================================================
# hook.sh — install / remove / check this module's line in StartTZApp
# =============================================================================
# Device-side controller. It exists so that all quoting, sed/ash dialect and
# "where exactly is the top of this file" handling lives HERE, on the device, where
# it is exercised — instead of inside a nested ssh string in install.sh. (That is the
# same reason router-fix/ttl-normalise puts `install-hook` in zlt-ttlnorm.)
#
# THE RULE THAT COST A DEPLOY:
#   "Insert the hook at the top of the script" means the first EXECUTABLE line, i.e.
#   AFTER the `#!` line. systemd runs StartTZApp directly —
#   `start_cfgd.service: ExecStop=/etc/initscripts/StartTZApp stop` and TZApp runs it
#   with `start` — so if line 1 stops being `#!...`, execve() returns ENOEXEC and the
#   whole boot wiring (ssh, firewall tuning, TTL, IPACM hook, the call bridge) stops
#   running. sh -n does NOT catch that. This script asserts it every time.
#
# Usage (on the device):
#   hook.sh install     insert (idempotent; strips a previous copy first)
#   hook.sh remove      remove our lines, restore a stray shebang to line 1
#   hook.sh check       exit 0 when wired correctly, 2 when not; prints one line
# =============================================================================
set -u

F=${HOOK_FILE:-/etc/initscripts/StartTZApp}
MARK='zlt-atcmd-guard: start the atcmd_daemon health timer'
LINE='[ -x /data/zlt-atcmd-guard/guard.sh ] && /bin/systemctl start zlt-atcmd-guard.timer >/dev/null 2>&1'

die() { echo "hook.sh: $*" >&2 ; exit 1 ; }

[ -f "$F" ] || die "$F not found"

count() { grep -c -- "$MARK" "$F" 2>/dev/null || true ; }

strip() {
    grep -v -- "$MARK" "$F" | grep -v -F -x "$LINE" > "$F.tmp" || true
    cat "$F.tmp" > "$F"
    rm -f "$F.tmp"
}

# If an earlier version left the shebang below line 1, move it back to the top.
fix_shebang() {
    head -1 "$F" | grep -q '^#!' && return 0
    sb=$(grep -m1 '^#!' "$F" 2>/dev/null || true)
    [ -n "$sb" ] || return 0
    { printf '%s\n' "$sb" ; grep -v '^#!' "$F" ; } > "$F.tmp"
    cat "$F.tmp" > "$F"
    rm -f "$F.tmp"
}

install_hook() {
    _mode=$(stat -c %a "$F" 2>/dev/null || echo 755)
    strip
    fix_shebang
    if head -1 "$F" | grep -q '^#!'; then
        { head -1 "$F"
          printf '# %s\n' "$MARK"
          printf '%s\n' "$LINE"
          tail -n +2 "$F"
        } > "$F.new"
    else
        { printf '# %s\n' "$MARK"
          printf '%s\n' "$LINE"
          cat "$F"
        } > "$F.new"
    fi
    sh -n "$F.new" || { rm -f "$F.new" ; die "new $F does not parse — left the old one alone" ; }
    head -1 "$F.new" | grep -q '^#!' || { rm -f "$F.new" ; die "refusing to install: line 1 would not be a shebang" ; }
    # busybox chmod has NO --reference (it fails silently under 2>/dev/null), so the
    # re-created file keeps the umask default — 644 — and this file is EXECVE'D by
    # systemd. That is how StartTZApp lost its exec bit on 2026-10-29 and would have
    # broken the whole boot chain on the next reboot. Apply the saved mode explicitly.
    chmod "$_mode" "$F.new" 2>/dev/null || chmod 755 "$F.new"
    [ -x "$F.new" ] || { rm -f "$F.new" ; die "refusing to install: $F would not be executable (systemd execve's it)" ; }
    mv "$F.new" "$F"
    [ "$(count)" = "1" ] || die "installed but the marker count is $(count)"
    echo "hook: installed, line 1 = $(head -1 "$F")"
}

remove_hook() {
    strip
    fix_shebang
    echo "hook: removed (marker count now $(count), line 1 = $(head -1 "$F"))"
}

check_hook() {
    n=$(count)
    l1=$(head -1 "$F")
    echo "hook: count=$n line1=$l1"
    [ "$n" = "1" ] || { echo "hook: WRONG — expected exactly 1 marker line" >&2 ; return 2 ; }
    case "$l1" in
        '#!'*) : ;;
        *) echo "hook: WRONG — line 1 is not a shebang, execve() will fail (ENOEXEC)" >&2 ; return 2 ;;
    esac
    sh -n "$F" || { echo "hook: WRONG — $F does not parse" >&2 ; return 2 ; }
    [ -x "$F" ] || { echo "hook: WRONG — $F is not executable; systemd execve's it" >&2 ; return 2 ; }
    echo "hook: ok"
    return 0
}

case "${1:-}" in
    install) install_hook ;;
    remove)  remove_hook ;;
    check)   check_hook ;;
    *)       echo "Usage: $0 { install | remove | check }" >&2 ; exit 1 ;;
esac
