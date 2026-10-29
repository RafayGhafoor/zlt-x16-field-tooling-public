# 34 — The AT shim's own cost, and the snapshot cache

**Status: deployed and verified on the unit (2026-11-05).** Payload:
`deploy-x16/atcli_smd11`. Tests: `tests/unit_atcli_{dialect,policy}.sh`,
`tests/unit_{shim_sources,neighbour_scan,tower_schedule}.sh`.

This page is about **what the shim costs**, not what it translates. The dialect
work is in `docs/04-simcom-at-mapping.md` and `docs/28-porting-contract.md`; the
transport decision is `docs/05-the-at-problem.md`.

---

## 1. Where the time went

Measured on the box itself (1-core A7, every call serialised on `qcmd`'s
`/tmp/qmanager_at.lock`, 30 calls per figure):

| | before | after |
|---|---|---|
| `AT+CGMM`, no cache | 60–63 ms | 44–51 ms |
| `AT+CGMM`, cache hit | — | 18 ms |
| `AT+CSQ`, no cache | 74–75 ms | 47–59 ms |
| tier-1 chain (`QENG;+QRSRP;+QRSRQ;+QSINR`), no cache | 208–214 ms | 101–114 ms |
| same chain, back-to-back burst | 292–309 ms | 45 ms |

A bare `/bin/atcmd <cmd>` — daemon handoff, write to `smd8`, modem round trip,
reply back through the socket — is **30 ms** on this box. The tier-1 chain makes
three modem calls, so `208/3 = 70 ms` per command meant **~40 ms of the shim's
own overhead per call**, in four pipelines inside `at_raw`:

```sh
_clean=$(printf '%s\n' "$_out" | sed '1{/^atcmd_receive:[[:space:]]*$/d;}')   # 2 forks
case "$(printf '%s' "$_clean" | tr -d ' \t\r\n')" in '')                      # 2 forks
if [ -f "$BLACKLIST" ] && grep -qxF "$1" "$BLACKLIST"                         # 1 fork
```

A fork+exec on this CPU is **18.5 ms** (`sh -c :` × 20 = 370 ms) and the core is
shared with `/bin/dialer`'s 1 Hz AT poll, busybox httpd, `qmanager_poller` and
the WebRTC audio pump. So the pipelines, not the transport, were the target.

The same pattern ran through every synthesiser: `sed -n 's/^<prefix>//p' |
tr -d '\r' | head -1` is three forks per settings read, and `QCAINFO`/`ATI`/
`CSYSSEL=?` each ran several of those per call.

## 2. What changed

**a. Fork-free text helpers.** `at_strip_echo`, `at_is_blank`, `at_unquote`,
`at_rtrim`, `at_line_value`, `at_despace`, `at_to_num` replace the `sed`/`tr`/
`awk`/`grep`/`cut` one-liners with `case` patterns and parameter expansion. Each
carries the pipeline it replaces in its comment. Newlines are matched through
`"$NL"` — a raw backslash-newline inside `${...}` is a *line continuation* and
silently deletes the pattern (found the hard way).

**b. No capture forks.** `at_fetch` sets `_AT_OUT` and prints nothing; `at_raw`
is the thin printing wrapper. Internal callers (`emit_qeng`, `emit_qcainfo`,
`emit_antenna_native`, `emit_cversion`, the band/mode readers, `wan_ipv4`) read
`$_AT_OUT` instead of `_x=$(at_raw ...)`, which removes one subshell each.

**c. A snapshot cache keyed by the native command.** `at_cache_slot` names a
file and a TTL for the read-only commands; `at_fetch` consults it before the
modem. Clock is `/proc/uptime` read with the `read` builtin — `date +%s` was an
18.5 ms fork on *every* call, including hits, which is half of what the cache
saves. A hit costs ~2 ms and no fork at all.

Rules the cache obeys, each with an assertion in `tests/unit_atcli_policy.sh`:

| Rule | Why |
|---|---|
| Only allowlisted commands get a slot | a cache file must never make an unverified command reachable |
| A reply containing `ERROR` is never stored | a transient failure must not outlive its cause (this is the "modem fine, no data" class) |
| Any state-changing write drops the whole cache | a read after a write cannot be served from before it |
| Live TTL (2 s) < the poller's 3 s cadence | a poll cycle never reads the previous cycle's data |
| Identity TTL (60 s): `ATI`, `CGMM`, `CGMR`, `CGSN`, `CIMI`, `CICCID`, `CNUM`, `CSYSSEL=?` | fixed for a boot, and any identity write drops them |
| Slots are exact strings | `AT+CGCONTRDP` and `AT+CGCONTRDP=6`, `AT+CCELLCFG?` and `AT+CCELLCFG=0` must never share one |

Not cached on purpose: `AT+QENG="neighbourcell"` (a scan the caller wants fresh),
`AT+SIMEI=`, and every other write.

Knobs (all defaulted, none required): `QM_AT_CACHE=0` disables, `QM_AT_CACHE_DIR`
(default `/tmp/qmanager_at_cache`), `QM_AT_TTL`, `QM_AT_TTL_STATIC`, and the
pre-existing `QM_CPSI_CACHE` / `QM_CPSI_TTL` which still own the `AT+CPSI?` slot.

## 3. Why this is not a `/dev/smd8` shortcut

`/dev/smd8` **is** the one AT channel, and `atcmd_daemon` already holds it (with
`/dev/smd9`) in a select/read loop whose error path logs `try to reopen smd fd`.
SMD is a single stream with no fan-out, so a second reader steals bytes from the
daemon's in-flight reply → the daemon reopens the fd and drops the request → the
dialer's 1 Hz poll starts failing → `Dialer reboot system cause AT send failed
more than %d times`. There is no spare channel either: `AT\r` written to
`/dev/smd11`, `/dev/smd21`, `/dev/smd22` returns 0 bytes. And it would buy at
most the 30 ms transport leg, which is now the *floor*, not the overhead.

## 4. Verification

* `sh tests/run-all.sh` — all suites pass (was 153 assertions across the two
  shim suites; the cache now has five of its own).
* **A/B against the previously deployed shim, on the live SIM8260E**, 44
  commands (every allowlisted read + every Quectel translation + a compound
  chain): **37 byte-identical, 6 differing only in the live signal readings
  (`+CPSI`, `+CCAINFO`, `+CSINR`, `+CRSSI`, `+QRSRP`, `+QSINR`), 1 differing only
  in the trailing field count the modem itself varies on a `+CCAINFO:` SCC row.**
  No behavioural difference.
* Deployed with a backup at
  `/data/zlt-backups/20261028/qmanager/atcli_smd11.pre-atcache`; `qmanager-poller`
  active, `NRestarts=0`, `/tmp/qmanager_status.json` with `errors: []`.
* Rollback: copy that file back and `systemctl restart qmanager-poller`.

## 5. A trap found while measuring: `atcmd` has a fixed reply socket

`/bin/atcmd` binds **`/tmp/.tmpsock/atcmd`** before it talks to the daemon, so two
clients that overlap can each receive the *other's* payload. Observed directly
while building the A/B harness: `atcli_smd11 AT+CGMR` answered with a
`+CPSI: LTE,...` line because `qmanager_poller` was mid-request.

Every real caller goes through `qcmd`, which holds `/tmp/qmanager_at.lock` around
the call — so **do not call `atcli_smd11` from anything that skips that lock**,
and do not add locking to the shim itself (it would deadlock against `qcmd`).

## 6. The lock, which was the real cost (2026-11-05, second round)

With the shim near its floor, the remaining latency turned out not to be the
shim at all. Measured end-to-end through `qcmd`, the same cache-fresh read:

| `qcmd` variant | `AT+CGMM` p50 / p90 / max | `AT+QENG="servingcell"` p50 / p90 / max |
|---|---|---|
| as shipped (100 ms `flock` poll) | 40 / 920 / 1070 ms | 980 / 2050 / 2980 ms |
| blocking `flock` | 40 / 60 / 140 ms | 1020 / 1040 / 1120 ms |
| no lock at all | 30 / 70 / 130 ms | 40 / 90 / 110 ms |

A blocking acquire fixes the 100 ms quantisation but not the queue: `flock()` has
no fairness, and `qmanager_poller` re-acquires the lock roughly 22 times per
cycle, so a UI call can lose the race repeatedly — 6.2 s was observed. The only
variant that meets a latency budget is the one that does not take the lock.

### What was changed

* **`atcli_smd11 --peek`**: answer from the snapshot only. Exit 0 with a complete
  answer, exit 3 the moment any part is not usable. It never opens `ATCMD`,
  never writes the cache and never writes the blacklist — which is why it needs
  no lock: there is nothing for `/bin/atcmd`'s fixed reply socket to race.
* **`qcmd`** tries `--peek` before touching the lock and falls back to the
  existing locked path otherwise. The discriminator is the exit code *plus* the
  rule "an answer of exactly `ERROR` is refused", so an older shim — which
  treats `--peek` as a command, answers `ERROR` and exits 0 — is never trusted.
  The two files can therefore be deployed in either order.
* **A torn-snapshot guard** in the cache reader: a snapshot is usable only if it
  ends with the modem's final result code. `--peek` reads files the poller may be
  writing, and a truncated `+CPSI` line parses into a plausible wrong reading.
  Verified on the device: complete → rc 0, truncated → rc 3, stale → rc 3.
* **Two live TTLs** (the trap this had to avoid): `QM_AT_TTL` (15 s) for UI reads,
  and `QM_AT_TTL_FORCE` (2 s) for the poller, which `Qmanager-poller.service`
  selects with `QM_AT_REFRESH=1`. One long TTL would have let the **poller hit its
  own previous cycle** and freeze every reading at the first sample. 2 s is under
  the unit's own `QM_AT_MIN_INTERVAL=3`, and still collapses the four CPSI reads
  inside one tier-1.5 pass. The poller also sets `QM_AT_NO_PEEK=1`: it is the lock
  holder, so peeking would only add a process per call.

### Result on the unit (n=30 each, this is the CGI/UI shape)

| command | before p50 / max | after p50 / p90 / max |
|---|---|---|
| `AT+CGMM` | 40 / 1070 ms | **40 / 60 / 110 ms** |
| `AT+CSQ` | 90 / 4450 ms | **40 / 90 / 170 ms** |
| `AT+COPS?` | — | **40 / 80 / 90 ms** |
| `AT+CGDCONT?` | — | **40 / 100 / 180 ms** |
| `AT+QENG="servingcell"` | 980 / 2980 ms | **40 / 80 / 120 ms** |
| `AT+QCAINFO` | — | **40 / 160 / 230 ms** |

The multi-second tail is gone (5180 ms worst case → 230 ms). What is left is the
floor: `qcmd` (~15 ms of shell startup) + the shim (~20 ms), which is why p50 is
40 ms and a 60 ms *ceiling* is not reachable while a fallback (a miss → lock →
`atcmd`) or host load lands in the sample. A hard ceiling needs one of those two
interpreter startups removed — `qcmd` as a static armv7 binary, or the persistent
QMI reader below — not more tuning of this path.

## 7. What this did not fix (next)

**QMI is the answer for contention, not for per-call latency.** Measured on the
unit the same day: `qmicli` is 30–70 ms p50 per query (405 KB binary +
`libqmi-glib` + `libqrtr-glib` through the dynamic loader), i.e. slower than the
shim's 18–20 ms snapshot hit — but it is completely independent of the AT lock
(60 ms p50 / 160 ms max *while AT was saturated*).

It cannot replace the AT path: no writes (band/cell lock, IMEI, `CFUN`), no SMS,
no per-antenna chains (`CRSRP`/`CSINR`), no per-carrier CA rows, and the parsers
index `+CPSI`/`+QENG`/`+QCAINFO` by position, so anything synthesised from QMI is
a new field-mapping risk. It *can* honestly cover registration/RAT/operator,
aggregate signal, band info, operating mode, ICCID/IMEI and the WDS profile —
roughly 8–12 of the poller's 29 `qcmd` call sites. Moving those off AT would
shrink the poller's lock occupancy (and its load on the channel the dialer needs
every second), which is the structural follow-up.

A persistent QMI reader (one process, client id held open, serving poller and
CGIs a snapshot) is the only way to a hard sub-60 ms bound for those reads; at
that point the 30–70 ms is single-digit. That is a small static armv7 binary, not
the `qmanager_atd` port docs/30 rejected.
