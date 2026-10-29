#!/bin/sh
# Host-side tests for the Ookla speedtest deployment and status CGI.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
QM_SRC=${QM_SRC:-/tmp/qm}
CHECK="$QM_SRC/scripts/www/cgi-bin/quecmanager/at_cmd/speedtest_check.sh"
STATUS="$QM_SRC/scripts/www/cgi-bin/quecmanager/at_cmd/speedtest_status.sh"
BIN="$HERE/../deploy-x16/speedtest"
TMP="${TMPDIR:-/tmp}/speedtest-test.$$"
mkdir -p "$TMP/bin" "$TMP/lib"
trap 'if [ -n "${BG_PID:-}" ]; then kill "$BG_PID" 2>/dev/null || :; wait "$BG_PID" 2>/dev/null || :; fi; rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

[ -f "$CHECK" ] || { echo "FATAL: QManager source missing at $CHECK" >&2; exit 2; }
[ -f "$STATUS" ] || { echo "FATAL: QManager source missing at $STATUS" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: speedtest payload missing or not executable" >&2; exit 2; }
# The shipped client is a 32-bit ARMv7 static executable. The host need not be
# ARM; validate the payload header and exact tested size without executing it.
assert_eq "Ookla payload size matches verified ARMv7 build" "2280128" "$(wc -c < "$BIN" | tr -d ' ')"
assert_eq "payload is ELF" "127" "$(od -An -tu1 -N1 "$BIN" | tr -d ' ')"
assert_eq "payload has ARM ELF machine id" "40" "$(od -An -tu1 -j18 -N1 "$BIN" | tr -d ' ')"

# Tiny CGI base shim: only the functions this check/status CGI needs.
cat > "$TMP/bin/flock" <<'FLOCK'
#!/bin/sh
# The CGI's lock behavior is tested separately on-device; here we let the
# deterministic single-process state-machine test take the lock immediately.
exit 0
FLOCK
chmod +x "$TMP/bin/flock"

cat > "$TMP/lib/cgi_base.sh" <<'CGI'
qlog_init() { :; }
qlog_warn() { :; }
qlog_error() { :; }
qlog_info() { :; }
cgi_headers() { :; }
cgi_handle_options() { :; }
pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
CGI

# Availability is a runnable probe, not merely command -v.
cat > "$TMP/bin/speedtest" <<'GOOD'
#!/bin/sh
[ "${1:-}" = --version ] && { echo 'Speedtest by Ookla test fixture'; exit 0; }
exit 0
GOOD
chmod +x "$TMP/bin/speedtest"
body=$(QM_LIB_DIR="$TMP/lib" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" sh "$CHECK")
assert_eq "available true only when version probe runs" "true" "$(printf '%s' "$body" | jq -r '.available')"
body=$(QM_LIB_DIR="$TMP/lib" PATH="/usr/bin:/bin" HOME="$TMP" sh "$CHECK")
assert_eq "missing binary reports unavailable" "false" "$(printf '%s' "$body" | jq -r '.available')"
cat > "$TMP/bin/speedtest" <<'BAD'
#!/bin/sh
exit 127
BAD
chmod +x "$TMP/bin/speedtest"
body=$(QM_LIB_DIR="$TMP/lib" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" sh "$CHECK")
assert_eq "truncated/non-runnable binary reports unavailable" "false" "$(printf '%s' "$body" | jq -r '.available')"

run_status() {
    REQUEST_METHOD=GET PATH="$TMP/bin:/usr/bin:/bin" QM_CGI_BASE="$TMP/lib/cgi_base.sh" \
    QM_SPEEDTEST_PID_FILE="$TMP/pid" \
    QM_SPEEDTEST_OUTPUT_FILE="$TMP/output" \
    QM_SPEEDTEST_RESULT_FILE="$TMP/result" \
    QM_SPEEDTEST_LOCK_FILE="$TMP/lock" \
    sh "$STATUS"
}

# A live process with a valid Ookla NDJSON progress line stays running and
# exposes the UI's phase + original progress object.
sleep 60 & BG_PID=$!
printf '%s\n' "$BG_PID" > "$TMP/pid"
cp "$HERE/fixtures/speedtest_progress.json" "$TMP/progress.pretty"
jq -c . "$TMP/progress.pretty" > "$TMP/output"
body=$(run_status)
assert_eq "live process remains running" "running" "$(printf '%s' "$body" | jq -r '.status')"
assert_eq "download progress phase is surfaced" "download" "$(printf '%s' "$body" | jq -r '.phase')"
assert_eq "real progress NDJSON is preserved" "download" "$(printf '%s' "$body" | jq -r '.progress.type')"

# A dead PID plus a real result line is harvested exactly once as complete.
kill "$BG_PID" 2>/dev/null || :
wait "$BG_PID" 2>/dev/null || :
BG_PID=""
printf '99999999\n' > "$TMP/pid"
jq -c . "$HERE/fixtures/speedtest_result.json" > "$TMP/output"
body=$(run_status)
assert_eq "finished result transitions to complete" "complete" "$(printf '%s' "$body" | jq -r '.status')"
assert_eq "result reports actual download bandwidth" "10418730" "$(printf '%s' "$body" | jq -r '.result.download.bandwidth')"
if [ -s "$TMP/result" ]; then actual=true; else actual=false; fi
assert_eq "harvest persists a cached result" "true" "$actual"
if [ ! -e "$TMP/pid" ] && [ ! -e "$TMP/output" ]; then actual=true; else actual=false; fi
assert_eq "harvest removes stale pid and progress output" "true" "$actual"

# A stale PID with missing/malformed progress must never look like success.
printf '99999999\n' > "$TMP/pid"
printf 'Ookla banner only; not JSON\n' > "$TMP/output"
body=$(run_status)
assert_eq "malformed final output is an error, never complete" "error" "$(printf '%s' "$body" | jq -r '.status')"
assert_eq "failure is explicit" "speedtest_failed" "$(printf '%s' "$body" | jq -r '.error')"

# A corrupt cached JSON file is discarded instead of embedded as a result.
rm -f "$TMP/pid" "$TMP/output"
printf 'not-json\n' > "$TMP/result"
body=$(run_status)
assert_eq "corrupt cache falls back to idle" "idle" "$(printf '%s' "$body" | jq -r '.status')"
if [ -e "$TMP/result" ]; then actual=true; else actual=false; fi
assert_eq "corrupt cache is deleted" "false" "$actual"

# A stale PID with no output is not interpreted as an idle/successful test.
printf '99999999\n' > "$TMP/pid"
body=$(run_status)
assert_eq "stale PID and empty output report failure" "error" "$(printf '%s' "$body" | jq -r '.status')"

echo "unit_speedtest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
