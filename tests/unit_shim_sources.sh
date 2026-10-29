#!/bin/sh
# =============================================================================
# tests/unit_shim_sources.sh — the shim's NON-AT sources
# =============================================================================
# deploy-x16/atcli_smd11 synthesises three Quectel answers from sources that are
# not AT at all, and those are the paths most likely to differ on the next
# device:
#
#   AT+QNWCFG="lte_mimo_layers"     <- lte_rank  in the vendor devinfo store
#   AT+QNWCFG="nr5g_mimo_layers"    <- nr_rank   in the vendor devinfo store
#   AT+QNWCFG="lte_time_advance"    <- qmicli NAS cell location info (us -> index)
#
# and one AT path whose source is easy to conflate:
#
#   AT+QNWPREFCFG="ue_capability_band"  <- AT+CSYSSEL=?        (capability)
#   AT+QNWPREFCFG="policy_band"         <- AT+CSYSSEL="lte_band" (policy)
#
# All three sources are injectable in the shim — QM_PHY_DEVINFO_FILE, QM_QMI_BIN,
# QM_QMI_LIBDIR, QM_QMI_DEV — which is what makes host testing possible. If a
# future edit hardcodes one of those paths again, these tests stop being able to
# see the code at all, so the override is a testability contract, not a
# convenience.
#
#   sh tests/unit_shim_sources.sh            # all tests
#   sh tests/unit_shim_sources.sh mimo       # only tests whose name matches
#
# The contract each group pins is the one QManager's parsers actually read:
#   parse_mimo         (parse_at.sh:685-733)  +QNWCFG: "<name>",<ul>,<dl>
#   parse_time_advance (parse_at.sh:975-1010) +QNWCFG: "lte_time_advance",<en>,<ta>
#   parse_policy_band  greps the quoted keys "lte_band"/"nsa_nr5g_band"/"nr5g_band"
# A miss is a bare OK, never a wrong number: "no reading" and "0 layers" must not
# be the same answer.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHIM="$HERE/../deploy-x16/atcli_smd11"
FAKE_AT="$HERE/fake-atcmd"
FAKE_QMI="$HERE/fake-qmicli"
FIXTURE="$HERE/fixtures/devinfo_sample.txt"
FILTER="${1:-}"

[ -f "$SHIM" ] || { echo "FATAL: shim not found at $SHIM" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: fixture not found at $FIXTURE" >&2; exit 1; }
for f in "$FAKE_AT" "$FAKE_QMI"; do
    [ -x "$f" ] || chmod +x "$f" 2>/dev/null
    [ -x "$f" ] || { echo "FATAL: $f is not executable" >&2; exit 1; }
done

PASS=0
FAIL=0
FAILED_NAMES=""

WORK=$(mktemp -d)
# The shim's time-advance path calls a bare `timeout`, which macOS does not
# ship (its coreutils `timeout` is an optional install). Without a stand-in the
# conversion would never run on a developer machine and these tests would pass
# for the wrong reason: a missing `timeout` looks exactly like "QMI said
# nothing". So put one on PATH for every run.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/timeout" <<'STUB'
#!/bin/sh
# stand-in for busybox/coreutils `timeout`: `timeout <secs> <cmd> [args...]`
# FAKE_TIMEOUT_EXPIRED=1 simulates the deadline firing (exit 124, no output).
[ -n "${FAKE_TIMEOUT_EXPIRED:-}" ] && exit 124
shift
exec "$@"
STUB
chmod +x "$WORK/bin/timeout"
PATH="$WORK/bin:$PATH"
export PATH

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

# --- tiny assertion helpers (same shape as unit_atcli_smd11.sh) --------------
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  - $1
    $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

assert_contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "expected to contain [$2] in [$3]" ;;
    esac
}

assert_not_contains() {
    case "$3" in
        *"$2"*) bad "$1" "should NOT contain [$2] in [$3]" ;;
        *) ok "$1" ;;
    esac
}

# The fail-soft contract for these sources: a bare OK and nothing else. Not
# "OK with a 0 in it", not ERROR — the caller has to be able to tell "the modem
# did not report this" from "the modem reported nothing to report".
assert_bare_ok() {
    _b=$(printf '%s\n' "$2" | tr -d '\r' | grep -v '^[[:space:]]*$')
    if [ "$_b" = "OK" ]; then
        ok "$1"
    else
        bad "$1" "expected a bare OK with no payload; got [$(printf '%s' "$_b" | tr '\n' '|')]"
    fi
}

# run <AT command> — shim against the fake modem, fresh caches per call so no
# test can inherit another's cached serving cell or identity answer.
run() {
    _c="$WORK/cpsi.cache"
    rm -f "$_c"
    rm -rf "$WORK/atcache"
    QM_CPSI_CACHE="$_c" QM_AT_CACHE_DIR="$WORK/atcache" QM_AT_BLACKLIST="$WORK/at.blacklist" \
        ATC="$FAKE_AT" sh "$SHIM" "$1"
    _rc=$?
    rm -f "$_c"
    rm -rf "$WORK/atcache"
    return $_rc
}

# store_with [<sed program>] — the captured devinfo fixture, optionally with one
# field perturbed, so every edge case below is a visible delta from real device
# data rather than a hand-written file. Prints the store path.
store_with() {
    if [ $# -eq 0 ]; then
        cp "$FIXTURE" "$WORK/devinfo"
    else
        sed "$1" "$FIXTURE" > "$WORK/devinfo"
    fi
    printf '%s' "$WORK/devinfo"
}

# qnwcfg_field <output> <n> — nth comma-separated field of the first +QNWCFG
# payload line, prefix stripped, so field 1 is the quoted key name.
qnwcfg_field() {
    printf '%s\n' "$1" | grep '^+QNWCFG:' | head -1 \
        | sed 's/^+QNWCFG: //' \
        | awk -F',' -v n="$2" '{gsub(/^[ \t]+|[ \t\r]+$/,"",$n); print $n}'
}

# count of +QNWCFG payload lines (a bare OK must be 0)
qnwcfg_lines() {
    printf '%s\n' "$1" | grep -c '^+QNWCFG:'
}

want() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

# ===========================================================================
echo "== mimo: AT+QNWCFG=*_mimo_layers  <-  devinfo lte_rank / nr_rank =="
# ===========================================================================
if want mimo; then
    # The live store: lte_rank:2, nr_rank:2, MIMO_STATUS empty.
    dev=$(store_with)
    out=$(QM_PHY_DEVINFO_FILE="$dev" run 'AT+QNWCFG="lte_mimo_layers"')
    # parse_mimo et al grep the exact quoted key; a renamed key is invisible.
    assert_contains "LTE MIMO answers the Quectel key parse_mimo greps" \
        '+QNWCFG: "lte_mimo_layers"' "$out"
    # field order is <ul>,<dl>: "LTE 1x2" for a rank-2 link.
    assert_eq "LTE UL is 1 layer"   '1' "$(qnwcfg_field "$out" 2)"
    assert_eq "LTE DL is the rank"  '2' "$(qnwcfg_field "$out" 3)"
    assert_eq "LTE MIMO line is exactly 1x2" \
        '+QNWCFG: "lte_mimo_layers",1,2' "$(printf '%s\n' "$out" | grep '^+QNWCFG:')"
    # The UL figure is a documented inference (single-layer UL); if it ever
    # starts mirroring the rank the tile would claim 2x2 UL the radio never did.
    assert_not_contains "UL layer count is not copied from the DL rank" \
        '"lte_mimo_layers",2,2' "$out"
    assert_eq "LTE MIMO ends in one OK" '1' "$(printf '%s' "$out" | grep -c '^OK')"

    out=$(QM_PHY_DEVINFO_FILE="$dev" run 'AT+QNWCFG="nr5g_mimo_layers"')
    assert_eq "NR5G MIMO uses the NR key" \
        '+QNWCFG: "nr5g_mimo_layers",1,2' "$(printf '%s\n' "$out" | grep '^+QNWCFG:')"

    # The poller issues its reads as a compound chain; both arms must survive it.
    out=$(QM_PHY_DEVINFO_FILE="$dev" run 'AT+QNWCFG="lte_mimo_layers";+QNWCFG="nr5g_mimo_layers"')
    assert_eq "a chain answers both MIMO keys" '2' "$(qnwcfg_lines "$out")"

    # --- in-range boundaries ------------------------------------------------
    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:1/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_eq "rank 1 (lowest valid) is published" '1,1' \
        "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^+QNWCFG: "lte_mimo_layers",//')"

    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:8/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_eq "rank 8 (highest valid) is published" '1,8' \
        "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^+QNWCFG: "lte_mimo_layers",//')"

    # --- out of range: a bare OK, never a fabricated layer count ------------
    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:9/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "rank 9 (above the 1..8 bound) answers a bare OK" "$out"
    assert_eq "  ... and emits no payload line" '0' "$(qnwcfg_lines "$out")"

    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:0/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "rank 0 is 'no data', not zero layers" "$out"

    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:25/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "a two-digit rank above the bound is refused" "$out"

    # --- value shapes the store can hold -----------------------------------
    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "an EMPTY rank is 'not reported', not 0x0" "$out"

    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank:abc/')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "a non-numeric rank is not parsed as a number" "$out"

    # The dialer rewrites this file ~1x/s; padding is not part of the contract.
    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^lte_rank:2$/lte_rank: 3 /')" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_eq "whitespace around the rank is tolerated" '1,3' \
        "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^+QNWCFG: "lte_mimo_layers",//')"

    # nr_rank is empty on this unit whenever the NR leg is down (the live
    # capture today): the NR tile must say "unavailable", not "1x0".
    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^nr_rank:2$/nr_rank:/')" run 'AT+QNWCFG="nr5g_mimo_layers"')
    assert_bare_ok "empty nr_rank (NR leg down) answers a bare OK" "$out"
    assert_eq "  ... LTE is unaffected by the empty NR key" '1,2' \
        "$(QM_PHY_DEVINFO_FILE="$(store_with 's/^nr_rank:2$/nr_rank:/')" run 'AT+QNWCFG="lte_mimo_layers"' \
           | grep '^+QNWCFG:' | sed 's/^+QNWCFG: "lte_mimo_layers",//')"

    # Key matching is exact-by-name: a store from another vendor that uses
    # nr_rank_5g must NOT be read as nr_rank (that would report the wrong RAT).
    out=$(QM_PHY_DEVINFO_FILE="$(store_with 's/^nr_rank:2$/nr_rank_5g:4/')" run 'AT+QNWCFG="nr5g_mimo_layers"')
    assert_bare_ok "a look-alike key (nr_rank_5g) is not the rank" "$out"

    # --- the store itself missing / unreadable ------------------------------
    out=$(QM_PHY_DEVINFO_FILE="$WORK/no-such-devinfo" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "absent devinfo store answers a bare OK" "$out"
    assert_not_contains "  ... with no ERROR for qcmd to trip on" 'ERROR' "$out"

    # A directory stands in for an unreadable file on any uid (chmod 000 is
    # readable by root, which would make a permission test pass vacuously).
    mkdir -p "$WORK/devinfo-dir"
    out=$(QM_PHY_DEVINFO_FILE="$WORK/devinfo-dir" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "unreadable devinfo store answers a bare OK" "$out"

    # A store that has none of the keys (a different vendor's dump) is absent
    # data, not a rank of 0.
    printf 'RSRP:-88\nSINR:13\n' > "$WORK/devinfo-nokeys"
    out=$(QM_PHY_DEVINFO_FILE="$WORK/devinfo-nokeys" run 'AT+QNWCFG="lte_mimo_layers"')
    assert_bare_ok "a store with no rank keys answers a bare OK" "$out"

    # The shim must still exit 0 whatever it answered: qcmd parses the text.
    QM_PHY_DEVINFO_FILE="$WORK/no-such-devinfo" run 'AT+QNWCFG="lte_mimo_layers"' >/dev/null 2>&1
    assert_eq "MIMO read always exits 0" '0' "$?"
fi

# ===========================================================================
echo "== time advance: AT+QNWCFG=\"lte_time_advance\"  <-  qmicli =="
# ===========================================================================
if want ta; then
    # Microseconds in, TA INDEX out: one index is 16*Ts = 0.520833 us, so
    # index = round(us / 0.520833) = round(us * 1.92). Feeding microseconds
    # through unchanged under-reports cell distance by 1.92x.
    LOG="$WORK/qmi.log"
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_CALL_LOG="$LOG" FAKE_TA_US=8 run 'AT+QNWCFG="lte_time_advance"')
    # The published cross-check: 8 us -> index 15 -> 1.20 km either way
    # (docs/captures/recon-distance-mimo.md:142-146).
    assert_eq "8 us converts to TA index 15" \
        '+QNWCFG: "lte_time_advance",1,15' "$(printf '%s\n' "$out" | grep '^+QNWCFG:')"
    assert_eq "  ... field 2 is the Quectel enabled flag" '1' "$(qnwcfg_field "$out" 2)"
    assert_eq "  ... field 3 is the index"                '15' "$(qnwcfg_field "$out" 3)"
    assert_eq "TA answer ends in one OK" '1' "$(printf '%s' "$out" | grep -c '^OK')"

    # The source really is qmicli's NAS cell location read, on the QRTR device.
    assert_contains "the read asks for NAS cell location info" \
        '--nas-get-cell-location-info' "$(cat "$LOG" 2>/dev/null)"
    assert_contains "the read targets the configured QMI device" \
        '-d qrtr://3' "$(cat "$LOG" 2>/dev/null)"
    assert_contains "the QMI libraries are found via LD_LIBRARY_PATH" \
        'LD_LIBRARY_PATH: /data/qmanager/lib/qmi/lib' "$(cat "$LOG" 2>/dev/null)"
    rm -f "$LOG"

    # Both QMI paths are overridable, because a device that keeps qmicli
    # elsewhere must not need an edit to this shim.
    LOG="$WORK/qmi2.log"
    out=$(QM_QMI_BIN="$FAKE_QMI" QM_QMI_LIBDIR=/opt/qmi/lib QM_QMI_DEV=qrtr://7 \
          FAKE_QMI_CALL_LOG="$LOG" FAKE_TA_US=8 run 'AT+QNWCFG="lte_time_advance"')
    assert_contains "QM_QMI_DEV override reaches qmicli" '-d qrtr://7' "$(cat "$LOG" 2>/dev/null)"
    assert_contains "QM_QMI_LIBDIR override reaches qmicli" 'LD_LIBRARY_PATH: /opt/qmi/lib' "$(cat "$LOG" 2>/dev/null)"
    assert_contains "  ... and the conversion still works" ',1,15' "$out"
    rm -f "$LOG"

    # --- the arithmetic, including the rounding direction -------------------
    # Truncation instead of rounding would answer 1 here, and 5 below: those
    # two are the cheap way to prove the conversion rounds.
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=1 run 'AT+QNWCFG="lte_time_advance"')
    assert_eq "1 us -> 2 (1.92 rounds up; truncation would give 1)" ',1,2' "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^.*"lte_time_advance"//')"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=2 run 'AT+QNWCFG="lte_time_advance"')
    assert_eq "2 us -> 4 (3.84)" ',1,4' "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^.*"lte_time_advance"//')"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=3 run 'AT+QNWCFG="lte_time_advance"')
    assert_eq "3 us -> 6 (5.76 rounds up; truncation would give 5)" ',1,6' "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^.*"lte_time_advance"//')"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=5 run 'AT+QNWCFG="lte_time_advance"')
    assert_eq "5 us -> 10 (9.6)" ',1,10' "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^.*"lte_time_advance"//')"

    # 667*1.92 = 1280.6 -> 1281, the highest index this rounding can reach
    # under the 1..1282 clamp calculateLteDistance enforces.
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=667 run 'AT+QNWCFG="lte_time_advance"')
    assert_eq "667 us -> 1281 (top of the published range)" ',1,1281' "$(printf '%s\n' "$out" | grep '^+QNWCFG:' | sed 's/^.*"lte_time_advance"//')"

    # --- out of range: a bare OK --------------------------------------------
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=0 run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "0 us means 'no data', not TA index 0" "$out"
    assert_eq "  ... no payload line" '0' "$(qnwcfg_lines "$out")"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=668 run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "668 us (index 1283) is past the 1282 bound" "$out"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=700 run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "700 us (index 1344) is out of range" "$out"

    # libqmi prints 'n/a' when the field is unavailable; that must not be
    # coerced into a number.
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_RAW="LTE Timing Advance: 'n/a' us" run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "a non-numeric TA value is not converted" "$out"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_RAW="LTE Timing Advance: '-8' us" run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "a negative TA value is not converted" "$out"

    # qmicli answered, but with no TA line at all (no serving cell yet).
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_RAW="[qrtr://3] Successfully got cell location info" run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "a cell-location answer with no TA field is 'not reported'" "$out"

    # --- qmicli broken / missing / slow -------------------------------------
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_FAIL=1 run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "qmicli failing answers a bare OK, never ERROR" "$out"

    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_RAW='' run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "an empty qmicli answer is a bare OK" "$out"

    out=$(QM_QMI_BIN="$WORK/no-such-qmicli" run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "a missing qmicli binary is a bare OK" "$out"

    # The shim bounds this read with `timeout` because it runs inside the AT
    # request path; the deadline firing must read as "no reading".
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TIMEOUT_EXPIRED=1 FAKE_TA_US=8 run 'AT+QNWCFG="lte_time_advance"')
    assert_bare_ok "a qmicli read that hits the timeout is a bare OK" "$out"

    # --- NR: there is no source, so there must be no number -----------------
    out=$(QM_QMI_BIN="$FAKE_QMI" FAKE_TA_US=8 run 'AT+QNWCFG="nr5g_time_advance"')
    assert_bare_ok "NR timing advance (no source on this box) is a bare OK" "$out"
    assert_eq "  ... and never borrows the LTE figure" '0' "$(qnwcfg_lines "$out")"

    QM_QMI_BIN="$FAKE_QMI" FAKE_QMI_FAIL=1 run 'AT+QNWCFG="lte_time_advance"' >/dev/null 2>&1
    assert_eq "TA read always exits 0" '0' "$?"
fi

# ===========================================================================
echo "== capability vs policy: which AT query feeds which key =="
# ===========================================================================
if want cap; then
    # Capability and policy are two different modem answers. Emitting the policy
    # under the capability keys shrank the band picker to the already-enabled
    # bands (LTE 1:3:5:41 instead of the modem's 19) — so pin the SOURCE, not
    # just the value: a future edit that reads one query for both keys is the
    # bug coming back.
    LOG="$WORK/cap.log"
    QM_CPSI_CACHE="$WORK/cpsi.cache" QM_AT_CACHE_DIR="$WORK/atcache" \
        QM_AT_BLACKLIST="$WORK/at.blacklist" \
        FAKE_CALL_LOG="$LOG" ATC="$FAKE_AT" sh "$SHIM" 'AT+QNWPREFCFG="ue_capability_band"' >/dev/null 2>&1
    assert_contains "capability is read from AT+CSYSSEL=?" 'AT+CSYSSEL=?' "$(cat "$LOG" 2>/dev/null)"
    rm -f "$LOG"

    LOG="$WORK/pol.log"
    out=$(QM_CPSI_CACHE="$WORK/cpsi.cache" QM_AT_CACHE_DIR="$WORK/atcache" \
          QM_AT_BLACKLIST="$WORK/at.blacklist" \
          FAKE_CALL_LOG="$LOG" ATC="$FAKE_AT" sh "$SHIM" 'AT+QNWPREFCFG="policy_band"')
    assert_contains "policy is read from AT+CSYSSEL=\"lte_band\"" \
        'AT+CSYSSEL="lte_band"' "$(cat "$LOG" 2>/dev/null)"
    # If policy ever started consulting the capability query, the two answers
    # would converge again — the exact regression this pair guards.
    assert_not_contains "policy does NOT consult the capability query" \
        'AT+CSYSSEL=?' "$(cat "$LOG" 2>/dev/null)"
    assert_contains "  ... and policy carries the enabled set" '"lte_band",1:3:5:41' "$out"
    rm -f "$LOG"

    # --- degradation: the modem answers AT+CSYSSEL=? with nothing -----------
    # A device whose capability query is unsupported (or errors) must fall back
    # to the policy band list. The wrong outcomes are an empty band list (the
    # picker renders nothing) or a zero.
    out=$(FAKE_FAIL='AT+CSYSSEL=?' run 'AT+QNWPREFCFG="ue_capability_band"')
    assert_contains "capability=ERROR falls back to the policy list" \
        '+QNWPREFCFG: "lte_band",1:3:5:41' "$out"
    assert_contains "  ... for the NSA NR keys too" \
        '+QNWPREFCFG: "nsa_nr5g_band",1:8:40:41:78' "$out"
    assert_contains "  ... and for the SA NR key" \
        '+QNWPREFCFG: "nr5g_band",1:8:40:41:78' "$out"
    # The fallback must not be the capability list it failed to read.
    assert_not_contains "  ... it is the policy, not the capability set" '18:19:20' "$out"
    assert_eq "  ... no empty band value is emitted" '0' \
        "$(printf '%s\n' "$out" | grep -c '^+QNWPREFCFG: "[a-z0-9_]*",$')"
    assert_eq "  ... and the answer still ends in OK" "OK" \
        "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E '^OK$')"

    # Same contract when the daemon returns an empty reply instead of an error
    # (the shim turns both into ERROR; the fallback must be identical).
    out=$(FAKE_BLANK='AT+CSYSSEL=?' run 'AT+QNWPREFCFG="ue_capability_band"')
    assert_contains "capability=blank falls back to the policy list" \
        '+QNWPREFCFG: "lte_band",1:3:5:41' "$out"
    assert_eq "  ... still no empty band value" '0' \
        "$(printf '%s\n' "$out" | grep -c '^+QNWPREFCFG: "[a-z0-9_]*",$')"
fi

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED_NAMES"
exit 1
