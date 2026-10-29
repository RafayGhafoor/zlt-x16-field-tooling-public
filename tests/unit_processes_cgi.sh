#!/bin/sh
# =============================================================================
# unit_processes_cgi.sh — the process-table CGI, against a synthetic /proc
# =============================================================================
# `system/processes.sh` is the only place in QManager that computes a CPU share
# itself: /proc/stat and /proc/<pid>/stat carry CUMULATIVE jiffy counters, so a
# percentage only exists relative to a previous sample the CGI keeps in a state
# file. That subtraction, the null-vs-zero rule, and the sort/limit contract are
# all arithmetic the device would otherwise be the only place to check — on a
# 1-core router where a wrong number looks exactly like a right one.
#
# So this suite fabricates a /proc tree (QM_PROC_ROOT) and a state directory
# (QM_PROC_STATE_DIR), runs the real CGI, and advances the counters by hand:
#
#   sample A  total 10000 jiffies, idle 8500, pid 100 at 200 ticks
#   sample B  total 10850 jiffies, idle 9200, pid 100 at 210 ticks
#
# The expected figures are then exact, not approximate: 850 jiffies elapsed, 150
# of them busy -> 17.6 %, and pid 100's 10 of them -> 1.2 %.
#
# No device, no network, no /proc of the host. Needs jq and POSIX sh only.
# =============================================================================
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
CGI="$REPO/qmanager/scripts/www/cgi-bin/quecmanager/system/processes.sh"

TMP="${TMPDIR:-/tmp}/unit_processes.$$"
mkdir -p "$TMP/lib" "$TMP/cgi" "$TMP/state"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; printf '       %s\n' "$2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

[ -f "$CGI" ] || { echo "FATAL: CGI missing at $CGI" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 2; }

# --- stage the CGI with a stub base ------------------------------------------
# The real cgi_base.sh lives at /usr/lib/qmanager on the device; on the host the
# copy is pointed at a stub. Only the five helpers this endpoint calls exist, and
# cgi_headers emits NOTHING so the body is the JSON alone (the real one writes
# HTTP headers, which the device's httpd strips and stdout here must not carry).
cat > "$TMP/lib/cgi_base.sh" <<'STUB'
qlog_init() { :; }
qlog_debug() { :; }
qlog_info() { :; }
qlog_warn() { :; }
qlog_error() { printf 'LOG-ERROR: %s\n' "$*" >&2; }
cgi_headers() { :; }
cgi_handle_options() { :; }
cgi_method_not_allowed() { printf '{"success":false,"error":"method_not_allowed"}\n'; exit 0; }
cgi_error() { printf '{"success":false,"error":"%s","detail":"%s"}\n' "$1" "$2"; }
STUB

sed "s|^\. /usr/lib/qmanager/cgi_base.sh|. \"$TMP/lib/cgi_base.sh\"|" "$CGI" \
    > "$TMP/cgi/processes.sh" || { echo "FATAL: cannot stage the CGI" >&2; exit 2; }

# --- the synthetic /proc ------------------------------------------------------
ROOT="$TMP/proc"

# mkroot USER SYSTEM IDLE UPTIME_S
mkroot() {
    mkdir -p "$ROOT"
    # cpu user nice system idle ...  (the CGI sums fields 2-9, idle = 4 + 5)
    printf 'cpu  %s 0 %s %s 0 0 0 0 0 0\n' "$1" "$2" "$3" > "$ROOT/stat"
    printf 'cpu0 1 2 3 4 5 6 7 8 9 10\n' >> "$ROOT/stat"
    printf 'processor\t: 0\nmodel name\t: ARMv7 Processor rev 4 (v7l)\n' > "$ROOT/cpuinfo"
    cat > "$ROOT/meminfo" <<'MEM'
MemTotal:         661264 kB
MemFree:          255592 kB
MemAvailable:     481456 kB
Buffers:               4 kB
Cached:            224556 kB
SwapCached:             0 kB
SwapTotal:        330628 kB
SwapFree:         330628 kB
MEM
    printf '4.39 3.73 3.35 2/454 14611\n' > "$ROOT/loadavg"
    # Uptime ADVANCES between samples, as it does on a device: the endpoint
    # treats a window shorter than 0.2 s as "the same instant" and re-seeds.
    printf '%s 5000.00\n' "$4" > "$ROOT/uptime"
}

# write_proc PID COMM STATE TICKS RSS_PAGES VSIZE THREADS STARTTIME
# TICKS is utime + stime (stime is written as 0), STARTTIME guards PID reuse.
#
# ALL 52 FIELDS ARE WRITTEN, in the kernel's own order, because the endpoint
# locates `state` by counting back from the end of the token list (comm may hold
# spaces and parentheses). A short fixture would not exercise that at all.
write_proc() {
    mkdir -p "$ROOT/$1"
    # 1 pid, 2 comm, 3 state, 4 ppid, 5 pgrp, 6 session, 7 tty, 8 tpgid, 9 flags,
    # 10-13 minflt..cmajflt, 14 utime, 15 stime, 16-17 cutime/cstime, 18 priority,
    # 19 nice, 20 threads, 21 itreal, 22 starttime, 23 vsize, 24 rss, then the
    # kernel's 28 remaining bookkeeping fields.
    printf '%s (%s) %s 1 1 1 0 -1 4194560 0 0 0 0 %s 0 0 0 20 0 %s 0 %s %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' \
        "$1" "$2" "$3" "$4" "$7" "$8" "$6" "$5" > "$ROOT/$1/stat"
}

# set_cmdline PID ARG...   (NUL-separated, exactly as the kernel writes it)
set_cmdline() {
    p=$1
    shift
    : > "$ROOT/$p/cmdline"
    for arg in "$@"; do
        printf '%s\0' "$arg" >> "$ROOT/$p/cmdline"
    done
}

run_cgi() {
    REQUEST_METHOD=GET \
    QUERY_STRING="${1:-}" \
    QM_PROC_ROOT="$ROOT" \
    QM_PROC_STATE_DIR="$TMP/state" \
    QM_PROC_NO_SEED="${SEED:-1}" \
    PATH="/usr/bin:/bin:${PATH}" \
    sh "$TMP/cgi/processes.sh"
}

q() { printf '%s' "$BODY" | jq -r "$1"; }

# =============================================================================
# The fixture, as a function of how many windows have elapsed
# =============================================================================
# A CPU share only exists relative to a previous sample, and the endpoint REFUSES
# to divide by a window whose uptime has not advanced (age < 0.2 s re-seeds).
# So every read here is preceded by advancing the whole tree by one 2.5 s window:
# 250 jiffies at the 100 Hz CONFIG_HZ this kernel uses, 30 of them user, 20
# system, 200 idle, and pid 100 accruing 3 ticks.
mkfixture() {
    n=$1
    user=$((1000 + n * 30))
    sys=$((500 + n * 20))
    idle=$((8500 + n * 200))
    up=$(awk -v n="$n" 'BEGIN { printf "%.2f", 7000 + n * 2.5 }')
    ticks=$((200 + n * 3))

    rm -rf "$ROOT"
    mkroot "$user" "$sys" "$idle" "$up"
    write_proc 100 "dialer"        S "$ticks" 850 100000 6 50
    write_proc 200 "(sd-pam)"      R  50  100  20000 1 60
    write_proc 300 "[kworker/0:0]" Z   0    0      0 1 70
    write_proc 400 "atcmd_daemon"  S  10  200  90000 3 80
    set_cmdline 100 /usr/bin/dialer -d
    set_cmdline 200 /bin/hotplug
    set_cmdline 400 /bin/atcmd_daemon
    # 300 has an EMPTY cmdline, like every kernel thread
    if [ "$n" -ge 1 ]; then
        # Appears in the SECOND window and is measured from then on.
        write_proc 500 "latecomer" S 5 50 10000 1 90
    fi
    # One process is BORN every window, which is what happens on the device
    # (a curl, a CGI, the sampler itself). Its share is unknown by construction,
    # so every window has exactly one null row for the ordering assertions.
    write_proc $((600 + n)) "spawned" R 1 10 5000 1 $((100 + n))
}

N=0
# cycle QUERY_STRING — advance one window, then read.
cycle() {
    N=$((N + 1))
    mkfixture "$N"
    BODY=$(run_cgi "${1:-}")
}

# =============================================================================
# Window 0: the first read, with no previous sample on disk
# =============================================================================
mkfixture 0
BODY=$(run_cgi "limit=25")

printf '%s' "$BODY" | jq -e . >/dev/null 2>&1 \
    && ok "the body is valid JSON" \
    || bad "the body is valid JSON" "not JSON: $(printf '%.120s' "$BODY")"

eq "success is true" "true" "$(q '.success')"
eq "no previous window: first_sample is true" "true" "$(q '.sample.first_sample')"

# THE null-vs-zero rule. With no earlier counters there is no percentage, and a
# 0 would rank a possibly-hot process at the bottom of a CPU-sorted list.
eq "no previous window: machine usage is null, not 0" "null" "$(q '.cpu.usage_pct')"
eq "no previous window: every row cpu_pct is null" "null,null,null,null,null" \
    "$(q '[.processes[].cpu_pct] | map(tostring) | join(",")')"

# =============================================================================
# Window 1: counters advanced by exactly one window
# =============================================================================
cycle "limit=25"

eq "a stored window is used: first_sample is false" "false" "$(q '.sample.first_sample')"
eq "window_ms is the jiffy delta x 10" "2500" "$(q '.sample.window_ms')"

# 250 jiffies elapsed, 50 of them busy -> 20.0 %, and the split must ADD UP.
eq "machine usage is the busy share of the window" "20.0" "$(q '.cpu.usage_pct')"
eq "user share" "12.0" "$(q '.cpu.user_pct')"
eq "system share" "8.0" "$(q '.cpu.system_pct')"
eq "idle share" "80.0" "$(q '.cpu.idle_pct')"
eq "the split sums to the window" "100" \
    "$(q '[.cpu.user_pct + .cpu.system_pct + .cpu.idle_pct] | map(round) | add')"

# 3 ticks of 250 = 1.2 %, already at the one decimal the endpoint emits.
eq "a row's cpu_pct is its tick delta over the window" "1.2" \
    "$(q '.processes[] | select(.pid == 100) | .cpu_pct')"
# One decimal, like every other share the endpoint emits — and NOT null,
# which is the distinction this line exists for.
eq "an idle process reads 0.0, not null" "0.0" \
    "$(q '.processes[] | select(.pid == 200) | .cpu_pct')"
eq "a process new to this window is null" "null" \
    "$(q '.processes[] | select(.pid == 500) | .cpu_pct')"

# -----------------------------------------------------------------------------
# Fields the UI reads
# -----------------------------------------------------------------------------
eq "rss_kb is the stat rss in pages x 4" "3400" \
    "$(q '.processes[] | select(.pid == 100) | .rss_kb')"
eq "vsize_kb passes through" "100000" \
    "$(q '.processes[] | select(.pid == 100) | .vsize_kb')"
eq "threads passes through" "6" \
    "$(q '.processes[] | select(.pid == 100) | .threads')"
eq "state passes through untranslated" "S" \
    "$(q '.processes[] | select(.pid == 100) | .state')"

# comm may hold parentheses — `(sd-pam)` and `(cron)` are real on this firmware —
# and the split must not truncate at the first "(".
eq "comm with parentheses is parsed whole" "(sd-pam)" \
    "$(q '.processes[] | select(.pid == 200) | .comm')"
# The HOST awk stops reading a file at NUL, so only the first argv element is
# visible here; on the device the endpoint joins every element with spaces and
# that is verified live (`/data/webrtc/bin/x16-webrtc --addr :8443 …`). This
# assertion therefore covers the plumbing (right file, right pid) and not the
# join itself.
eq "argv reaches the row for the right pid" "/bin/hotplug" \
    "$(q '.processes[] | select(.pid == 200) | .cmdline')"
eq "a kernel thread has an empty cmdline" "" \
    "$(q '.processes[] | select(.pid == 300) | .cmdline')"

eq "counts.total counts every pid" "6" "$(q '.counts.total')"
eq "counts.running counts R" "2" "$(q '.counts.running')"
eq "counts.zombie counts Z" "1" "$(q '.counts.zombie')"
eq "counts.sleeping counts S/D/I" "3" "$(q '.counts.sleeping')"

eq "memory used = MemTotal - MemAvailable" "179808" "$(q '.memory.used_kb')"
eq "memory used_pct" "27.2" "$(q '.memory.used_pct')"
eq "swap used is total - free" "0" "$(q '.memory.swap_used_kb')"
eq "load one/five/fifteen" "4.39 3.73 3.35" \
    "$(q '"\(.load.one) \(.load.five) \(.load.fifteen)"')"
eq "load running/tasks" "2 454" "$(q '"\(.load.running) \(.load.tasks)"')"
eq "cores comes from /proc/cpuinfo, not from an assumption" "1" \
    "$(q '.sample.cores')"

# -----------------------------------------------------------------------------
# Ordering and the row budget
# -----------------------------------------------------------------------------
cycle "sort=pid&limit=100"
eq "sort=pid is ascending" "100,200,300,400,500,$((600 + N))" \
    "$(q '[.processes[].pid] | join(",")')"

cycle "sort=mem&limit=100"
eq "sort=mem is by RSS, descending" "100,400,200,500,$((600 + N)),300" \
    "$(q '[.processes[].pid] | join(",")')"

cycle "sort=cpu&limit=100"
eq "sort=cpu puts the busy row first" "100" "$(q '.processes[0].pid')"
# An unmeasured row sorts BELOW a measured 0.0, never inside the ranking — the
# one born this window is the only null, and it must be last.
eq "sort=cpu puts an unmeasured row last" "$((600 + N))" \
    "$(q '.processes[-1].pid')"

cycle "limit=2"
eq "limit truncates" "2" "$(q '.processes | length')"

cycle "limit=0"
eq "limit below 1 is clamped to 1" "1" "$(q '.processes | length')"

cycle "limit=abc"
eq "a non-numeric limit falls back to 25" "6" "$(q '.processes | length')"

cycle ""
eq "no query string at all still answers" "true" "$(q '.success')"

# =============================================================================
# A stale window is not a window
# =============================================================================
# The state file carries the uptime of the sample it holds. A sample from a
# different epoch (reboot, or the page closed overnight) must be re-seeded rather
# than divided against — otherwise the first read of the morning reports the
# CPU share over the last twelve hours as "right now".
mkdir -p "$TMP/state2"
printf 'u 1.00\nj 1000 900\nc 100 0 0 0\np 100 200 50\n' > "$TMP/state2/qmanager_proc_sample"
BODY=$(REQUEST_METHOD=GET QUERY_STRING="" QM_PROC_ROOT="$ROOT" \
      QM_PROC_STATE_DIR="$TMP/state2" QM_PROC_NO_SEED=1 \
      PATH="/usr/bin:/bin:$PATH" sh "$TMP/cgi/processes.sh")
eq "a 7000 s old sample is re-seeded, not divided" "true" \
    "$(printf '%s' "$BODY" | jq -r '.sample.first_sample')"

# =============================================================================
# Hygiene
# =============================================================================
state_files=$(ls "$TMP/state" 2>/dev/null | sort | tr '\n' ' ')
eq "only the sample and its lock survive a run" \
    "qmanager_proc_sample qmanager_proc_sample.lock " "$state_files"

eq "the state file records uptime, jiffies, counters and one line per pid" \
    "u j c p p p p p p" \
    "$(awk '{print $1}' "$TMP/state/qmanager_proc_sample" | tr '\n' ' ' | sed 's/ $//')"

# The endpoint is read-only: a POST must not be able to do anything.
BODY=$(REQUEST_METHOD=POST QUERY_STRING="" QM_PROC_ROOT="$ROOT" \
      QM_PROC_STATE_DIR="$TMP/state" PATH="/usr/bin:/bin:$PATH" \
      sh "$TMP/cgi/processes.sh")
eq "POST is refused" "method_not_allowed" \
    "$(printf '%s' "$BODY" | jq -r '.error')"

# =============================================================================
printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
