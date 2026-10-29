#!/bin/sh
# =============================================================================
# tests/unit_atcli_policy.sh — what the shim REFUSES and how it behaves
# =============================================================================
# Compound chains, the CPSI cache, the allowlist/timeout/blacklist safety net,
# and the performance guardrails. Paired with tests/unit_atcli_dialect.sh.
# =============================================================================
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib_atcli.sh"

echo "== compound chains =="
# ===========================================================================
if want compound; then
    out=$(run 'AT+CVERSION;+CGMM;+CGSN;+CIMI;+QCCID;+CNUM')
    assert_contains "chain: CVERSION block" 'VERSION:' "$out"
    assert_contains "chain: model"          'SIMCOM_SIM8260E' "$out"
    assert_contains "chain: IMEI"           '<imei-redacted>' "$out"
    assert_contains "chain: IMSI"           '<imsi-redacted>' "$out"
    assert_contains "chain: ICCID"          '+QCCID: 89410037251217291419' "$out"

    # order must be preserved: operators read compound replies positionally
    out=$(run 'AT+COPS?;+CPIN?')
    cops_line=$(printf '%s\n' "$out" | grep -n '+COPS:' | cut -d: -f1)
    pin_line=$(printf '%s\n' "$out" | grep -n '+CPIN:' | cut -d: -f1)
    if [ -n "$cops_line" ] && [ -n "$pin_line" ] && [ "$cops_line" -lt "$pin_line" ]; then
        ok "compound replies keep their order"
    else
        bad "compound replies keep their order" "COPS at $cops_line, CPIN at $pin_line"
    fi

    out=$(run 'AT+QENG="servingcell";+QCAINFO=1;+QCAINFO;+QCAINFO=0')
    assert_contains "tier-1 chain keeps QENG"   '+QENG: "servingcell"' "$out"
    assert_contains "tier-1 chain keeps CA rows" '+QCAINFO: "PCC"' "$out"
fi

# ===========================================================================
echo "== +CPSI cache (poller asks 4 times per pass) =="
# ===========================================================================
if want cache; then
    # These assertions deliberately SHARE one cache directory: they are testing
    # the cache. Every other suite isolates it per invocation (tests/lib_atcli.sh).
    CD=$(mktemp -d)
    LOG=$(mktemp); CACHE=$(mktemp -u)
    FAKE_CALL_LOG="$LOG" QM_CPSI_CACHE="$CACHE" QM_AT_CACHE_DIR="$CD" QM_CPSI_TTL=60 \
        ATC="$FAKE" sh "$SHIM" 'AT+QENG="servingcell";+QRSRP;+QRSRQ;+QSINR' >/dev/null 2>&1
    hits=$(grep -c 'AT+CPSI?' "$LOG" 2>/dev/null); hits=${hits:-0}
    assert_eq "one CPSI call serves QENG + all three antenna queries" "1" "$hits"
    rm -f "$LOG" "$CACHE"

    # A second invocation inside the TTL must reuse the snapshot the FIRST one
    # wrote. The stamp is the shim's own (monotonic centiseconds), so the test
    # never has to reproduce the clock -- it primes with one call, then measures
    # the next.
    LOG=$(mktemp)
    FAKE_CALL_LOG="$LOG" QM_CPSI_CACHE="$CACHE" QM_AT_CACHE_DIR="$CD" QM_CPSI_TTL=60 \
        ATC="$FAKE" sh "$SHIM" 'AT+QENG="servingcell"' >/dev/null 2>&1
    rm -f "$LOG"
    LOG=$(mktemp)
    FAKE_CALL_LOG="$LOG" QM_CPSI_CACHE="$CACHE" QM_AT_CACHE_DIR="$CD" QM_CPSI_TTL=60 \
        ATC="$FAKE" sh "$SHIM" 'AT+QENG="servingcell"' >/dev/null 2>&1
    hits=$(grep -c 'AT+CPSI?' "$LOG" 2>/dev/null); hits=${hits:-0}
    assert_eq "a repeat read inside the TTL avoids the modem entirely" "0" "$hits"
    rm -f "$LOG" "$CACHE"

    # ...and an EXPIRED snapshot is never served: stamp 0 is older than any TTL.
    LOG=$(mktemp)
    { printf '0\n'; printf '%s\n' '+CPSI: LTE,Online,410-99,0xDEAD,424242,9,EUTRAN-BAND7,1,1,1,-1,-1000,-1000,0'; } > "$CACHE"
    out=$(FAKE_CALL_LOG="$LOG" QM_CPSI_CACHE="$CACHE" QM_AT_CACHE_DIR="$CD" QM_CPSI_TTL=1 \
        ATC="$FAKE" sh "$SHIM" 'AT+QENG="servingcell"')
    hits=$(grep -c 'AT+CPSI?' "$LOG" 2>/dev/null); hits=${hits:-0}
    assert_eq "an expired snapshot is refetched" "1" "$hits"
    assert_not_contains "  ... and the stale band is not served" 'BAND7' "$out"
    rm -f "$LOG" "$CACHE"

    # A FAILED read must never be cached: a transient ERROR would otherwise
    # outlive the condition for a whole TTL, which is the "modem fine, no data"
    # class of bug this shim exists to avoid.
    LOG=$(mktemp)
    FAKE_FAIL=AT+CSQ FAKE_CALL_LOG="$LOG" QM_AT_CACHE_DIR="$CD" ATC="$FAKE" \
        sh "$SHIM" 'AT+CSQ' >/dev/null 2>&1
    FAKE_FAIL=AT+CSQ FAKE_CALL_LOG="$LOG" QM_AT_CACHE_DIR="$CD" ATC="$FAKE" \
        sh "$SHIM" 'AT+CSQ' >/dev/null 2>&1
    hits=$(grep -c 'AT+CSQ' "$LOG" 2>/dev/null); hits=${hits:-0}
    assert_eq "a failed read is not cached (asked twice, asked twice)" "2" "$hits"
    rm -f "$LOG"

    # A state-changing write drops the snapshots, so no read taken after it can
    # be answered from before it.
    LOG=$(mktemp)
    for _c in 'AT+CSQ' 'AT+CSQ' 'AT+CFUN=1' 'AT+CSQ'; do
        FAKE_CALL_LOG="$LOG" QM_AT_CACHE_DIR="$CD" ATC="$FAKE" sh "$SHIM" "$_c" >/dev/null 2>&1
    done
    hits=$(grep -c 'AT+CSQ' "$LOG" 2>/dev/null); hits=${hits:-0}
    assert_eq "a state write drops the cache (read, cached, write, read)" "2" "$hits"
    rm -f "$LOG"

    # The cache must never widen the allowlist: a refused command is answered
    # locally and leaves no snapshot behind, however often it is asked.
    CD2=$(mktemp -d); BL2=$(mktemp)
    QM_AT_CACHE_DIR="$CD2" QM_AT_BLACKLIST="$BL2" ATC="$FAKE" sh "$SHIM" 'AT+CRSM=176,28539,0,0,12' >/dev/null 2>&1
    out2=$(QM_AT_CACHE_DIR="$CD2" QM_AT_BLACKLIST="$BL2" ATC="$FAKE" sh "$SHIM" 'AT+CRSM=176,28539,0,0,12')
    assert_eq "a refused command stays refused with the cache on" "ERROR" "$(printf '%s' "$out2" | tr -d '\r' | head -1)"
    assert_eq "  ... and left nothing in the cache" "0" "$(ls "$CD2" 2>/dev/null | wc -l | tr -d ' ')"
    rm -rf "$CD2"; rm -f "$BL2"

    # Slots are keyed by the EXACT command: the same prefix with an argument is
    # a different question and must not be answered from the plain one.
    CD3=$(mktemp -d); LOG=$(mktemp)
    FAKE_CALL_LOG="$LOG" QM_AT_CACHE_DIR="$CD3" ATC="$FAKE" sh "$SHIM" 'AT+CGCONTRDP'   >/dev/null 2>&1
    FAKE_CALL_LOG="$LOG" QM_AT_CACHE_DIR="$CD3" ATC="$FAKE" sh "$SHIM" 'AT+CGCONTRDP=6' >/dev/null 2>&1
    assert_contains "CGCONTRDP=6 is not served from the CGCONTRDP slot" \
        'AT+CGCONTRDP=6' "$(cat "$LOG" 2>/dev/null)"
    rm -f "$LOG"; rm -rf "$CD3"
    rm -rf "$CD"
fi

# ===========================================================================
echo "== --peek: the lock-free read contract =="
# ===========================================================================
if want peek; then
    # --peek exists so a cache-fresh read never has to take the AT lock. Its whole
    # value rests on three properties, each asserted here: it never opens the
    # modem, it never writes anything, and it says so (exit 3) instead of
    # answering when the snapshot is not usable.
    CD4=$(mktemp -d); LOG=$(mktemp); BL4=$(mktemp)
    out=$(QM_AT_CACHE_DIR="$CD4" QM_AT_BLACKLIST="$BL4" FAKE_CALL_LOG="$LOG" \
          ATC="$FAKE" sh "$SHIM" --peek 'AT+CGMM' 2>&1); rc=$?
    assert_eq "peek on a cold cache exits 3"            "3" "$rc"
    assert_eq "  ... and prints nothing usable"         ""  "$out"
    assert_eq "  ... and never touches the modem"       "0" "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')"
    assert_eq "  ... and writes no snapshot"            "0" "$(ls "$CD4" 2>/dev/null | wc -l | tr -d ' ')"

    # prime, then peek: answer served, still one modem call in total
    QM_AT_CACHE_DIR="$CD4" QM_AT_BLACKLIST="$BL4" FAKE_CALL_LOG="$LOG" \
        ATC="$FAKE" sh "$SHIM" 'AT+CGMM' >/dev/null 2>&1
    out=$(QM_AT_CACHE_DIR="$CD4" QM_AT_BLACKLIST="$BL4" FAKE_CALL_LOG="$LOG" \
          ATC="$FAKE" sh "$SHIM" --peek 'AT+CGMM'); rc=$?
    assert_eq "peek on a warm cache exits 0"            "0" "$rc"
    assert_contains "  ... with the real answer"         'SIMCOM_SIM8260E' "$out"
    assert_eq "  ... and still one modem call"          "1" "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')"

    # a compound where only the first part is cached must not be half-answered
    out=$(QM_AT_CACHE_DIR="$CD4" QM_AT_BLACKLIST="$BL4" \
          ATC="$FAKE" sh "$SHIM" --peek 'AT+CGMM;+CSQ'); rc=$?
    assert_eq "peek refuses a compound with a stale part" "3" "$rc"
    rm -rf "$CD4"; rm -f "$LOG" "$BL4"
fi

# ===========================================================================
echo "== daemon safety (allowlist / timeout / blacklist) =="
# ===========================================================================
if want safety; then
    # Commands that are not verified must never reach the daemon. The fake
    # answers OK to anything, so an ERROR here proves the shim short-circuited.
    for c in 'AT+CRSM=176,28539,0,0,12' 'AT+QMBNCFG="list"' 'AT+QSCAN=1' 'AT+COPS=?'; do
        out=$(run "$c")
        assert_eq "unverified [$c] is refused without contacting the daemon" "ERROR" "$(printf '%s' "$out" | tr -d '\r' | head -1)"
    done

    # IMEI reads map to the safe command; writes are TRANSLATED to SIMCom's
    # AT+SIMEI= and reach the modem only for an exact 15-digit value.
    out=$(run 'AT+EGMR=0,7')
    assert_contains "IMEI read maps to AT+CGSN" '<imei-redacted>' "$out"

    # A valid write is translated, not refused. The fake modem records the
    # command it received so the translation itself is asserted, not just the OK.
    LOG=$(mktemp)
    out=$(FAKE_CALL_LOG="$LOG" run 'AT+EGMR=1,7,"490154203237518"')
    assert_contains "IMEI write answers OK" 'OK' "$out"
    assert_eq "IMEI write became AT+SIMEI=<15 digits>" \
        'AT+SIMEI=490154203237518' "$(grep SIMEI "$LOG" | head -1)"
    rm -f "$LOG"

    # The gate is the value shape: anything that is not 15 digits, and the
    # placeholder identities vendor tools write as a "blank", must not reach it.
    for bad in 'AT+EGMR=1,7,"49015420323751"' 'AT+EGMR=1,7,"4901542032375189"' \
               'AT+EGMR=1,7,"49015420323751a"' 'AT+EGMR=1,7,""' \
               'AT+EGMR=1,7,"000000000000000"'; do
        LOG=$(mktemp)
        out=$(FAKE_CALL_LOG="$LOG" run "$bad")
        assert_eq "IMEI write refuses [$bad]" "ERROR" "$(printf '%s' "$out" | tr -d '\r' | head -1)"
        # grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would
        # append a second line; take grep's own count.
        assert_eq "  ... and never reaches the modem" "0" "$(grep -c SIMEI "$LOG" 2>/dev/null | head -1)"
        rm -f "$LOG"
    done

    # A wrong record/pair is still refused (this is not a general EGMR gateway).
    out=$(run 'AT+EGMR=1,4,"490154203237518"')
    assert_eq "AT+EGMR=1,4 is refused" "ERROR" "$(printf '%s' "$out" | tr -d '\r' | head -1)"

    # A hanging command must time out, return ERROR, and be blacklisted so the
    # daemon is never asked again (this is the 2026-10-26 WAN outage in a test).
    BL=$(mktemp)
    out=$(QM_AT_BLACKLIST="$BL" QM_AT_TIMEOUT=1 FAKE_HANG=AT+CSQ run 'AT+CSQ')
    assert_eq "hanging command returns ERROR" "ERROR" "$(printf '%s' "$out" | tr -d '\r' | head -1)"
    assert_contains "hanging command is blacklisted" "AT+CSQ" "$(cat "$BL")"
    out=$(QM_AT_BLACKLIST="$BL" FAKE_HANG=AT+CSQ run 'AT+CSQ')
    assert_eq "blacklisted command short-circuits" "ERROR" "$(printf '%s' "$out" | tr -d '\r' | head -1)"
    rm -f "$BL"

    # ...and a healthy command still works when a different one is blacklisted
    BL=$(mktemp); echo 'AT+CRSM=x' > "$BL"
    out=$(QM_AT_BLACKLIST="$BL" run 'AT+CSQ')
    assert_contains "unrelated commands still reach the modem" '+CSQ: 24,99' "$out"
    rm -f "$BL"
fi

# ===========================================================================
echo "== performance guardrails =="
# ===========================================================================
if want perf; then
    # The poller issues the tier-1 chain every cycle. Before the single-pass
    # rewrite this took 0.92 s on the device's single A7 core (13 `cut` forks
    # plus awk); the budget below catches a regression back to fork-per-field.
    start=$(date +%s)
    i=0
    while [ $i -lt 5 ]; do
        ATC="$FAKE" QM_AT_CACHE_DIR="$(mktemp -d)" sh "$SHIM" 'AT+QENG="servingcell";+QCAINFO=1;+QCAINFO;+QCAINFO=0' >/dev/null
        i=$((i+1))
    done
    end=$(date +%s)
    elapsed=$((end-start))
    if [ "$elapsed" -le 5 ]; then
        ok "tier-1 chain stays under budget (${elapsed}s for 5 runs)"
    else
        bad "tier-1 chain stays under budget" "${elapsed}s for 5 runs (budget 5s)"
    fi
fi

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED_NAMES"
exit 1
