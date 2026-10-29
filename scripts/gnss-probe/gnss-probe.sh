#!/bin/sh
# =============================================================================
# gnss-probe.sh — does this unit get a GNSS fix, and where does the position come from
# =============================================================================
# Host-side, `ZLT_HOST`-parameterised, and non-destructive: it starts a GNSS session
# through SIMCom's own SDK demo (`/usr/bin/example_gnss`, shipped in the image),
# listens for the position indications, and stops the session again.
#
# What it drives (measured 2026-10-29, docs/47):
#   option 12  Set GNSS msg indications   -> the engine only emits NMEA/position
#                                            indications when a bit mask is set
#      then    a bit-mask value on the next line (the demo asks for it)
#   option 1   Start Gnss                 -> "gnss start success!!"
#   option 2   Close Gnss / 99 EXIT       -> clean teardown
#
# The demo also takes ONE extra (empty) line after most prompts, because it mixes
# scanf() and fgets(); the sequence below is the one that works.
#
# WHY NOT QMI LOC. The modem serves service 0x10, but this firmware implements only
# four LOC messages (0x0020-0x0023, all answering "missing-arg"; 0x0024+ answer
# 0x0039 not-implemented) — measured with `qmi-probe raw 0x10 <msg>`. The vendor
# drives GNSS with AT commands forwarded through `atfwd_daemon` (`+CGPSXD`, `+QGPS`,
# `open_nmea_port`), which is what `Sunsea_Gnss_*` wraps. So the SDK is the road,
# not QMI LOC.
#
# Exit: 0 position seen, 3 engine started but no fix within the window,
#       1 transport/ssh failure, 2 usage.
#
# Usage:
#   ./gnss-probe.sh                 # 90 s window, indication mask 127
#   ./gnss-probe.sh --seconds 300   # a cold start with no sky view needs minutes
#   ./gnss-probe.sh --mask 3        # fewer indication classes
#   ./gnss-probe.sh --collect FILE  # also keep the raw session transcript
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-8}"
SECS=90
MASK=127
COLLECT=''

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECS=${2:-90} ; shift 2 ;;
        --mask)    MASK=${2:-127} ; shift 2 ;;
        --collect) COLLECT=${2:-} ; shift 2 ;;
        -h|--help)  sed -n '2,32p' "$0" || sed -n '2,32p' "$0" ; exit 0 ;;
        *) echo "unknown option: $1" >&2 ; exit 2 ;;
    esac
done

case "$SECS" in ''|*[!0-9]*) echo "--seconds must be a number" >&2 ; exit 2 ;; esac

rsh() {
    n=0
    while [ "$n" -lt "$TRIES" ]; do
        if out=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "$1" 2>/dev/null); then
            printf '%s\n' "$out" ; return 0
        fi
        n=$((n + 1)) ; sleep 3
    done
    echo "ERROR: ssh to $HOST failed after $TRIES attempts" >&2
    return 1
}

echo "== GNSS probe on $HOST (window ${SECS}s, indication mask $MASK)"

# The demo is interactive; feed the exact sequence and let the engine run.
# `sleep` inside the braces keeps each answer ahead of its prompt.
RAW=$(rsh "{ echo 12; sleep 1; echo $MASK; sleep 1; echo 1; sleep $SECS; echo 2; sleep 1; echo 99; } \
           | timeout -s KILL $((SECS + 25)) /usr/bin/example_gnss 2>&1") || exit 1

[ -n "$COLLECT" ] && printf '%s\n' "$RAW" > "$COLLECT" && echo "   transcript: $COLLECT"

# --- what the session said --------------------------------------------------
printf '%s\n' "$RAW" | sed -n 's/^.*\(diag:.*\|gnss init .*\|addrxindmsghandle .*\|set indications .*\|gnss start .*\|gnss stop.*\).*$/  \1/p' | head -6

# --- a position, in any of the shapes this firmware emits -------------------
# NMEA sentences ($GPGGA/$GNRMC/…), the demo's degrees-minutes format
# (`%d%09.6lf,N`), or an explicit latitude/longitude field.
POS=$(printf '%s\n' "$RAW" | grep -E '\$GP|\$GN|\$GL|,N,|,S,|,E,|,W,|latitude|longitude|lat:|lon:|alt:' | head -8)
if [ -n "$POS" ]; then
    echo "== FIX"
    printf '%s\n' "$POS" | sed 's/^/  /'
    echo "== result: position obtained"
    exit 0
fi

echo "== no position in ${SECS}s"
printf '%s\n' "$RAW" | grep -q 'gnss start success' \
    && echo "  the engine DID start (session accepted) — so this is a visibility/assistance" \
    || echo "  the engine did not report a start — check simcom-gnss.service and docs/47"
echo "  no sky view, or a cold start with no assistance data: /data/localxtra.bin did not"
echo "  exist on this unit before the first run, so the engine had never been started."
echo "  Retry from the installed position (an ODU is a mast-mounted CPE), or wider:"
echo "    ./gnss-probe.sh --seconds 300 --collect /tmp/gnss.txt"
exit 3
