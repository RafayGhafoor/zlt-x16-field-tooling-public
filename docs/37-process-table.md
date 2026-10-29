# 37 — The Processes page: what is actually eating this box

**Page:** `/system-settings/processes` (System → Processes, beside Logs)
**Endpoint:** `GET /cgi-bin/quecmanager/system/processes.sh?limit=N&sort=cpu|mem|pid`
**Source:** `qmanager/scripts/www/cgi-bin/quecmanager/system/processes.sh`,
`qmanager/{app,components,hooks,types}` — no device payload, no new unit, no boot hook.

---

## Why it exists

The customer's question was *"what is hogging the CPU/memory, live"*. On this
device that question is not idle curiosity. Measured on 2026-11-02:

```
$ uptime          -> load average: 4.39, 3.73, 3.35     (ONE core)
$ free -m         -> 645 MB total, 175 used, 250 free
$ top -b -n1      -> 30.7% usr  46.1% sys  23.0% nic   0.0% idle
```

A single-core box reading 4.4 load is why `docs/30-cpu-profile-and-kernel-noise.md`
exists at all (it is where the two self-inflicted hogs in this firmware were
found and fixed). Before this page the only way to answer "what is hot right
now" was SSH plus `top`, which is exactly the situation a web UI is supposed to
replace.

## Why `/proc` and not `top`

`busybox top` is not usable as a data source here, for two measured reasons:

| Problem | Effect |
|---|---|
| `top -b -n1` computes %CPU on a FIRST pass whose "previous" sample is each process's whole lifetime | a long-lived daemon's number is an average since boot, not what it is doing now |
| An honest `top` sample needs a full second | a 1 s request against a 1-core router, with `top` itself near the top of its own list |

So the endpoint reads `/proc` directly, and **the measurement window is the
interval between requests**: each call writes the jiffy counters it read
(`/tmp/qmanager_proc_sample`), and the next call divides by the difference. The
page polls every 2.5 s, so the CPU column is a 2.5 s share — which is the
question. `window_ms` travels with the payload and the page prints it
("measured over 2.3 s"), so the figure and its window cannot be read apart.

The first request after boot, after `/tmp` is wiped, or after the page sat closed
for more than `MAX_AGE_S` (120 s) has no usable window. It takes **two samples
350 ms apart inside the request** rather than reporting a screen of dashes; the
alternative — dividing against a stale file — would report the average of the
last twelve hours as "right now".

## What the numbers mean, and the two `null`s

| Field | Meaning |
|---|---|
| `cpu_pct` | share of the **whole machine** over the window (the column sums to ≤ 100). `null` — never `0` — when the device has no previous sample for that PID (a process born since the last window, or a reused PID), which the row's start time guards. A `0` there would rank a possibly-hot process at the bottom of a CPU-sorted list. |
| whole `cpu` block | `null` on the very first sample: no earlier counters to subtract, so the page says "measuring…" instead of `0 %` of nothing |
| `rss_kb` | the kernel's `rss` in pages × 4 KB. Verified on the device: `/proc/1/stat` rss = 1175 pages, `/proc/1/status` VmRSS = 4700 kB |
| `vsize_kb` | address space, reported and never sorted on: `x16-webrtc` reserves 563 MB virtual and is resident in 14 MB |
| `state` | the raw `/proc/<pid>/stat` letter, untranslated — the wording belongs to the UI's five locales |

### Two CPU scales, deliberately different

Both are shares of the same one core, and one number cannot serve both:

- **per process** (the bar in each row): warn 25 %, alarm 50 %. A quarter of the
  only core, sustained, is worth knowing; half is a hog by any definition.
- **the machine** (the band): warn 75 %, alarm 90 %, load warn 6 / alarm 10.

The band's first cut warned at 50 % CPU / 1.5 load and **painted red on a healthy
device** — the observed steady state is 45–67 % CPU and 3.3–4.8 load, because the
vendor stack (`qwesd`, `basic_prv`, `alsa_daemon`, `netmgrd`, `thermal-engine`,
`QCMAP`, `ipacm`, the WebRTC bridge) keeps the core busy by design. A status band
that cries wolf on the steady state teaches the user to ignore it, which is the
one failure it cannot recover from. Thresholds now sit **above** the observed
normal, and the numbers are in the tile's caption either way.

## Read-only, on purpose

There is no kill action. The processes that top this list are `dialer`,
`QCMAP_ConnectionManager`, `atcmd_daemon`, `qmanager-poller` and the WebRTC
bridge — every one of them owns a resource the WAN depends on (AGENTS.md §5.4: the
data call is fragile). A "kill" button in a web UI on a one-core box is one
mis-click from a dropped bearer with no obvious way back, so the page reports and
leaves the acting to an SSH session. If that ever changes it needs a per-process
allowlist, not a PID field.

## What it costs

Measured on the device 2026-11-02 (load ≈ 4, 197 processes), warm:

```
real 0.30–0.49 s   user 0.09–0.15 s   sys 0.02–0.05 s
```

≈ **120–170 ms of CPU per request**, i.e. ~5–7 % of the single core at the 2.5 s
cadence — and only while the page is open **and its tab visible**: the hook tears
the interval down on `visibilitychange`, like every other live surface here.

That number is the interesting part of this page, because the obvious
implementations are all far worse. Each of these was measured on the device, not
guessed:

| Implementation | Cost | Why it is wrong |
|---|---|---|
| Walk each stat line backwards with `substr()` looking for the last `)` | **340–770 ms** | O(n²) per line; replaced by one greedy `sub()` pass |
| Sort the rows with an in-awk insertion sort | **160–400 ms** | 195²/4 comparisons in busybox awk; `sort -rn` does it in ~2 ms |
| Sum the 50-field tail to locate `comm` | ~10 ms | the few tokens *before* `state` give the same position |
| Pass `/proc/[0-9]*/stat` as awk's **argv** | request fails outright | busybox awk treats an unopenable argv file as FATAL and exits before printing anything — measured on the first run, which died on a process that vanished between the shell's glob and awk's open. Files are now opened with `getline` (returns −1, loop moves on) from a PID list the shell writes. |
| Find the boundary with `^.*\) ` | correct on the device, wrong on this repo's host awk | busybox awk resolves it to the longest match, the host's awk to the shortest, which put the boundary inside `comm` (`my)proc name` → `my)proc`). A parser that answers differently per awk is not a parser, so the field index is now counted from the end of the token list. |

Four forks in total: two awk passes, one `sort`, one `jq`. `flock` on an fd
serialises the state file so two open tabs cannot measure against a half-written
baseline; a failed lock degrades to "unserialised", never to no response.

## Verification

Host (no device, no network, ~0.3 s):

```sh
sh tests/unit_processes_cgi.sh          # 44 assertions
```

It fabricates a `/proc` tree via `QM_PROC_ROOT` / `QM_PROC_STATE_DIR` and
**advances the counters by hand**, so the arithmetic is exact rather than
approximate: 250 jiffies of window with 30 user + 20 system + 200 idle must read
20.0 % busy and split 12.0 / 8.0 / 80.0, and a process that accrued 3 ticks must
read 1.2 %. It also pins the two `null` rules, the ordering contract (an
unmeasured row sorts *below* a measured 0.0), the clamps, and that the state file
is the only thing left behind.

Device:

```sh
ssh zlt-root 'curl -s -b /tmp/qm.cookies \
  "http://127.0.0.1:8080/cgi-bin/quecmanager/system/processes.sh?limit=8&sort=cpu"'
```

Measured 2026-11-02 (deployed via `deploy-x16/install.sh`, static export
including `/system-settings/processes`):

```
http=200 bytes=2493 time=0.251s
{"sample":{"window_ms":2830,"cores":1,"first_sample":false},
 "cpu":{"usage_pct":45.9,"user_pct":23.0,"system_pct":19.4,"iowait_pct":0.0,
        "irq_pct":3.5,"idle_pct":54.1},
 "load":{"one":3.33,"five":3.79,"fifteen":3.66,"running":2,"tasks":458},
 "counts":{"total":199,...}}
2.8%  14148kB  S  3020  x16-webrtc  /data/webrtc/bin/x16-webrtc
2.5%   3444kB  S  1073  dialer      dialer
1.8%   4008kB  S   544  ipacm       /usr/bin/ipacm
```

The page was then loaded in a browser (1280 px and 390 px) and checked against
the same device: band tiles read 55.9 % / 181 MB / 4.20, the table is ordered by
CPU, the Memory and PID orderings re-query the endpoint, the filter narrows to
the matching rows and reports what those rows account for, and at 390 px the
NAME → CPU → MEMORY columns survive while PID/THREADS/STATE drop out (an earlier
cut let the fixed columns squeeze the name column to zero width, so the page
listed CPU shares with no process names at all).

## Rollback

Nothing was installed outside `/data/qmanager`. To remove the page:

```sh
ssh zlt-root 'rm -rf /data/qmanager/www/system-settings/processes \
                     /data/qmanager/www/cgi-bin/quecmanager/system/processes.sh \
                     /tmp/qmanager_proc_sample /tmp/qmanager_proc_sample.lock'
```

…and drop the `processes` entry from `components/app-sidebar.tsx` plus the
`processes` blocks in `public/locales/*/system-settings.json` in the QManager
tree, or re-run `deploy-x16/install.sh --build` after reverting that commit.

Note that a rebuild does **not** delete a page (AGENTS.md §4): the route keeps
answering until `/data/qmanager` is cleared, which is why the `rm -rf` above is
part of the rollback rather than an afterthought.
