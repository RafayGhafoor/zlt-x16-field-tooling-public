#!/bin/sh
# Install the WAN outage recorder on the X16.
#
#   ./install.sh              # deploy, hook at top of StartTZApp, start now
#   ./install.sh --check      # verification only
#   ./install.sh --uninstall  # stop, unhook, remove
#
# Read-only with respect to the network: reads the vendor dialer log, writes its
# own log under /data. No AT, no QMI, no dialer interaction.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
host=${ZLT_HOST:-zlt-root}
tries=${ZLT_TRIES:-6}
sleep_s=${ZLT_SLEEP:-4}
payload=$here/zlt-wan-recovery
dest=/etc/initscripts/zlt-wan-recovery
hook=/etc/initscripts/StartTZApp
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

case $mode in
check)
    echo "== running?"
    ssh_do "pid=\$(cat /data/zlt-wan-recovery.pid 2>/dev/null); if [ -n \"\$pid\" ] && kill -0 \$pid 2>/dev/null; then echo \"   running pid=\$pid\"; else echo '   not running'; fi"
    echo "== hooked in StartTZApp?"
    ssh_do "grep -q zlt-wan-recovery $hook && echo '   hooked' || echo '   NOT hooked'"
    echo "== state"; ssh_do "cat /data/zlt-wan-recovery.state 2>/dev/null || echo '   (none yet)'"
    echo "== recent outages"; ssh_do "grep OUTAGE /data/zlt-wan-recovery.log 2>/dev/null | tail -5 || echo '   (none yet)'"
    ;;
uninstall)
    ssh_do "if [ -f /data/zlt-wan-recovery.pid ]; then kill \$(cat /data/zlt-wan-recovery.pid) 2>/dev/null && echo '   stopped' || echo '   no such pid'; rm -f /data/zlt-wan-recovery.pid; else echo '   was not running'; fi"
    ssh_do "sed -i '/zlt-wan-recovery/d' $hook && echo '   unhooked'"
    ssh_do "rm -f $dest && echo '   payload removed'"
    echo "   kept the evidence in /data/zlt-wan-recovery.log on purpose"
    ;;
install)
    ts=$(date +%Y%m%d)
    echo "== backing up"
    ssh_do "mkdir -p /data/zlt-backups/$ts/wan-recovery && cp -p $hook /data/zlt-backups/$ts/wan-recovery/ && echo '   backed up $hook'"
    echo "== pushing payload"
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "cat > $dest.new && chmod 755 $dest.new && mv -f $dest.new $dest" \
        < "$payload" || { echo "install.sh: push failed" >&2; exit 1; }
    echo "== hooking at the TOP of StartTZApp (below the shebang)"
    ssh_do "grep -q 'zlt-wan-recovery' $hook || { cp -p $hook $hook.zlt-wan-recovery.bak; awk 'NR==1{print; print \"# zlt-wan-recovery (installed by router-fix/wan-recovery)\"; print \"[ -x $dest ] && $dest >/dev/null 2>&1 &\"; next} {print}' $hook.zlt-wan-recovery.bak > $hook.new && cat $hook.new > $hook && rm -f $hook.new; }; sh -n $hook && echo '   hooked, StartTZApp parses'"
    echo "== starting now"
    ssh_do "if [ -f /data/zlt-wan-recovery.pid ]; then kill \$(cat /data/zlt-wan-recovery.pid) 2>/dev/null; sleep 1; fi; setsid sh -c 'exec $dest' >/dev/null 2>&1 </dev/null & sleep 4; pid=\$(cat /data/zlt-wan-recovery.pid 2>/dev/null); if [ -n \"\$pid\" ] && kill -0 \$pid 2>/dev/null; then echo \"   running pid=\$pid\"; else echo '   FAILED to stay up'; tail -3 /data/zlt-wan-recovery.log; fi"
    echo "== state"; ssh_do "cat /data/zlt-wan-recovery.state 2>/dev/null; tail -2 /data/zlt-wan-recovery.log 2>/dev/null"
    ;;
esac
