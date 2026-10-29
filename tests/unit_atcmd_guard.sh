#!/bin/sh
# =============================================================================
# tests/unit_atcmd_guard.sh — the guard's decisions, without a device
# =============================================================================
# router-fix/atcmd-guard decides one thing: "is atcmd_daemon's indication stream
# gone, and if so may I act?" (docs/38 §1). Every branch is asserted here against a
# fake /proc, a fake pgrep and a fake start script, so the suite runs anywhere and a
# change to the decision table cannot be merged untested.
#
# The failure it exists for: read_tty_thread reopens /dev/smd3 (a node this firmware
# does not have) on a read error and loops forever without logging, while AT keeps
# answering. The only observable is "the daemon no longer holds /dev/smd9".
#
#   sh tests/unit_atcmd_guard.sh
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUARD="$HERE/../router-fix/atcmd-guard/guard.sh"
[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD" >&2 ; exit 1 ; }

PASS=0 ; FAIL=0 ; FAILED=""
ok()  { PASS=$((PASS+1)) ; printf '  ok   %s\n' "$1" ; }
bad() { FAIL=$((FAIL+1)) ; FAILED="$FAILED
  - $1
    $2" ; printf '  FAIL %s\n       %s\n' "$1" "$2" ; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/atcmd-guard.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --- the fake world ---------------------------------------------------------
#   $TMP/proc       stands in for /proc          (GUARD_PROC)
#   $TMP/dev/smd9   stands in for the indication node (GUARD_SMD9)
#   $TMP/pgrep      prints FAKE_PID              (GUARD_PGREP)
#   $TMP/start      appends to $TMP/started      (GUARD_START)
#   $TMP/daemon.log the vendor's own log         (GUARD_DAEMON_LOG)
#
# Fixture variables (FAKE_PID / FAKE_FDS / FAKE_START) are read by setup(); call it
# as `FAKE_PID=... setup` so it sees them.
setup() {
    rm -rf "$TMP/proc" "$TMP/dev" "$TMP/state" "$TMP/log"
    rm -f "$TMP/started"
    mkdir -p "$TMP/proc" "$TMP/dev" "$TMP/state"
    : > "$TMP/dev/smd9"
    : > "$TMP/daemon.log"
    printf '100.00 200.00\n' > "$TMP/proc/uptime"

    # here-docs, not printf: an escaped \$ inside a printf format is not portable
    cat > "$TMP/pgrep" <<'EOS'
#!/bin/sh
printf '%s\n' "${FAKE_PID:-}"
EOS
    # unquoted delimiter: $TMP must be baked in, because the guard runs this
    # script with its own environment (which has no TMP).
    cat > "$TMP/start" <<EOS
#!/bin/sh
echo started >> "$TMP/started"
EOS
    chmod +x "$TMP/pgrep" "$TMP/start"

    if [ -n "${FAKE_PID:-}" ]; then
        mkdir -p "$TMP/proc/$FAKE_PID/fd"
        # /proc/<pid>/stat: after the comm field, starttime is the 20th token
        printf '%s (atcmd_daemon) S 1 %s 0 -1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 %s 0 0\n' \
            "$FAKE_PID" "$FAKE_PID" "${FAKE_START:-10}" > "$TMP/proc/$FAKE_PID/stat"
        for fd in ${FAKE_FDS:-}; do
            case "$fd" in
                */smd9) ln -s "$TMP/dev/smd9" "$TMP/proc/$FAKE_PID/fd/smd9" ;;
                *)      ln -s "$fd"          "$TMP/proc/$FAKE_PID/fd/$(basename "$fd")" ;;
            esac
        done
    fi
}

run_guard() {
    # The fixtures must reach the fake pgrep/start scripts, which are children.
    export FAKE_PID FAKE_START
    GUARD_PROC="$TMP/proc" GUARD_PGREP="$TMP/pgrep" GUARD_START="$TMP/start" \
    GUARD_STATE="$TMP/state" GUARD_LOGDIR="$TMP/log" GUARD_SMD9="$TMP/dev/smd9" \
    GUARD_DAEMON_LOG="$TMP/daemon.log" GUARD_MIN_AGE=60 GUARD_COOLDOWN=900 GUARD_WAIT=2 \
    sh "$GUARD"
    LOGF="$TMP/log/zlt-atcmd-guard.log"
}

has()      { grep -q "$1" "$TMP/log/zlt-atcmd-guard.log" 2>/dev/null ; }   # log contains
silent()   { [ ! -f "$TMP/log/zlt-atcmd-guard.log" ] ; }                   # no log at all
started()  { [ -f "$TMP/started" ] && wc -l < "$TMP/started" | tr -d ' ' || echo 0 ; }
last()     { tail -1 "$TMP/log/zlt-atcmd-guard.log" 2>/dev/null ; }

echo "== atcmd-guard decisions =="

# --- 1. healthy: holds the node, baseline recorded, silence ----------------
FAKE_PID=4242 FAKE_FDS="/dev/smd8 /dev/smd9" setup
run_guard
if [ -f "$TMP/state/smd9.expected" ] && silent && [ "$(started)" = 0 ]; then
    ok "healthy daemon: baseline marker written, no log line, no restart"
else
    bad "healthy daemon: baseline marker written, no log line, no restart" \
        "marker=$([ -f "$TMP/state/smd9.expected" ] && echo yes || echo no) log=[$(last)] started=$(started)"
fi

# --- 2. VoLTE off: no node at all, no reader was ever lost -> silence ------
FAKE_PID=4242 FAKE_FDS="/dev/smd8" setup
rm -f "$TMP/dev/smd9"
run_guard
if silent && [ "$(started)" = 0 ]; then
    ok "no /dev/smd9 node at all: silent (nothing to lose, VoLTE off)"
else
    bad "no /dev/smd9 node at all: silent (nothing to lose, VoLTE off)" "log=[$(last)]"
fi

# --- 3. first run, node present, no baseline, no evidence -> silence -------
# Ambiguous: this looks identical to "VoLTE was never on for this boot". The guard
# must not guess, because a needless restart costs a second of AT for every client.
FAKE_PID=4242 FAKE_FDS="/dev/smd8" setup
run_guard
if silent && [ "$(started)" = 0 ]; then
    ok "no baseline, no fd, no evidence: silent (does not guess)"
else
    bad "no baseline, no fd, no evidence: silent (does not guess)" "log=[$(last)]"
fi

# --- 4. the bug: baseline exists and the /dev/smd9 fd is gone --------------
: > "$TMP/state/smd9.expected"
run_guard ; sleep 1
if has 'RESTART (reason=urc-thread-lost' && [ "$(started)" = 1 ]; then
    ok "baseline present and the fd is gone: RESTART, and the start script ran"
else
    bad "baseline present and the fd is gone: RESTART, and the start script ran" \
        "log=[$(last)] started=$(started)"
fi

# --- 5. cooldown: a second fault inside COOLDOWN is suppressed ------------
run_guard
if has 'SUPPRESSED' && [ "$(started)" = 1 ]; then
    ok "a second fault inside the cooldown is SUPPRESSED, not restarted"
else
    bad "a second fault inside the cooldown is SUPPRESSED, not restarted" \
        "log=[$(last)] started=$(started)"
fi

# --- 6. the vendor's log line disambiguates a first-boot fault ------------
FAKE_PID=4242 FAKE_FDS="/dev/smd8" setup
printf 'x [atcmd_daemon] (read_tty_thread, 1304): stty read count is invaild(-1), try to reopen pty devices\n' \
    > "$TMP/daemon.log"
run_guard ; sleep 1
if has 'RESTART (reason=urc-thread-lost-log' && [ "$(started)" = 1 ]; then
    ok "no baseline, no fd, but the vendor log proves the loop: RESTART"
else
    bad "no baseline, no fd, but the vendor log proves the loop: RESTART" \
        "log=[$(last)] started=$(started)"
fi

# --- 7. a daemon that just started is not judged --------------------------
FAKE_PID=4242 FAKE_FDS="/dev/smd8" FAKE_START=90 setup   # uptime 100 -> age 10 s
: > "$TMP/state/smd9.expected"
run_guard
if silent && [ "$(started)" = 0 ]; then
    ok "a daemon younger than MIN_AGE is left alone (it may still be opening the node)"
else
    bad "a daemon younger than MIN_AGE is left alone (it may still be opening the node)" \
        "log=[$(last)]"
fi

# --- 8. no daemon at all --------------------------------------------------
FAKE_PID='' setup
run_guard
if has 'RESTART (reason=daemon-absent'; then
    ok "no daemon at all: RESTART (daemon-absent)"
else
    bad "no daemon at all: RESTART (daemon-absent)" "log=[$(last)]"
fi

# ---------------------------------------------------------------------------
# The boot hook. This is where the module actually broke a deploy: the hook was
# inserted ABOVE the `#!` line, and systemd runs StartTZApp directly
# (start_cfgd.service ExecStop=..., TZApp ExecStart=...), so execve() would return
# ENOEXEC and take every other boot hook with it. `sh -n` cannot see that, so the
# rule is asserted here instead.
HOOK="$HERE/../router-fix/atcmd-guard/hook.sh"
if [ -f "$HOOK" ]; then
    echo "== boot hook insertion (shebang first) =="
    H="$TMP/StartTZApp"
    printf '#!/bin/sh\n# vendor line\necho start\n' > "$H"

    HOOK_FILE="$H" sh "$HOOK" install >/dev/null 2>&1
    if [ "$(head -1 "$H")" = '#!/bin/sh' ] && [ "$(grep -c 'zlt-atcmd-guard: start' "$H")" = 1 ]; then
        ok "install keeps the shebang on line 1 and adds exactly one hook line"
    else
        bad "install keeps the shebang on line 1 and adds exactly one hook line" \
            "line1=[$(head -1 "$H")] count=$(grep -c 'zlt-atcmd-guard: start' "$H")"
    fi

    HOOK_FILE="$H" sh "$HOOK" install >/dev/null 2>&1      # idempotent re-run
    if [ "$(grep -c 'zlt-atcmd-guard: start' "$H")" = 1 ]; then
        ok "re-running install does not duplicate the hook"
    else
        bad "re-running install does not duplicate the hook" "count=$(grep -c 'zlt-atcmd-guard: start' "$H")"
    fi

    HOOK_FILE="$H" sh "$HOOK" check >/dev/null 2>&1
    [ $? = 0 ] && ok "check accepts a correctly wired file" \
        || bad "check accepts a correctly wired file" "non-zero"

    # The second way this broke boot: busybox chmod has no --reference, so a
    # write-then-mv rewrote StartTZApp as 644 and systemd's execve() would fail
    # (EACCES) even with the shebang on line 1. install must preserve the mode.
    if [ -x "$H" ] && [ "$(stat -c %a "$H" 2>/dev/null || stat -f %Lp "$H")" = 755 ]; then
        ok "install preserves the executable bit (systemd execve's the file)"
    else
        bad "install preserves the executable bit (systemd execve's the file)" \
            "mode=$(stat -c %a "$H" 2>/dev/null || stat -f %Lp "$H")"
    fi

    # ... and check must refuse the broken mode.
    chmod 644 "$H"
    HOOK_FILE="$H" sh "$HOOK" check >/dev/null 2>&1
    [ $? = 2 ] && ok "check refuses a non-executable StartTZApp" \
        || bad "check refuses a non-executable StartTZApp" "expected rc=2"
    chmod 755 "$H"

    HOOK_FILE="$H" sh "$HOOK" remove >/dev/null 2>&1
    if [ "$(head -1 "$H")" = '#!/bin/sh' ] && [ "$(grep -c 'zlt-atcmd-guard: start' "$H")" = 0 ]; then
        ok "remove deletes the hook and leaves the shebang first"
    else
        bad "remove deletes the hook and leaves the shebang first" \
            "line1=[$(head -1 "$H")] count=$(grep -c 'zlt-atcmd-guard: start' "$H")"
    fi

    # The exact regression: hook above the shebang. install must repair it.
    printf '# zlt-atcmd-guard: start the atcmd_daemon health timer\n%s\n#!/bin/sh\necho start\n' \
        '[ -x /data/zlt-atcmd-guard/guard.sh ] && /bin/systemctl start zlt-atcmd-guard.timer >/dev/null 2>&1' > "$H"
    HOOK_FILE="$H" sh "$HOOK" install >/dev/null 2>&1
    if [ "$(head -1 "$H")" = '#!/bin/sh' ] && [ "$(grep -c 'zlt-atcmd-guard: start' "$H")" = 1 ]; then
        ok "install repairs a file whose shebang was pushed off line 1"
    else
        bad "install repairs a file whose shebang was pushed off line 1" \
            "line1=[$(head -1 "$H")] count=$(grep -c 'zlt-atcmd-guard: start' "$H")"
    fi

    # check must REFUSE that state, which is what makes it a gate.
    printf '# zlt-atcmd-guard: start the atcmd_daemon health timer\n#!/bin/sh\necho start\n' > "$H"
    HOOK_FILE="$H" sh "$HOOK" check >/dev/null 2>&1
    [ $? = 2 ] && ok "check refuses a file whose line 1 is not a shebang" \
        || bad "check refuses a file whose line 1 is not a shebang" "expected rc=2"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED"
exit 1
