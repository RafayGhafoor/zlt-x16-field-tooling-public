#!/bin/sh
# =============================================================================
# at-probe.sh — read-only AT/NV facts the current tools do not expose
# =============================================================================
# Host-side, parameterised by ZLT_HOST, safe to run on a live unit: every command
# below is a QUERY, sent through /bin/atcmd (the vendor's serialised client) with a
# kill-timeout, and nothing is written to the modem, the config or /data.
#
# Why these particular reads (all found in the decompilation, docs/38 §4, docs/42):
#
#   sn        AT+CNVR=2497,0   the module serial number: 15 raw bytes, hex in the
#                              reply. This is the item atcmd_daemon's AT+MODULE_SN
#                              WRITES; reading it needs no NV tool and no write.
#   reboot    AT+CFAILUREMGRCFG? + AT+CBACKUPRESULT + AT+CRESTORECOUNT
#                              the modem's own failure/reboot policy and counters —
#                              the answer to "why did it reboot" that docs/29 could
#                              only infer. Field order of CFAILUREMGRCFG is not
#                              documented anywhere, so it is printed raw.
#   nv        AT+CNVR=<item>,0            read NV by number
#             AT+CNV=<efs-path>,0         read NV by path (the dialer's own form)
#                              a third independent source beside scripts/efs-nv
#                              (DIAG) and scripts/qmi-probe (QMI) — docs/33, docs/36.
#   health    no AT at all: the daemon's fd table (is the indication stream alive?),
#             the vendor log tail, and /tmp/.sockmsg (socket = running daemon,
#             1-byte file = not running). docs/38 §1, docs/39 §4.
#
# Every atcmd call is bounded with `timeout -s KILL` — atcmd ignores SIGTERM and a
# plain timeout leaves the shared channel held (AGENTS.md §6).
#
# Usage:
#   ./at-probe.sh sn
#   ./at-probe.sh reboot
#   ./at-probe.sh nv 2497            # by number
#   ./at-probe.sh nv --path /nv/item_files/modem/mmode/lte_bandpref
#   ./at-probe.sh health
#   ./at-probe.sh all
#
# Environment:
#   ZLT_HOST   ssh target (default: zlt-root)
#   ZLT_TRIES  ssh attempts (default: 8; the link drops regularly)
#   AT_TIMEOUT kill-timeout per AT call (default: 20 s)
# =============================================================================
set -u

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-8}"
AT_TIMEOUT="${AT_TIMEOUT:-20}"

die() { echo "ERROR: $*" >&2 ; exit 1 ; }

# Every ssh call retries: this link drops roughly one connection in three.
#
# stderr is kept OUT of the payload. `2>&1` looked harmless and was not: ssh writes
# its "Permanently added ... to the list of known hosts" and post-quantum warnings to
# stderr, so the captured value began with 3-4 warning lines and every "is the first
# line the echo?" test in this script was looking at the wrong line.
RERR=$(mktemp "${TMPDIR:-/tmp}/at-probe.err.XXXXXX")
trap 'rm -f "$RERR"' EXIT INT TERM
rsh() {
    n=0
    while [ "$n" -lt "$TRIES" ]; do
        if out=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "$1" 2>"$RERR"); then
            printf '%s\n' "$out"
            return 0
        fi
        n=$((n + 1))
        sleep 3
    done
    sed 's/^/  ssh: /' "$RERR" >&2
    return 1
}

# at <cmd> — one bounded AT call, echo line stripped. Never fails the script: an
# ERROR answer is data (it is what the modem said).
at() {
    # tr -d '\r' first: the client's echo line is CRLF-terminated, so a `$`-anchored
    # pattern never matches it (that is why the echo used to survive here).
    # Dropping the whole first line is safe for a display tool: /bin/atcmd always
    # prints the echo on its own line (verified on-device), and no AT response starts
    # with the word atcmd_receive.
    rsh "timeout -s KILL $AT_TIMEOUT /bin/atcmd '$1'" 2>/dev/null \
        | tr -d '\r' \
        | sed '1{/^atcmd_receive:/d;}'
}

hex2ascii() {   # hex on stdin -> printable ASCII, with a dot for NUL
    printf '%s' "$1" | sed 's/../& /g' | tr ' ' '\n' | {
        out=''
        while IFS= read -r h; do
            [ -n "$h" ] || continue
            case "$h" in
                00) out="$out." ;;
                *)  out="$out\\x$h" ;;
            esac
        done
        printf "$out"
    }
}

hdr() { printf '\n== %s\n' "$1" ; }

cmd_sn() {
    hdr "module serial number — AT+CNVR=2497,0 (docs/42 §1)"
    raw=$(at "AT+CNVR=2497,0")
    printf '%s\n' "$raw" | sed -n 's/^+CNVR: [0-9]*,/  hex: /p'
    hex=$(printf '%s\n' "$raw" | sed -n 's/^+CNVR: [0-9]*,"\([0-9A-Fa-f]*\)".*/\1/p')
    if [ -n "$hex" ]; then
        printf '  ascii: %s\n' "$(hex2ascii "$hex" | sed 's/\.*$//')"
        printf '  note: 15 bytes of SN then 0x00 padding; the same item that\n'
        printf '        atcmd_daemon AT+MODULE_SN WRITES with AT+CNVW=2497,0 (docs/38 §4.1)\n'
    else
        printf '  no +CNVR line — the modem did not answer the read\n'
    fi
}

cmd_reboot() {
    hdr "modem failure/reboot policy — AT+CFAILUREMGRCFG?"
    printf '%s\n' "$(at "AT+CFAILUREMGRCFG?")" | sed 's/^/  /'
    printf '  field order is undocumented; two trigger groups are visible (docs/42 §2)\n'
    hdr "backup/restore counters — AT+CBACKUPRESULT / AT+CRESTORECOUNT"
    printf '%s\n' "$(at "AT+CBACKUPRESULT")" | sed 's/^/  /'
    printf '%s\n' "$(at "AT+CRESTORECOUNT")" | sed 's/^/  /'
}

cmd_nv() {
    [ $# -ge 1 ] || die "nv needs an item number or --path <efs-path>"
    if [ "$1" = "--path" ]; then
        p=${2:-} ; [ -n "$p" ] || die "nv --path needs an EFS path"
        hdr "NV by EFS path — AT+CNV=$p,0"
        at "AT+CNV=$p,0" | sed 's/^/  /'
        printf '  read-only form only; the WRITE form (…,0,<hex>,<len>) is not offered here\n'
    else
        case "$1" in *[!0-9]*) die "nv item must be a number (or use --path)" ;; esac
        hdr "NV item $1 — AT+CNVR=$1,0"
        at "AT+CNVR=$1,0" | sed 's/^/  /'
    fi
}

cmd_health() {
    hdr "atcmd_daemon + the indication stream (no AT traffic)"
    rsh 'P=$(pgrep -f "^atcmd_daemon$" | head -1)
         echo "  pid: ${P:-NOT RUNNING}"
         if [ -n "$P" ]; then
             for f in $(ls /proc/$P/fd 2>/dev/null); do
                 t=$(readlink /proc/$P/fd/$f 2>/dev/null)
                 case "$t" in
                     /dev/smd8) echo "  fd $f -> $t  (AT channel)" ;;
                     /dev/smd9) echo "  fd $f -> $t  (indication stream)" ;;
                 esac
             done
             ls -l /proc/$P/fd 2>/dev/null | grep -q "/dev/smd9" \
                 || echo "  WARNING: no /dev/smd9 fd — URCs (calls, SMS, USSD) are dead; see router-fix/atcmd-guard"
         fi'
    hdr "vendor log tail (tmpfs — gone on reboot)"
    rsh 'tail -6 /tmp/logs/ATCMD_DAEMON.log 2>/dev/null | sed "s/^/  /"'
    hdr "sockmsg apps (socket = running, 1-byte file = not)"
    rsh 'ls -l /tmp/.sockmsg 2>/dev/null | awk "NR>1 {print \"  \" \$1 \" \" \$NF}"'
    hdr "guard (if installed)"
    rsh 'tail -3 /data/log/zlt-atcmd-guard.log 2>/dev/null | sed "s/^/  /" || echo "  (no guard log)"'
}

case "${1:-}" in
    sn)      cmd_sn ;;
    reboot)  cmd_reboot ;;
    nv)      shift ; cmd_nv "$@" ;;
    health)  cmd_health ;;
    all)     cmd_health ; cmd_sn ; cmd_reboot ;;
    -h|--help|'') sed -n '2,45p' "$0" ; exit 0 ;;
    *)       die "unknown command: $1 (sn | reboot | nv | health | all)" ;;
esac
