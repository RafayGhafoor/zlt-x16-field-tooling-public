#!/bin/sh
# modem-profile — read-only cellular/CA/band profiler for a ZLT X16-class ODU.
#
#   ./profile.sh                    # collect against $ZLT_HOST (default zlt-root)
#   ./profile.sh --host root@10.0.0.1
#   ./profile.sh --minutes 10       # churn sampling window
#   ./profile.sh --out DIR          # capture directory
#
# Designed to be run unchanged against a NEW router: it discovers paths and
# command support at runtime and never assumes a specific firmware revision.
#
# WHAT IT ANSWERS
#   * what the modem can do  (band capability, CA, NR)  vs
#   * what it is currently allowed to do  (band policy, mode, NR disable)
#   * whether carrier aggregation is actually formed, and how its composition
#     (PCC + SCCs) changes over time -- the "it keeps switching bands" symptom
#   * whether the RF front end is healthy (per-chain RSRP / SINR)
#
# READ-ONLY. It issues no writes, no resets, no unlocks, no MBN/PDC changes.
#
# ============================================================================
# HARD-WON RULES -- every one of these was learned by breaking a live unit.
# Do not "simplify" them away.
#
# 1. THERE IS ONE SHARED AT CHANNEL and `atcmd` has NO internal timeout.
#    A command the modem does not answer blocks the channel FOREVER, which also
#    takes out the QManager poller and the calls bridge. The unit only recovers
#    when `atcmd_daemon` respawns.
#      CONFIRMED HANGING -- never send these:
#        AT+CLAC          (documented in docs/26; still hangs)
#        AT+CNBP?         (hang)
#        AT+CSYSSEL=?     (hang -- this is the capability probe, see rule 4)
#    Hence: EVERY AT call goes through at_cmd(), which applies `timeout` and an
#    allowlist. Adding a command to the allowlist is a deliberate act.
#
# 2. The link drops constantly. Every ssh call retries. The on-device collector
#    runs DETACHED (setsid/nohup) so an ssh drop cannot truncate a long sample.
#
# 3. scp does NOT work (no sftp-server); files are pulled with `ssh 'cat f'`.
#
# 4. The modem's band CAPABILITY cannot be read over AT on this firmware,
#    because the only query (AT+CSYSSEL=?) hangs. It is available from the
#    QManager status JSON instead (`supported_lte_bands`), which the poller
#    fills from a successful read. Use that; never guess a capability list.
#
# 5. `AT+QNWPREFCFG="lte_band"` is a SHIM rename of `AT+CSYSSEL="lte_band"`.
#    The value is a colon list. Reads can come back TRUNCATED (e.g. "1:3" for
#    "1:3:5:28:38:41") when the channel is contended -- a short value is a
#    MEASUREMENT ARTEFACT, not evidence that the policy changed. Re-read before
#    concluding anything (docs/29 was misled by exactly this).
#
# 6. `AT+QCAINFO` is Quectel and ERRORs natively. The CA source here is
#    `AT+CCAINFO?` (PCC/SCC rows). `AT+CPSI?` is the serving cell.
#    CPSI fields 11..14 are RSRQ, RSRP, RSSI, SIL/SNR scaled x10 (RSRP -731 is
#    -73.1 dBm) -- NOT RSRP first.
#
# 7. `/data/log` is WIPED at boot, and this unit reboots without being asked.
#    Captures therefore live on the HOST, and we record uptime at both ends:
#    if uptime went backwards the box rebooted mid-run and the sample is void.
# ============================================================================

set -u

ZLT_HOST="${ZLT_HOST:-zlt-root}"
TRIES="${ZLT_TRIES:-6}"
SLEEP_BETWEEN="${ZLT_SLEEP:-4}"
MINUTES=5
OUT=""
SAMPLE_GAP="${ZLT_GAP:-5}"

# Commands proven to answer on SIM8260E. Anything not here is refused by
# at_cmd() -- that refusal is what protects the shared channel.
AT_ALLOW="
AT
ATI
AT+CGMM
AT+CGMR
AT+CGSN
AT+CIMI
AT+CPIN?
AT+CFUN?
AT+COPS?
AT+CEREG?
AT+CGREG?
AT+C5GREG?
AT+CGATT?
AT+CGACT?
AT+CGDCONT?
AT+CGPADDR
AT+CSQ
AT+CPAS
AT+CNMP?
AT+CPSI?
AT+CCAINFO?
AT+CCELLCFG?
AT+CRSRP?
AT+CSINR?
AT+CSYSSEL=\"lte_band\"
AT+CSYSSEL=\"nsa_nr5g_band\"
AT+CSYSSEL=\"nr5g_band\"
AT+CSYSSEL=\"nr5g_disable\"
AT+CGCONTRDP
"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)    ZLT_HOST="$2"; shift 2 ;;
        --minutes) MINUTES="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --gap)     SAMPLE_GAP="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

STAMP=$(date '+%Y%m%d-%H%M%S')
[ -n "$OUT" ] || OUT="$PWD/modem-profile-$STAMP"
mkdir -p "$OUT" || exit 1

# ---------------------------------------------------------------------------
# ssh with retries. The WAN-facing link on these units drops routinely, so a
# single failure must never abort a collection.
# ---------------------------------------------------------------------------
ssh_do() {
    _i=1
    while [ "$_i" -le "$TRIES" ]; do
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$ZLT_HOST" "$@" 2>/dev/null; then
            return 0
        fi
        _i=$((_i + 1))
        sleep "$SLEEP_BETWEEN"
    done
    return 1
}

# at_cmd is defined ON THE DEVICE, not here, because the allowlist and the
# timeout have to apply where the channel actually is.
install_device_helpers() {
    ssh_do 'cat > /tmp/mp_lib.sh' <<'DEVEOF'
AT_ALLOW="AT ATI AT+CGMM AT+CGMR AT+CGSN AT+CIMI AT+CPIN? AT+CFUN? AT+COPS? AT+CEREG? AT+CGREG? AT+C5GREG? AT+CGATT? AT+CGACT? AT+CGDCONT? AT+CGPADDR AT+CSQ AT+CPAS AT+CNMP? AT+CPSI? AT+CCAINFO? AT+CCELLCFG? AT+CRSRP? AT+CSINR? AT+CSYSSEL=\"lte_band\" AT+CSYSSEL=\"nsa_nr5g_band\" AT+CSYSSEL=\"nr5g_band\" AT+CSYSSEL=\"nr5g_disable\" AT+CGCONTRDP"

ATBIN="${MP_ATBIN:-/bin/atcmd}"

at_allowed() {
    for _a in $AT_ALLOW; do
        [ "$_a" = "$1" ] && return 0
    done
    return 1
}

# timeout is mandatory: an unanswered AT command wedges the shared channel.
at_cmd() {
    if ! at_allowed "$1"; then
        printf 'REFUSED (not in allowlist: %s)\n' "$1"
        return 0
    fi
    timeout 12 "$ATBIN" "$1" 2>&1 | tr -d '\r'
    _rc=$?
    [ "$_rc" -eq 143 ] || [ "$_rc" -eq 124 ] && printf 'TIMEOUT\n'
    sleep 2
}

uptime_s() { cut -d' ' -f1 /proc/uptime; }
DEVEOF
}

# ---------------------------------------------------------------------------
# 1. Identity, host health, and the "did it reboot" markers.
# ---------------------------------------------------------------------------
collect_identity() {
    cat > /tmp/mp_identity.sh <<'DEVEOF'
. /tmp/mp_lib.sh
echo "== uptime_s ==";        uptime_s
echo "== date ==";            date
echo "== loadavg ==";         cat /proc/loadavg
echo "== perf ==";            nproc 2>/dev/null || echo "?"
echo "== identity =="
for c in 'ATI' 'AT+CGMM' 'AT+CGMR' 'AT+CGSN' 'AT+CIMI' 'AT+CPIN?'; do
    echo "--- $c"; at_cmd "$c"
done
echo "== firmware text =="
cat /firmware/image/Ver_Info.txt 2>/dev/null
echo "== product config =="
for k in SYS_CFG_VER SYS_AERA_ID SYS_FW_USER_VER USR_APN_USR_NAME USR_APN_MTU \
         USR_LTE_LOCK_BAND_MASK USR_YOCTO_ORCA_SCG_LIMIT_SW \
         USR_YOCTO_ORCA_SCG_LIMIT_AT_STR SYS_REBOOT_WHEN_MODEM_UNORMAL; do
    v=$(mdlcfg -r "$k" 2>/dev/null)
    [ -n "$v" ] && echo "$k=$v"
done
echo "== top =="
top -b -n 1 2>/dev/null | head -12
DEVEOF
    ssh_do 'cat > /tmp/mp_identity.sh' < /tmp/mp_identity.sh || return 1
    ssh_do 'sh /tmp/mp_identity.sh' > "$OUT/01-identity.txt" 2>&1
}

# ---------------------------------------------------------------------------
# 2. Radio state: what it may do, and what it is doing.
# ---------------------------------------------------------------------------
collect_radio() {
    cat > /tmp/mp_radio.sh <<'DEVEOF'
. /tmp/mp_lib.sh
echo "== policy: band / mode / NR =="
for c in 'AT+CSYSSEL="lte_band"' 'AT+CSYSSEL="nsa_nr5g_band"' \
         'AT+CSYSSEL="nr5g_band"' 'AT+CSYSSEL="nr5g_disable"' 'AT+CNMP?'; do
    echo "--- $c"; at_cmd "$c"
done
echo
echo "== capability (from QManager cache; AT+CSYSSEL=? HANGS) =="
for f in /tmp/qmanager_status.json /data/qmanager/status.json; do
    [ -r "$f" ] || continue
    echo "--- $f"
    tr ',' '\n' < "$f" | grep -iE 'supported_lte_bands|supported_nsa|supported_nr|cells_supported' 
done
echo
echo "== serving cell + RF chains =="
for c in 'AT+CPSI?' 'AT+CRSRP?' 'AT+CSINR?' 'AT+CSQ'; do
    echo "--- $c"; at_cmd "$c"
done
echo
echo "== registration + bearers =="
for c in 'AT+CEREG?' 'AT+C5GREG?' 'AT+COPS?' 'AT+CGATT?' 'AT+CGACT?' 'AT+CCELLCFG?'; do
    echo "--- $c"; at_cmd "$c"
done
echo
echo "== carrier aggregation (AT+CCAINFO? -- NOT QCAINFO) =="
at_cmd 'AT+CCAINFO?'
DEVEOF
    ssh_do 'cat > /tmp/mp_radio.sh' < /tmp/mp_radio.sh || return 1
    ssh_do 'sh /tmp/mp_radio.sh' > "$OUT/02-radio.txt" 2>&1
}

# ---------------------------------------------------------------------------
# 3. Churn sampler. Runs DETACHED so an ssh drop cannot truncate it, and
#    writes to /data/log which is fine for the run but is wiped at boot --
#    the host copy below is the record.
# ---------------------------------------------------------------------------
collect_churn() {
    SAMPLES=$(( MINUTES * 60 / SAMPLE_GAP ))
    cat > /tmp/mp_churn.sh <<DEVEOF
. /tmp/mp_lib.sh
OUT=/data/log/mp-churn.log
: > "\$OUT"
_i=0
while [ \$_i -lt $SAMPLES ]; do
    _i=\$((_i+1))
    _t=\$(date '+%H:%M:%S')
    _c=\$(timeout 12 \$ATBIN 'AT+CPSI?' 2>/dev/null | grep '^+CPSI: LTE' | head -1)
    _a=\$(timeout 12 \$ATBIN 'AT+CCAINFO?' 2>/dev/null | grep '^+CCAINFO' | tr '\n' '|')
    _u=\$(uptime_s)
    echo "\$_t|\$_u|\$_c|\$_a" >> "\$OUT"
    sleep $SAMPLE_GAP
done
echo "MP_CHURN_DONE" >> "\$OUT"
DEVEOF
    ssh_do 'cat > /tmp/mp_churn.sh' < /tmp/mp_churn.sh || return 1
    ssh_do 'setsid nohup sh /tmp/mp_churn.sh >/dev/null 2>&1 </dev/null & echo started' >/dev/null

    echo "  sampling ${MINUTES}min every ${SAMPLE_GAP}s ..."
    _waited=0
    _limit=$(( MINUTES * 60 + 120 ))
    while [ "$_waited" -lt "$_limit" ]; do
        if ssh_do 'grep -q MP_CHURN_DONE /data/log/mp-churn.log 2>/dev/null'; then
            break
        fi
        sleep 15
        _waited=$((_waited + 15))
        printf '.'
    done
    echo
    ssh_do 'cat /data/log/mp-churn.log' > "$OUT/03-churn-raw.txt" 2>&1
}

# ---------------------------------------------------------------------------
# 4. Analysis. Turns the raw rows into the numbers that matter: how often the
#    primary cell or the CA set actually changed.
# ---------------------------------------------------------------------------
analyse() {
    awk -F'|' '
        /MP_CHURN_DONE/ { next }
        NF < 2 { next }
        {
            t = $1; cpsi = $3
            # CCAINFO is several rows; the sampler joins them with "|", so they
            # arrive as fields 4..NF. Reassemble before parsing.
            ca = ""
            for (i = 4; i <= NF; i++) ca = ca $i "|"
            n++

            # ---- serving cell (from CPSI): band / earfcn / pci ----
            # A failed/contended read must NOT look like a cell change: docs/29
            # was misled once by counting blank samples. Skip the sample.
            cell = ""
            if (match(cpsi, /EUTRAN-BAND[0-9]+/)) {
                b = substr(cpsi, RSTART + 11, RLENGTH - 11)
                if (split(cpsi, p, ",") >= 8) cell = "B" b "/" p[8] "/" p[6]
            }
            if (cell == "") { blank++; }
            else if (cell != lastcell) {
                changes++
                if (lastcell != "") printf "  serving cell  %s -> %s   (%s)\n", lastcell, cell, t
                lastcell = cell
            }

            # ---- primary component carrier (from CCAINFO) ----
            pcc = ""
            if (match(ca, /"PCC",EUTRAN_BAND[0-9]+/)) {
                s = substr(ca, RSTART, RLENGTH)
                sub(/.*EUTRAN_BAND/, "", s); pcc = "B" s
            }
            if (pcc != "" && pcc != lastpcc) {
                pccchanges++
                if (lastpcc != "") printf "  PCC change    %s -> %s   (%s)\n", lastpcc, pcc, t
                lastpcc = pcc
            }

            # ---- aggregated band set (order-independent) ----
            set = ""
            for (i = 4; i <= NF; i++) {
                if (match($i, /EUTRAN_BAND[0-9]+/))
                    set = set (substr($i, RSTART + 11, RLENGTH - 11) + 0) " "
            }
            ncc = split(set, _b, " ")
            if (set != lastset) {
                setchanges++
                if (lastset != "") printf "  CA band set   [%s] -> [%s]   (%s)\n", lastset, set, t
                lastset = set
            }
            if (ncc - 1 > maxscc) maxscc = ncc - 1
            if (ncc == 0) nosamples++
        }
        END {
            printf "\n  samples=%d  serving-cell changes=%d  PCC changes=%d  CA-set changes=%d\n",
                   n, changes+0, pccchanges+0, setchanges+0
            printf "  carriers: max %dCC (PCC + %d SCC)\n", maxscc + 1, maxscc
            span = n * GAP
            if (span > 0) {
                if (pccchanges > 0) printf "  mean time between PCC changes:  %d s\n", span / pccchanges
                if (setchanges > 0) printf "  mean time between CA-set changes: %d s\n", span / setchanges
            }
            if (nosamples > 0)
                printf "  note: %d sample(s) had no CCAINFO rows -- CA was not configured then\n", nosamples
            if (blank > 0)
                printf "  note: %d sample(s) had an unreadable CPSI -- excluded, not counted as changes\n", blank
        }
    ' GAP="$SAMPLE_GAP" "$OUT/03-churn-raw.txt" 2>/dev/null

    # A reboot invalidates the window: uptime must be monotonic.
    awk -F'|' '
        /MP_CHURN_DONE/ { next }
        NF < 2 { next }
        { u = $2 + 0
          if (prev != "" && u < prev) { print "  !! uptime went backwards -- box rebooted mid-run, sample void"; bad=1 }
          prev = u }
        END { if (!bad) print "  uptime monotonic -- sample trustworthy" }
    ' "$OUT/03-churn-raw.txt" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 5. Inventory: what firmware/MBN/EFS material exists, for the next investigation.
# ---------------------------------------------------------------------------
collect_inventory() {
    cat > /tmp/mp_inv.sh <<'DEVEOF'
echo "== mcfg packages =="
find /firmware/image/modem_pr/mcfg/configs/mcfg_sw -name 'mcfg_sw.mbn' 2>/dev/null | wc -l
find /firmware/image/modem_pr/mcfg/configs/mcfg_sw/generic -maxdepth 1 -type d 2>/dev/null
echo "== common (region-neutral) packages =="
find /firmware/image/modem_pr/mcfg/configs/mcfg_sw/generic/common -name 'mcfg_sw.mbn' 2>/dev/null | while read -r f; do
    echo "$(sha256sum "$f" 2>/dev/null)"
done
echo "== mbn in the mcfg_sw container: EFS items it sets =="
for f in $(find /firmware/image/modem_pr/mcfg/configs/mcfg_sw/generic/common -name 'mcfg_sw.mbn' 2>/dev/null); do
    echo "--- $f"
    strings -n 4 "$f" 2>/dev/null | grep -c 'nv/item_files'
    strings -n 4 "$f" 2>/dev/null | grep -E 'nv/item_files' | grep -iE 'band|ca_|carrier|rrc|meas' || echo "  (no band/CA/RRC items)"
done
echo "== EFS partitions (raw; not mounted) =="
grep -E 'efs2' /proc/mtd 2>/dev/null
echo "== active PDC config, if qmicli is staged =="
if [ -x /data/zlt-mbn-recovery/bin/qmicli ]; then
    echo "(qmicli present; node id required -- qrtr-ns enumerates it)"
    ps w 2>/dev/null | grep -c qrtr-ns
fi
DEVEOF
    ssh_do 'cat > /tmp/mp_inv.sh' < /tmp/mp_inv.sh || return 1
    ssh_do 'sh /tmp/mp_inv.sh' > "$OUT/04-inventory.txt" 2>&1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
echo "modem-profile -> $OUT"
echo "host: $ZLT_HOST"

printf 'checking reachability ... '
if ! ssh_do 'echo reachable'; then
    echo "UNREACHABLE -- is the device up and is ssh configured?" >&2
    exit 1
fi
echo ok

install_device_helpers || { echo "could not install helpers" >&2; exit 1; }

echo "[1/5] identity + host health"
collect_identity
UP_BEFORE=$(sed -n 's/^== uptime_s ==//p' "$OUT/01-identity.txt" 2>/dev/null | tr -d ' ')
[ -n "$UP_BEFORE" ] || UP_BEFORE=$(awk '/uptime_s/{getline; print; exit}' "$OUT/01-identity.txt" 2>/dev/null | tr -d ' ')

echo "[2/5] radio state + capability"
collect_radio

echo "[3/5] churn sampler"
collect_churn

echo "[4/5] analysis"
analyse | tee "$OUT/05-churn-analysis.txt"

echo "[5/5] firmware / MBN / EFS inventory"
collect_inventory

UP_AFTER=$(ssh_do 'cut -d" " -f1 /proc/uptime' | tr -d ' ')
{
    echo "uptime_before=$UP_BEFORE"
    echo "uptime_after=$UP_AFTER"
    if [ -n "$UP_BEFORE" ] && [ -n "$UP_AFTER" ]; then
        awk -v a="$UP_BEFORE" -v b="$UP_AFTER" 'BEGIN{
            if (b+0 < a+0) print "REBOOTED DURING RUN -- discard the churn window";
            else print "no reboot during run";
        }'
    fi
} > "$OUT/06-run-integrity.txt"

echo
cat "$OUT/06-run-integrity.txt"
echo
echo "captures:"
ls -1 "$OUT"
