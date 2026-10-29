#!/bin/sh
# Install the CPU governor pin on the X16.
#
#   ./install.sh              # deploy + hook + verify
#   ./install.sh --check      # verify only
#   ./install.sh --uninstall  # restore the vendor governor (ondemand) and unhook
#
# Contract (AGENTS.md §4): idempotent, backs up what it replaces, verifies after,
# --uninstall restores vendor behaviour, re-running is safe.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
host=${ZLT_HOST:-zlt-root}
tries=${ZLT_TRIES:-6}
sleep_s=${ZLT_SLEEP:-4}
gov=${GOV:-performance}
vendor_gov=${VENDOR_GOV:-ondemand}
payload=$here/zlt-cpufreq
dest=/etc/initscripts/zlt-cpufreq
hook=/etc/initscripts/StartTZApp
marker='# zlt-cpufreq (installed by router-fix/cpu-governor)'
mode=install

for a in "$@"; do
    case $a in
        --check) mode=check ;;
        --uninstall) mode=uninstall ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

ssh_do() {
    i=0
    while [ "$i" -lt "$tries" ]; do
        i=$((i + 1))
        if ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "$@" 2>/dev/null; then return 0; fi
        sleep "$sleep_s"
    done
    echo "install.sh: ssh to $host failed after $tries tries" >&2
    return 1
}

# Current governors, one line per cpu.
governors() { ssh_do "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do printf '%s ' \"\$(cat \$f 2>/dev/null)\"; done; echo"; }

case $mode in
check)
    echo "== hook present?"
    ssh_do "grep -q 'zlt-cpufreq' $hook && echo '   hooked in StartTZApp' || echo '   NOT hooked'"
    echo "== payload present?"
    ssh_do "[ -x $dest ] && echo '   $dest ok' || echo '   $dest missing'"
    echo "== governors now: $(governors)"
    echo "== last log lines"
    ssh_do "tail -3 /data/log/zlt-cpufreq.log 2>/dev/null || echo '   (no log yet)'"
    ;;

uninstall)
    echo "== unhooking"
    ssh_do "sed -i '/zlt-cpufreq/d' $hook && echo '   hook line removed'"
    echo "== restoring $vendor_gov"
    ssh_do "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo $vendor_gov > \$f 2>/dev/null; done; echo '   done'"
    ssh_do "rm -f $dest && echo '   payload removed'"
    echo "== governors now: $(governors)"
    ;;

install)
    ts=$(date +%Y%m%d)
    echo "== backing up"
    ssh_do "mkdir -p /data/zlt-backups/$ts/cpu-governor && cp -p $hook /data/zlt-backups/$ts/cpu-governor/ && echo '   backed up $hook'"

    echo "== pushing payload"
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "cat > $dest.new && chmod 755 $dest.new && mv -f $dest.new $dest" \
        < "$payload" || { echo "install.sh: push failed" >&2; exit 1; }

    echo "== hooking at the TOP of StartTZApp (boot-time rule: never at the end)"
    ssh_do "grep -q 'zlt-cpufreq' $hook || { cp -p $hook $hook.zlt-cpufreq.bak; { echo '$marker'; echo '[ -x $dest ] && $dest >/dev/null 2>&1 &'; cat $hook.zlt-cpufreq.bak; } > $hook.new && cat $hook.new > $hook && rm -f $hook.new; }; echo '   hooked'"

    echo "== applying now"
    ssh_do "GOV=$gov $dest; echo \"   exit=\$?\""

    echo "== verify"
    echo "   governors: $(governors)"
    ssh_do "tail -3 /data/log/zlt-cpufreq.log 2>/dev/null"
    ;;
esac
