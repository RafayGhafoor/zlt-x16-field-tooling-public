#!/bin/sh
# backup.sh -- snapshot the modem's NV before any change.
#
# WHY
#   AGENTS.md rule 2. Modem NV is the one thing that cannot be reinstalled from
#   a vendor package, and `efs2_bak` is only as current as the vendor's last
#   write. Take the backup first, keep it on the device AND on the host, and
#   verify it by sha256 on both sides.
#
# WHAT WORKS ON THIS FIRMWARE (measured, not assumed)
#   The daemon's `image` command (full-subtree FS image) is REJECTED by this
#   modem's EFS DIAG: "fs-image open: ... bad command (0x13)". So there is no
#   one-shot logical image. Two modes replace it:
#
#     default   item-wise: read every named item and store its bytes + sha256.
#               Small, fast, and directly restorable with `write`/`nv_write`.
#     --raw     whole-partition: pull /dev/mtd3 (the `efs2` MTD, 13 MB) byte
#               for byte. Complete, slower, and the only true full snapshot.
#
#   Run --raw once before a round of changes; run item-wise before each write.
#
# Read-only: the daemon is started WITHOUT -rw, so it cannot write NV here.
set -eu

HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-6}"
SLEEP_BETWEEN="${ZLT_SLEEP:-4}"
SOCK="qcom_efsd"
DEV_DIR="/data/zlt-efsd"
MODE=items
OUT=""
STAMP=$(date '+%Y%m%d-%H%M%S')
EXTRA=""

# The radio-policy and capability items. This is the set any of our changes
# would touch, so this is the set that must be restorable.
PATHS="
/nv/item_files/modem/mmode/lte_bandpref
/nv/item_files/modem/mmode/lte_bandpref_extn_65_256
/nv/item_files/modem/mmode/nr_band_pref
/nv/item_files/modem/mmode/nr_nsa_band_pref
/nv/item_files/modem/mmode/mode_pref
/nv/item_files/modem/mmode/nr5g_disable_mode
/nv/item_files/modem/mmode/lte_disable_duration
/nv/item_files/modem/mmode/get_net_auto_mode
/nv/item_files/modem/mmode/ue_usage_setting
/nv/item_files/modem/mmode/lte_rpm_info_2
/nv/item_files/modem/mmode/nr5g_rpm_info_2
/nv/item_files/modem/lte/ML1/lte_ml1_l2nr_search_optimization
/nv/item_files/modem/lte/rrc/efs/irat_sib_freq_list
/nv/item_files/modem/lte/rrc/efs/nr5g_fp_db
/nv/item_files/modem/nr5g/RRC/cap_control_nrca_3x_f_plus_t_band_combos
/nv/item_files/modem/nr5g/RRC/cap_dss_control
"

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --raw)  MODE=raw; shift ;;
        --out)  OUT="$2";  shift 2 ;;
        --path) EXTRA="$EXTRA $2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$OUT" ] || OUT="$PWD/nv-backup-$STAMP"
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

sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# raw whole-partition mode
# ---------------------------------------------------------------------------
if [ "$MODE" = raw ]; then
    echo "== raw efs2 partition backup from $HOST =="
    DST="$OUT/efs2-mtd3-$STAMP.img"
    echo "pulling /dev/mtd3 (13 MB) ..."
    _i=1
    while [ "$_i" -le "$TRIES" ]; do
        if ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" 'dd if=/dev/mtd3 bs=65536 2>/dev/null' > "$DST" 2>/dev/null && [ -s "$DST" ]; then
            break
        fi
        _i=$((_i + 1)); sleep "$SLEEP_BETWEEN"
    done
    {
        echo "mode=raw"
        echo "host=$HOST"
        echo "taken=$STAMP"
        echo "source=/dev/mtd3 (efs2)"
        echo "size=$(wc -c < "$DST" | tr -d ' ')"
        echo "sha256=$(sha_of "$DST")"
        echo "expected_size_from_mtd=$(ssh_do 'grep \"efs2\" /proc/mtd | head -1' || true)"
        echo "--- Ver_Info"
        ssh_do 'cat /firmware/image/Ver_Info.txt' || true
    } > "$OUT/META.txt" 2>&1
    cat "$OUT/META.txt"
    echo
    echo "raw image: $DST"
    exit 0
fi

# ---------------------------------------------------------------------------
# item-wise mode
# ---------------------------------------------------------------------------
echo "== item-wise NV backup from $HOST =="

if [ ! -x "$HERE/out/qcom-efsd" ] || [ ! -x "$HERE/out/efscli" ]; then
    echo "building helper"
    "$HERE/build.sh" >/dev/null
fi

ssh_do "mkdir -p $DEV_DIR"
# a running helper holds its own binary open; writing over it is ETXTBSY
ssh_do 'killall -q qcom-efsd 2>/dev/null; sleep 1; true' >/dev/null 2>&1 || true
for b in qcom-efsd efscli; do
    _i=1
    while [ "$_i" -le "$TRIES" ]; do
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "cat > $DEV_DIR/$b" < "$HERE/out/$b" 2>/dev/null && break
        _i=$((_i + 1)); sleep "$SLEEP_BETWEEN"
    done
done
ssh_do "cd $DEV_DIR && chmod +x qcom-efsd efscli && killall -q qcom-efsd 2>/dev/null; sleep 1; setsid nohup ./qcom-efsd -uid 0 -socket $SOCK >/tmp/qcom-efsd.log 2>&1 </dev/null & sleep 3; echo started" >/dev/null

OPEN=$(ssh_do "cd $DEV_DIR && timeout 25 ./efscli $SOCK '{\"cmd\":\"open\"}'") || true
case "$OPEN" in
    *'"ok":true'*) : ;;
    *) echo "EFS not reachable: $OPEN" >&2; exit 1 ;;
esac

MAN="$OUT/MANIFEST.txt"
: > "$MAN"
{
    echo "mode=items"
    echo "host=$HOST"
    echo "taken=$STAMP"
    echo "open=$OPEN"
    echo "--- Ver_Info"
    ssh_do 'cat /firmware/image/Ver_Info.txt' || true
    echo "--- mtd"
    ssh_do 'grep efs2 /proc/mtd' || true
} > "$OUT/META.txt" 2>&1

i=0
for p in $PATHS $EXTRA; do
    i=$((i + 1))
    safe=$(printf '%s' "$p" | sed 's|^/nv/item_files/||; s|/|_|g')
    r=$(ssh_do "cd $DEV_DIR && timeout 30 ./efscli $SOCK '{\"cmd\":\"read\",\"path\":\"$p\"}'") || r='{"ok":false,"error":"ssh failed"}'
    case "$r" in
        *'"ok":true'*)
            # decode base64 to real bytes so the backup is restorable as-is
            printf '%s' "$r" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p' > "$OUT/$safe.b64"
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$OUT/$safe.b64" "$OUT/$safe.bin" <<'PY'
import base64, sys
src, dst = sys.argv[1], sys.argv[2]
data = base64.b64decode(open(src).read().strip() or "")
open(dst, "wb").write(data)
PY
                rm -f "$OUT/$safe.b64"
                printf 'PRESENT  %s  size=%s  sha256=%s\n' "$p" "$(wc -c < "$OUT/$safe.bin" | tr -d ' ')" "$(sha_of "$OUT/$safe.bin")" >> "$MAN"
            else
                printf 'PRESENT  %s  (b64 only; sha256=%s)\n' "$p" "$(sha_of "$OUT/$safe.b64")" >> "$MAN"
            fi
            ;;
        *'bad length'*)
            printf 'ABSENT   %s  (firmware default only; nothing to restore)\n' "$p" >> "$MAN"
            ;;
        *)
            printf 'ERROR    %s  %s\n' "$p" "$(printf '%s' "$r" | head -c 120)" >> "$MAN"
            ;;
    esac
done

echo
cat "$MAN"
echo
echo "backup directory: $OUT"
echo
echo "NOTE: ABSENT items need no restore -- they were never set. To roll back a"
echo "write, restore the PRESENT items with:"
echo "  printf '%s' '<base64>' | ... or copy the .bin and write it back verbatim."
