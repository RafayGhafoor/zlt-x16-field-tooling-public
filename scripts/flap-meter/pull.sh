#!/bin/sh
# Fetch the transition log and the dialer log so analyze.sh can join them.
#
# The dialer writes /tmp/logs/DIALER.log (tmpfs -- gone at reboot); the vendor
# rotates copies into /data/logs_backup/DIALER.log. Both are fetched when
# present: the live one covers this run, the backup covers older drops.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
host=${ZLT_HOST:-zlt-root}
tries=${ZLT_TRIES:-6}
sleep_s=${ZLT_SLEEP:-4}
out=${1:-$here/capture}
stamp=$(date +%Y%m%d-%H%M%S)
slug=$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '_')

ssh_do() {
    i=0
    while [ "$i" -lt "$tries" ]; do
        i=$((i + 1))
        if ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "$@" 2>/dev/null; then return 0; fi
        sleep "$sleep_s"
    done
    echo "pull.sh: ssh to $host failed after $tries tries" >&2
    return 1
}

mkdir -p "$out"
f="$out/transitions-$slug-$stamp.log"
echo "== transitions -> $f"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" 'cat /data/zlt-flapmeter/transitions.log' > "$f" \
    || { echo "pull.sh: no transition log (/data/zlt-flapmeter/transitions.log)" >&2; exit 1; }
echo "   $(wc -l < "$f" | tr -d ' ') lines, $(grep -c ' CHANGE ' "$f" || true) changes"

for src in /tmp/logs/DIALER.log /data/logs_backup/DIALER.log; do
    name=$(printf '%s' "$src" | tr '/' '_')
    df="$out/dialer-$slug-$stamp$name"
    if ssh_do "test -r $src"; then
        echo "== $src -> $df"
        ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "cat $src" > "$df" 2>/dev/null || rm -f "$df"
        [ -s "$df" ] && echo "   $(wc -l < "$df" | tr -d ' ') lines: $(grep -c 'Datacall Disconnected' "$df" || true) disconnect(s)"
    fi
done

echo
echo "Next: ./analyze.sh $f [dialer log]"
