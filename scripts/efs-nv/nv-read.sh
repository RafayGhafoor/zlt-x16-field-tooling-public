#!/bin/sh
# nv-read.sh -- dump interesting modem NV items from a ZLT X16-class router.
#
# Deploys qcom-efsd + efscli, starts the helper READ-ONLY, reads a curated set
# of band/mode/NR items plus whatever a caller lists, and writes the raw JSON
# to a capture directory for decode_nv.py.
#
#   ./nv-read.sh                                  # default host zlt-root
#   ./nv-read.sh --host root@10.0.0.1 --out DIR
#   ./nv-read.sh --item /nv/item_files/...         # add an item (repeatable)
#
# READ-ONLY: the daemon is started without -rw, so every mutating command is
# refused by the helper. Nothing here writes NV.
set -eu

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-6}"
SLEEP_BETWEEN="${ZLT_SLEEP:-4}"
STAMP=$(date '+%Y%m%d-%H%M%S')
OUT=""
SOCK="qcom_efsd"
DEV_DIR="/data/zlt-efsd"
EXTRA=""

# Items that actually exist on this firmware and matter for radio behaviour.
# (Most /nv/item_files/modem/lte/rrc/efs/* names seen inside the modem image
# are firmware DEFAULTS, not live items: reading them returns
# "bad length (0x15)". Only list items that are really present.)
ITEMS="
/nv/item_files/modem/mmode/lte_bandpref
/nv/item_files/modem/mmode/lte_bandpref_extn_65_256
/nv/item_files/modem/mmode/nr_band_pref
/nv/item_files/modem/mmode/nr_nsa_band_pref
/nv/item_files/modem/mmode/mode_pref
/nv/item_files/modem/mmode/nr5g_disable_mode
/nv/item_files/modem/mmode/lte_disable_duration
/nv/item_files/modem/mmode/get_net_auto_mode
/nv/item_files/modem/mmode/ue_usage_setting
/nv/item_files/modem/lte/ML1/lte_ml1_l2nr_search_optimization
/nv/item_files/modem/lte/rrc/efs/irat_sib_freq_list
/nv/item_files/modem/lte/rrc/efs/nr5g_fp_db
"

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --out)  OUT="$2";  shift 2 ;;
        --item) EXTRA="$EXTRA $2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$OUT" ] || OUT="$PWD/nv-$STAMP"
mkdir -p "$OUT"

HERE=$(cd "$(dirname "$0")" && pwd)

ssh_do() {
    _i=1
    while [ "$_i" -le "$TRIES" ]; do
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@" 2>/dev/null && return 0
        _i=$((_i + 1)); sleep "$SLEEP_BETWEEN"
    done
    return 1
}

push() {  # push <local> <remote-basename>
    # The basename must be resolved HERE: inside the remote double-quoted
    # command it would expand on the device, where $2 does not exist.
    _base=$(basename "$2")
    _i=1
    while [ "$_i" -le "$TRIES" ]; do
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "mkdir -p $DEV_DIR && cat > $DEV_DIR/$_base" < "$1" 2>/dev/null && return 0
        _i=$((_i + 1)); sleep "$SLEEP_BETWEEN"
    done
    return 1
}

# 1. build if the binaries are not there yet
if [ ! -x "$HERE/out/qcom-efsd" ] || [ ! -x "$HERE/out/efscli" ]; then
    echo "building (first run)"
    "$HERE/build.sh" >/dev/null
fi

# A running helper holds its own binary open; writing over it fails with
# "Text file busy". Stop it before pushing, not after.
ssh_do 'killall -q qcom-efsd 2>/dev/null; sleep 1; true' >/dev/null 2>&1 || true

echo "deploying helper to $HOST:$DEV_DIR"
push "$HERE/out/qcom-efsd" qcom-efsd || { echo "push failed (qcom-efsd)" >&2; exit 1; }
push "$HERE/out/efscli"   efscli   || { echo "push failed (efscli)" >&2; exit 1; }

# 2. start it read-only. -uid 0 because we connect as root.
echo "starting qcom-efsd (read-only)"
ssh_do "cd $DEV_DIR && chmod +x qcom-efsd efscli && killall -q qcom-efsd 2>/dev/null; sleep 1; setsid nohup ./qcom-efsd -uid 0 -socket $SOCK > /tmp/qcom-efsd.log 2>&1 </dev/null & sleep 3; echo started" >/dev/null

# 3. confirm the transport before dumping anything
OPEN=$(ssh_do "cd $DEV_DIR && timeout 25 ./efscli $SOCK '{\"cmd\":\"open\"}'") || true
printf '%s\n' "$OPEN" > "$OUT/00-open.json"
case "$OPEN" in
    *'"ok":true'*) echo "  transport: $(printf '%s' "$OPEN" | sed -n 's/.*"transport":"\([^"]*\)".*/\1/p')" ;;
    *) echo "EFS open FAILED: $OPEN" >&2
       echo "  if it says ECONNREFUSED, the daemon is not up; if it says qrtr, the"
       echo "  modem is not publishing DIAG on the QRTR bus." >&2
       exit 1 ;;
esac

# 4. read the items
: > "$OUT/01-items.jsonl"
for p in $ITEMS $EXTRA; do
    r=$(ssh_do "cd $DEV_DIR && timeout 30 ./efscli $SOCK '{\"cmd\":\"read\",\"path\":\"$p\"}'") || r='{"ok":false,"error":"ssh failed"}'
    printf '%s|%s\n' "$p" "$r" >> "$OUT/01-items.jsonl"
done

# 5. also record the AT-side view so the two can be compared
ssh_do 'for c in "AT+CSYSSEL=\"lte_band\"" "AT+CSYSSEL=\"nsa_nr5g_band\"" "AT+CSYSSEL=\"nr5g_disable\"" "AT+CNMP?"; do echo "--- $c"; timeout 12 /bin/atcmd "$c" 2>&1; sleep 2; done' \
    > "$OUT/02-at-policy.txt" 2>&1 || true

echo
echo "decoded:"
if command -v python3 >/dev/null 2>&1; then
    python3 "$HERE/decode_nv.py" "$OUT/01-items.jsonl"
else
    echo "  (python3 not found; run decode_nv.py on $OUT/01-items.jsonl)"
fi

echo
echo "captures in $OUT"
echo
echo "to stop the helper:  ssh $HOST 'killall qcom-efsd'"
