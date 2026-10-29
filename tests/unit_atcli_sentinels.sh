#!/bin/sh
# =============================================================================
# tests/unit_atcli_sentinels.sh — the two replies that are NOT modem text
# =============================================================================
# `atcmd_daemon` answers with two strings that look exactly like a two-line modem
# reply and are not one. Both were found by decompiling the daemon and the client
# (docs/38 §2 and §3); neither is a modem behaviour that a capture would reveal:
#
#   <path>\r\nATCMD_DAEMON_FILE_OK\r\n
#       The answer did not fit its buffer, so ALL of it was written to <path>
#       (safe_read / file_write). Passing this up would turn a long answer into a
#       two-line reply — a neighbour scan would read as "no cells" rather than
#       "the data is in a file". The sentinel carries the path, so the shim parses
#       it instead of assuming the fixed one; the test points the fake at its own
#       path to prove that.
#
#   Atcmd_daemon get At_Response Error
#       The daemon's own failure literal (atcmdd_node_handler). It is not a modem
#       answer: qcmd would call it a success and a parser would find nothing.
#
# Plus one allowlist assertion: AT+CFUN? HANGS on this firmware (AGENTS.md §6,
# docs/42 §3) and, because qcmd holds the global AT lock around the call, the hang
# is paid by every other AT consumer. The shim must refuse it without touching the
# daemon.
#
#   sh tests/unit_atcli_sentinels.sh          # all
#   sh tests/unit_atcli_sentinels.sh spill    # one section
# =============================================================================
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib_atcli.sh"

# first line of an answer, CR-stripped — the shape every assertion below uses
first_line() { printf '%s' "$1" | tr -d '\r' | head -1 ; }

echo "== daemon sentinels (file transfer, failure literal, CFUN?) =="

# ---------------------------------------------------------------------------
if want spill; then
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/atcli-spill.XXXXXX")
    printf '+CCAINFO: "PCC",EUTRAN_BAND3,1312,100,256,-94,-8,-66,200\n+CCAINFO: "SCC",EUTRAN_BAND1,150,50,502,2,-108,-9,-82,134,2,3,9\n' \
        > "$TMP/answer"

    out=$(FAKE_SPILL='AT+CCAINFO?' FAKE_SPILL_PATH="$TMP/answer" run 'AT+CCAINFO?')
    assert_contains "a spilled answer is read back from the sentinel's path" 'EUTRAN_BAND3' "$out"
    assert_contains "…the whole file, not just its first line" 'EUTRAN_BAND1' "$out"
    assert_not_contains "the sentinel never reaches the caller" 'ATCMD_DAEMON_FILE_OK' "$out"

    # The file is gone (or was never written): the honest answer is ERROR, not the
    # sentinel. This is the case that matters — it is what a failed file_write
    # leaves behind, and it must not look like a reply.
    out=$(FAKE_SPILL='AT+CCAINFO?' FAKE_SPILL_PATH="$TMP/absent" run 'AT+CCAINFO?')
    assert_eq "a sentinel pointing at a missing file answers ERROR" 'ERROR' "$(first_line "$out")"

    # A path that is not absolute is not something this shim reads.
    out=$(FAKE_SPILL='AT+CCAINFO?' FAKE_SPILL_PATH='relative/path' run 'AT+CCAINFO?')
    assert_eq "a relative spill path is refused as ERROR" 'ERROR' "$(first_line "$out")"

    rm -rf "$TMP"
fi

# ---------------------------------------------------------------------------
if want daemonerr; then
    out=$(FAKE_DAEMON_ERR='AT+CCAINFO?' run 'AT+CCAINFO?')
    assert_eq "the daemon's failure literal answers ERROR" 'ERROR' "$(first_line "$out")"
    assert_not_contains "…and is never handed to a parser" 'At_Response' "$out"
fi

# ---------------------------------------------------------------------------
if want untouched; then
    # The sentinel handling must be inert for ordinary replies: same bytes, echo
    # still stripped, OK/ERROR still passed through (qcmd parses those itself).
    out=$(run 'AT+CCAINFO?')
    assert_contains "an ordinary reply still passes through" 'EUTRAN_BAND3' "$out"
    assert_not_contains "…with the echo line still stripped" 'atcmd_receive' "$out"
    out=$(FAKE_FAIL='AT+CCAINFO?' run 'AT+CCAINFO?')
    assert_contains "a modem ERROR still passes through as ERROR" 'ERROR' "$out"
fi

# ---------------------------------------------------------------------------
if want cfun; then
    # AT+CFUN? hangs (AGENTS.md §6). Refused means refused BEFORE the client runs:
    # FAKE_CALL_LOG records every invocation, so an empty log is the proof.
    LOG="${TMPDIR:-/tmp}/atcli-cfun.$$.log" ; : > "$LOG"
    out=$(FAKE_CALL_LOG="$LOG" run 'AT+CFUN?')
    assert_eq "AT+CFUN? is refused (it hangs on this firmware)" 'ERROR' "$(first_line "$out")"
    assert_eq "…without ever invoking the AT client" '0' "$(wc -l < "$LOG" | tr -d ' ')"
    rm -f "$LOG"

    # AT+CFUN= is the write form and stays allowed — QManager bounces the modem
    # with it, and only the QUERY is the hang.
    LOG="${TMPDIR:-/tmp}/atcli-cfun2.$$.log" ; : > "$LOG"
    out=$(FAKE_CALL_LOG="$LOG" run 'AT+CFUN=4')
    assert_eq "AT+CFUN=4 (write) is still sent to the daemon" '1' "$(wc -l < "$LOG" | tr -d ' ')"
    rm -f "$LOG"
fi

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED_NAMES"
exit 1
