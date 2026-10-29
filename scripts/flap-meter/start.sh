#!/bin/sh
# Start the flap meter on the device.
#
# Why a sampler at all: the churn this measures has four different causes
# (docs/29, docs/36) and they are distinguished by *what* changed, not by how
# often. AT can only see two of them, at 5 s granularity, holding the shared lock
# ~60% of the window. This runs `qmi-probe watch` -- one process, one NAS socket,
# two GETs per tick (~2 ms) -- so 1 Hz is free on a 1-core box.
#
# Idempotent: re-running restarts the sampler against the same log.
#
#   ./start.sh                       # 1 Hz, heartbeat every 60 s
#   FLAP_INTERVAL=2 ./start.sh       # gentler
#   ZLT_HOST=root@10.0.0.1 ./start.sh
#
# Log: /data/zlt-flapmeter/transitions.log  (on /data, so it survives the
# reboot that wipes /data/log; rotated to .1 past 4 MB)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
probe="$here/../qmi-probe/out/qmi-probe"
host=${ZLT_HOST:-zlt-root}
tries=${ZLT_TRIES:-6}
sleep_s=${ZLT_SLEEP:-4}
interval=${FLAP_INTERVAL:-1}
heartbeat=${FLAP_HEARTBEAT:-60}
dir=/data/zlt-flapmeter
log=$dir/transitions.log
pid=$dir/sampler.pid

ssh_do() {
    i=0
    while [ "$i" -lt "$tries" ]; do
        i=$((i + 1))
        if ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "$@" 2>/dev/null; then return 0; fi
        sleep "$sleep_s"
    done
    echo "start.sh: ssh to $host failed after $tries tries" >&2
    return 1
}

[ -x "$probe" ] || ( cd "$here/../qmi-probe" && ./build.sh >/dev/null )

echo "== pushing qmi-probe ($(wc -c < "$probe" | tr -d ' ') bytes)"
ssh_do "mkdir -p $dir/bin" || exit 1
# Push to a NEW name and mv it into place. `cat > $dir/bin/qmi-probe` fails with
# ETXTBSY whenever the previous sampler is still running from that path -- and
# with stderr dropped it fails SILENTLY, leaving a stale binary that looks pushed
# (cost: one debugging detour on 2026-10-29). mv is atomic and works on a busy
# executable.
ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "cat > $dir/bin/qmi-probe.new && chmod +x $dir/bin/qmi-probe.new" \
    < "$probe" || { echo "start.sh: push failed (stderr?)" >&2; exit 1; }
ssh_do "mv -f $dir/bin/qmi-probe.new $dir/bin/qmi-probe" || exit 1

echo "== starting sampler (interval ${interval}s, heartbeat ${heartbeat}s)"
# The sampler writes its own pid: stopping by pattern is unsafe here, because
# the ssh command line carries the pattern too and `pkill -f` then kills the
# session it is running in (rc=255, no output -- learned the hard way).
ssh_do "
    if [ -f $pid ]; then kill \$(cat $pid) 2>/dev/null && sleep 1; rm -f $pid; fi
    [ -f $log ] && [ \$(wc -c < $log) -gt 4194304 ] && mv -f $log $log.1
    : >> $log
    setsid sh -c 'echo \$\$ > $pid; exec $dir/bin/qmi-probe watch $interval $heartbeat 0' \
        >> $log 2>&1 </dev/null &
    sleep 3
    if [ -f $pid ] && kill -0 \$(cat $pid) 2>/dev/null; then
        echo \"   pid=\$(cat $pid) running\"
    else
        echo '   sampler did NOT stay up'; tail -5 $log; exit 1
    fi
    echo '   first lines:'
    tail -3 $log | sed 's/^/     /'
    echo \"   log: $log (\$(wc -c < $log | tr -d ' ') bytes)\"
" || exit 1

echo
echo "Runs until stopped. Next:"
echo "  ./pull.sh      # fetch the log (+ the dialer log for the join)"
echo "  ./analyze.sh capture/transitions-*.log"
echo "  ./stop.sh      # stop and print the summary"
