#!/bin/sh
# Stop the flap meter and print what it recorded. Read-only.
set -eu
host=${ZLT_HOST:-zlt-root}
tries=${ZLT_TRIES:-6}
sleep_s=${ZLT_SLEEP:-4}
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
    echo "stop.sh: ssh to $host failed after $tries tries" >&2
    return 1
}

echo "== stopping"
ssh_do "if [ -f $pid ]; then kill \$(cat $pid) 2>/dev/null && echo '   stopped' || echo '   no such pid'; rm -f $pid; else echo '   was not running'; fi"
ssh_do "sleep 1; echo '   summary:'; grep SUMMARY $log 2>/dev/null | tail -1 | sed 's/^/     /' || true
         echo \"   changes so far: \$(grep -c '^.* CHANGE ' $log 2>/dev/null || echo 0)\"
         echo \"   log: $log (\$(wc -c < $log 2>/dev/null | tr -d ' ') bytes)\"" || exit 1
echo
echo "Pull it with ./pull.sh, then ./analyze.sh <file>"
