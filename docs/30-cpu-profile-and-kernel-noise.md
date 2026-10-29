# 30 — CPU profile, and triaging the kernel log

Measured 2026-10-26 on the live unit (1 core, ARMv7, `ondemand`, max 1 804 800 kHz).
Companion to [29](29-wan-drops-and-band-switching.md).

**Method.** Per-process CPU is taken from `/proc/<pid>/stat` jiffy deltas
(`utime+stime`) between two snapshots, not from `ps`/`top` snapshots. At `HZ=100`
a 25 s window is 2500 jiffies, so percent-of-one-core = `jiffies × 100 / 2500`.
Totals come from `/proc/stat` deltas (`usr/sys/idle/softirq`). This matters: a
`top -b -n 1` sample includes `top` itself and misses short-lived processes
entirely.

---

## 1. Result: the box is not CPU-bound

Steady state, quiet LAN, no call in progress:

```
usr=24.2%  sys=2.7%  idle=66.2%  softirq=6.9%
```

Top processes over a 25 s window:

| % of core | process | note |
|---|---|---|
| 1.4 | `awk` (pid 545) | the ipacm log filter — see §3 |
| 1.2 | `qmanager_poller` | poller pass |
| 1.1 | `ipacm` | vendor |
| 0.6 | `x16-webrtc` | idle cost only; see §2 |
| 0.6 | `dialer` | vendor |
| 0.2 | `tpws` (DPI proxy) | varies 0.2–5.6 % with traffic |
| 0.1 | `dnsmasq`, `mdlcfgd` | |

**Two things made the box look CPU-starved, and neither was a service.**

### 1a. A stray diagnostic `grep` (the real hog)

```
/bin/grep -oh .{0,700}/monitoring/watchdog".{0,400} .../9962befc165c4382.js
parent: sh -c 'FILES=$(find /data/qmanager/www -type f -name "*.js") ... | head -3'
utime=6299 jiffies
```

A shell pipeline left over from an earlier investigation was grepping **every**
`.js` chunk in `/data/qmanager/www` with a bounded-repetition regex
(`.\{0,700\}…\{0,400\}`). Against a minified multi-MB bundle that pattern
backtracks pathologically. It measured **41.8 % of the core** while running
(63 s of CPU accumulated). Killed.

Lesson for the next investigation: a "search the bundle" one-liner must be
bounded (`-m1`, a single file, or `strings | grep -F`), because the loop keeps
spawning a heavy `grep` per file and nothing reaps it when the terminal goes away.

### 1b. A fork-bomb-shaped profiler (self-inflicted)

An earlier attempt at attributing fork churn sampled `/proc` in a loop and ran
`grep -qx` **per PID per iteration** — ~470 forks × 500 iterations. Under
contention each fork got slower, so it ran far longer than designed and drove
load average to ~14, saturating the box to the point where sshd could not get
scheduled. It burned ~100 k forks (`processes` in `/proc/stat` went 3.9 k → 127 k).

Recovery was over telnet (port 23, no login prompt, drops straight to a root
shell) — `telnetd` stayed responsive when dropbear could not. Everything after
that used `read` shell builtins, no per-PID fork.

Attributing fork churn precisely needs process accounting or `execsnoop`, neither
of which exists here; do not re-invent it with a polling loop.

---

## 2. Where the CPU actually goes under load

**Perceived** CPU peaks come from the call path, and they are legitimate work,
not a leak:

| During a call | % of core |
|---|---|
| `alsa_daemon` | ~15 |
| `x16-webrtc` | ~10 |
| `agm_server` | ~4 |
| **audio path total** | **~29** |

Idle, the same path costs `x16-webrtc` 0.6 % and `alsa_daemon` under 0.5 %, so the
call terminal is not burning CPU when nobody is talking — it is call-driven, as
it should be. `calls.jsonl` confirmed calls were in progress during that sample.

Also measured while profiling: **forks ≈ 39/s (2 398/min)** and **context switches
≈ 2 951/s**. At roughly 3 ms per fork/exec on this SoC that is **~12 % of the
core spent creating short-lived processes**, which is the CPU that per-process
snapshots cannot see. It comes from shell pipelines in the 1-minute guards and
the poller. This is the largest remaining *structural* cost and is not fixed here.

---

## 3. Fixed: the ipacm log was ~14 700 lines/min of pure noise

`ipacm` writes its stdout/stderr through a FIFO filter
(`router-fix/ipacm/ipacm-starter.sh`) before it reaches `/data/log/ipacm.log`.
The filter dropped known-noisy lines but **not** the per-NAT-entry debug, which
carries no `IPACM_Conntrack` marker and therefore fell through to `{ print }`:

```
AddIface(): Nat entry match with ip addr(...)
AddORDeleteNatEntry(): target ip or dst ip(...)
PopulateTCPorUDPEntry(): private ip(...)
Private IP(...): 192.168.3.1
Target IP(...): 192.168.3.176
checking ipv4_address(...): 192.168.3.176
ProcessTCPorUDPMsg(): target ip or
```

About six lines **per NAT entry** — i.e. per connection any LAN client makes.

Measured before: **14 720 lines/min (~772 KiB/min)**, all triggered by one
client's ordinary browsing, written to ubifs on the same volume as `/etc`, with
an `awk` process on a 1-core box.

Measured effect of the extended filter over the same real 3000-line sample:

| filter | lines kept |
|---|---|
| before | 3000 (100 %) |
| after | 198 (6.6 %) |

**93.4 % fewer lines** (~970 lines/min, ~51 KiB/min). The WAN-marker rule is
matched first and still fires, so `ipacm-wan-learned` detection is unaffected —
verified synthetically (a `Received wan ipv4-addr` line still prints and still
touches the marker).

Deployed by replacing `/etc/initscripts/ipacm-starter.sh` **without restarting the
supervisor**: the running `awk` keeps its old program, so the new filter takes
effect at the next supervisor start (reboot or data-call reconnect) with no
downtime now. Restarting it by hand would have cost IPA hardware offload until
the next reconnect (AGENTS.md §8).

---

## 4. Kernel log triage — mostly boot noise

The pasted log spans boot (`t≈82 s`) to `t≈981 s`. Counted against the full
`dmesg` ring (1306 lines, `docs/captures/2026-10-26-cpu-and-kernel/dmesg-full.log`):

| Message | Count | Verdict |
|---|---|---|
| `r8125: eth0: link down/up` | 5 / 6 | **Boot transient, t=259–321 s only.** `operstate=up`, 1000 Mbps, no flap for the following ~1700 s. Driver/autoneg settle during init, not an ongoing fault. |
| `NOHZ: local_softirq_pending 08` | 10 | Boot transient, all at t≈87 s (softirq backlog while everything starts). |
| `TCP: Possible SYN flooding on port 989` | 2 | t≈103 s. 989 is `tpws`, the DPI proxy that LAN 80/443 is `REDIRECT`ed to; a boot burst against it. Currently 239 sockets on 989 (84 TIME_WAIT), consistent with normal browsing through the proxy. |
| `perf: interrupt took too long … lowering max_sample_rate` | 6 | t=155–392 s only. No `perf` process is running now; `perf_event_paranoid=2`. Not recurring. |
| `servloc: … service locator timed out` | 2 | t≈335 s, GNSS/location service. `simcom_gnss` runs regardless; no functional impact observed. |
| `adbd` | 30 | **Not an exposure:** `adbd` is not running and `SYS_ADB_SWITCH=0`, so `start_adb` applies `AT+CUSBCFG=USBADB,0`. Boot chatter only. |

Nothing here is faulting now. The honest summary is that the kernel messages
describe a busy boot on a 1-core SoC, not a defect to patch — with the one
exception of the ipacm log volume in §3, which was real and continuous.

---

---

## 4a. Fork churn attributed, and the crash list cleared

`cutime+cstime` (fields 16/17 of `/proc/<pid>/stat`) attributes **forked
children's** CPU to the parent that spawned them, which is exactly the blind spot
per-process snapshots have. Over 30 s:

| % of core in children | parent |
|---|---|
| 5.9 | `qmanager_poller` |
| 2.3 | `tpws` |
| 1.9 | `qmanager_traffic` |
| 1.2 | `ipacm`, `dialer` |

Fork rate re-measured cleanly (no investigation tooling running): **55/s**, ctx
switches 3 431/s.

### The poller never rests

`qmanager_poller` has `POLL_INTERVAL=2`, but a cycle takes **14 s** against its
own `CYCLE_TIME_BUDGET=10` — 36 budget warnings logged. Because the cycle is
longer than the interval the loop is back-to-back, so it is continuously live.

Per cycle it spawns roughly 130 processes: 21 `jq`, 20 `cut`, 18 `qcmd`, 17
`date`, 17 `tr`, 16 `grep`, 13 `awk`. But the cycle time is **AT-bound, not
fork-bound**: 18 serialised `qcmd` calls at ~0.7 s each is ~12.6 s of the 14 s.
The forks are a consequence of a cycle that never finishes early.

So the honest optimisation for this is *fewer AT round-trips per cycle* (or a
longer cadence), not micro-optimising the text tools. Not attempted here: it
changes the UI's refresh contract and deserves its own verified change.

### Crashes

| Unit | State | Action |
|---|---|---|
| `adbd.service` | **real crash loop** — `start-limit-hit`, 16 restarts. `start_adb` applies `AT+CUSBCFG=USBADB,0` because `SYS_ADB_SWITCH=0`, so `launch_adbd start` can never stay up and systemd retried until the limit | **masked** (`/etc/systemd/system/adbd.service -> /dev/null`), `reset-failed`. Boot caveat: units under `/etc/systemd/system` are not visible early in boot (AGENTS.md §4), and the existing start-limit still bounds the damage on the first boot after. |
| `qmanager-dns-edge.service` | failed, exit 1 → `probe_failed` | **Collateral from the runaway scanner**, not a code bug. With the unit's own PATH the probe reports `dns.google 89 ms` and `apply-edge` returns `{"ok":true,"restarted":true,"listening":true}`. Re-run: `Result=success`. |
| SmartDNS `FAIL LAN path does not answer` (22:54) | transient | DNS verified working (dnsmasq 3756 + smartdns 2318, `www.google.com -> 142.251.155.119`). Also collateral from the same saturation. |

The other failed units (`mbim_copybind`, `ninfod`, `pcie-diag`, `QCMAP_Bootup`,
`qcmap_dhcp_release`, `qcmap_wlan`, `qps615`, `rdisc`) are the vendor noise
AGENTS.md §5.5 documents — deliberately not touched.

---

---

## 4b. The real cost was a 1-second lock quantum in `qcmd`

Decomposing one AT read on the device (5-sample averages, after the fix):

| Layer | Per call |
|---|---|
| `/bin/atcmd` (modem only) | **35 ms** |
| + shell shim `atcli_smd11` (46 KB) | 77 ms |
| + `qcmd` (flock) | 93 ms |

Before the fix the same call through `qcmd` averaged **1552 ms**, and 10
sequential samples were `139, 1549, 1219, 2659, 2489, 1369, 1159, 1150, 1309,
2480` ms — every slow one ~N×1000 ms plus shim time. That is a quantisation
showing through, not work.

Cause: BusyBox `flock` has no `-w`, so `flock_wait()` polled with `sleep 1`. Any
contention — and with the poller cycling continuously there is almost always
contention — rounded up to a **full second**, when an uncontended acquire costs
**7 ms**. Fixed by polling at 100 ms (`sleep 0.1` is supported here; 0.1 s
measured 130 ms wall). Counter is incremented before the sleep so a device
without fractional sleep cannot spin forever.

Result: 1552 ms → **93 ms** uncontended, 645 ms under live contention.

### What this does *not* fix

`poll_cycle` still exceeds its own 10 s budget (measured 11–17 s). At 93 ms per
invocation a 14 s cycle implies **~150 tool/AT invocations per cycle** — the
poller is **call-count bound**, not lock-bound. Fixing that means batching or
polling less, which is a separate change with its own refresh-rate trade-off.

### Rust, assessed honestly

**Corrected 2026-10-27.** An earlier revision of this section said Rust on
`qcmd` would take a cycle from 14 s to 5 s. That was wrong: it assumed ~150 AT
invocations per cycle. Reading the code, the poller issues only **2–3 AT calls
per cycle** — `poll_tier1_at` sends one compound
(`AT+QENG="servingcell";+QCAINFO=1;+QCAINFO;+QCAINFO=0`) and the shim answers
`+QCAINFO=0|1` with `OK` without touching the modem. So porting `qcmd`/the shim
to Rust would save 58 ms × 3 ≈ **0.17 s per cycle**. Not worth doing.

The real prize is different: port the **whole poller** as one long-lived
process, which removes the per-parse tool startups entirely. But the size of
that prize is unproven, because the tool costs could not be measured reliably
here — the same `jq -n 1` measured **101 ms under load and 18 ms when idle**, and
copying `jq` to tmpfs made it *slower* (24 ms). On a box that the poller itself
keeps at load 3–6, micro-benchmarks measure the load, not the tool.

So: do not start a poller port on the strength of these numbers. Re-measure the
tool share with the poller stopped (and the guard disarmed) before committing to
it.

Two frictions worth knowing before starting:

- The existing Rust in the QManager tree (`native/qmanager_atd`,
  `native/qmanager_traffic`, `ping-daemon`) is **aarch64-musl**; the X16 is
  **armv7l**, so nothing there runs as-is and a cross toolchain would be needed.
- `qmanager_atd` owns `/dev/smd11` directly. On the X16 the modem is already
  owned by the vendor's `atcmd_daemon` behind `/bin/atcmd`, so an X16 client
  would be a *smaller* job (talk to `atcmd`, port the shim's translations,
  replace flock with a real mutex) — but the shim is 46 KB of translations, so
  it is a port, not a wrapper.

Conclusion: not justified on the current evidence. The dominant, *verified*
problem is the data-call drops, not the poller.

### Benchmark of the qcmd fix (n=10, 1.5s apart, on device)

| `qcmd AT+CVERSION` | min | median | **max** | mean |
|---|---|---|---|---|
| pre-fix (`sleep 1` poll) | 129 ms | 270 ms | **11,349 ms** | 1,622 ms |
| post-fix (`sleep 0.1` poll) | 130 ms | 229 ms | **1,190 ms** | 496 ms |

The value is in the **tail**: a contended call could block for **11.3 seconds**
(eleven 1 s quanta). That is a UI/CGI-visible stall and is what pushed
`poll_cycle` over budget. Worst case improved **9.5x**, mean 3.3x; median barely
moves because the uncontended path never slept.

**Why the fix cannot do better than this.** `sleep 0.1` costs **120 ms** on this
box — busybox forks a process to sleep. So the poll loop is dominated by the cost
of waiting, not by the wait itself: 100 ms of granularity costs 120 ms to achieve.
The remaining tail needs a *kernel-blocking* lock (no shell poll at all), which is
the one part of the native/Rust work that measures as worthwhile — see
`greenpacket-o5a-qmanager/native/qmanager_x16/MEMO.md`.

Two self-inflicted measurement errors worth remembering, because they are easy to
repeat:

- A 200-iteration `flock -x -n` probe reported the AT lock **95% busy**. It was
  self-contending with its own previous iteration. With 50 ms spacing: **0/50,
  0% busy.** The lock is not contended in normal operation.
- The first "improvement" figure of 1.3x was measured by running old and new
  back-to-back 8 times each — the same self-contention. The n=10 run with 1.5 s
  gaps above is the number to trust.

### A mistake made and caught here

The first deployment of the `qcmd` change applied only the
`/usr/lib/qmanager` → `/data/qmanager/lib` rewrite and missed the
`/usr/bin/<binary>` → `/data/qmanager/bin/<binary>` rule, so `AT_CLI` pointed at
`/usr/bin/atcli_smd11`. Every AT call then failed instantly with
`ERROR: ... not found or executable`, which also *looked* like a 60× speedup
because failures return fast. Caught by checking that real reads still contained
a `servingcell` line (0/10 did) and by diffing `AT_CLI` against the backup.
Corrected by restoring the deployed backup and re-applying only the lock hunk,
so the paths were never re-derived by hand.

## 5. Optimisation plan, in value order

| # | Change | Measured basis | Risk |
|---|---|---|---|
| 1 | **ipacm log filter** — done in this change | 14 720 → ~970 lines/min (−93.4 %) | none; supervisor untouched, applies next start |
| 2 | **Cut fork churn** (39/s, ~12 % of core) — batch the 1-minute guards and the poller so each run is one process instead of N pipelines | measured forks/s + ctx switches/s | low, but rewrites working guards |
| 3 | **Evaluate `tpws`** — it costs 0.2–5.6 % and holds 239 sockets. It is a *feature* (DPI/domain filtering), so this is a product decision, not a bug fix | per-run cost varies with traffic | would remove filtering |
| 4 | **Leave the call path alone** — ~29 % during a call is real work; idle cost is ~0.6 % | measured idle vs in-call | — |
| 5 | **Do not chase the kernel messages** — boot transients | full dmesg counted | — |

Not recommended: any attempt to raise the dialer's throughput or to
`nice`-renice the vendor daemons. The first is the 60 s watchdog in
[29](29-wan-drops-and-band-switching.md); the second buys nothing while idle is
66 %.
