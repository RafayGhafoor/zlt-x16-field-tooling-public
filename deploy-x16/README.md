# deploy-x16 — QManager on the ZLT X16

Runs the QManager web UI on the **ZLT X16 ODU** (Qualcomm SDX65 `sdxlemur`,
SIMCom **SIM8260E**, glibc 2.31, armv7, **1 core**, systemd 244) at
`http://<x16-lan-ip>:8080/`. The vendor UI on `:80`/`:443` is never touched.

Upstream QManager targets a Quectel RM520N-GL. This module is the adaptation
layer — the QManager source tree itself is **not** forked: `parse_at.sh`, the 87
CGIs and the poller run unmodified.

## Install

> **`QM_SRC` defaults to the tree vendored in this repository (`qmanager/`).**
> The QManager source is a git subtree here, with its full history, so one clone
> is enough. `QM_SRC` still overrides it for a checkout kept elsewhere; the old
> default (`/tmp/qm`) is only a last resort, because that scratch path is not a
> git repo, is wiped on reboot, and predates this module's fixes (sms file store,
> apn active-cid, band capability, CCAINFO SINR, staleness, and the `scripts/`
> half of every other fix) — building it deploys old behaviour silently.
> `--build` prints which tree it is using and warns only when that tree is in no
> git work tree at all.

```sh
cd deploy-x16
./install.sh --build      # bun build + stage, using ../qmanager
./install.sh              # push, relocate, enable, wire boot, start, verify
./install.sh --check      # verify only (includes the boot-wiring test)
./install.sh --uninstall  # remove everything, restore the vendor boot file

# refreshing the vendored tree / sending QManager-side work back to it:
git subtree pull --prefix=qmanager qmsrc greenpacket
git subtree push --prefix=qmanager qmsrc greenpacket
```

`ZLT_HOST` (default `zlt-root`) and `ZLT_TRIES` (default 10) are honoured;
every ssh call retries because the link drops roughly one connection in three.

## Contents

| File | Purpose |
|---|---|
| `atcli_smd11` | **The port.** AT transport (`/bin/atcmd`) **and** the Quectel ⇄ SIMCom dialect layer, with an allowlist, per-call timeout and blacklist. |
| `sms_tool` | SMS shim: `status` via `AT+CPMS`, `at` passthrough, `delete`. `recv` answers empty **and that is correct here** — the vendor's `/bin/sms_mgr` drains every received message out of the SIM into `/data/sms/sms_read/`, so the modem really has nothing to read and `AT+CMGR`/`CMGL` answer a bare `ERROR` (not `+CMS ERROR`: there is no final result code). The inbox is served from that file store by `sms.sh`; see [docs/captures/recon-sms.md](../docs/captures/recon-sms.md). |
| `qm_serve.sh` | `start\|stop\|restart\|status` for busybox httpd on 8080 (root, so CGI can reach `atcmd_daemon` and write `/etc/qmanager`). |
| `qm_pathfix_x16.sh` | Rewrites QManager's hardcoded `/usr/lib/qmanager`, `/usrdata`, `/opt/bin`, `/lib/systemd/system` paths into `/data/qmanager` + `/etc/systemd/system`. |
| `qmanager_traffic.sh` | 1 Hz live-traffic sampler from `/proc/net/dev`. Replaces the upstream Rust binary (this device counts the WAN rmnet interface in `/proc`, so no ethtool ioctl is needed). |
| `start_qmanager` | Boot hook: waits for `/data`, then starts each unit independently, plus the Traffic Engine (gated on `tpws`) and the background clock sync. |
| `qmanager-*.service` | Five units: httpd, poller, ping, traffic, **dpi** (Traffic Engine). |
| `qmanager-guard.{service,timer}` | The healer: every minute, restart an enabled-but-stopped unit and log it (see "The healer" below). |
| `qmanager-dpi{,-ensure}.{service,timer}` | Traffic Engine: `tpws` plus the loop that re-asserts its `nat` REDIRECT (QCMAP flushes the nat table on every re-dial). `tpws` drops to `nobody` and opens its hostlist by path, so `/etc/qmanager` must be **711** — it is created 700 and that alone stopped the engine from starting. |
| `video_domains.txt` | The factory hostlist, seeded to `/etc/qmanager/video_domains{,_default}.txt` only when absent, so an operator's edited list is never overwritten. |
| `qmanager-timesync` | Boot-time NTP with retry. The vendor's `start_ntp` touches `/tmp/.time_synced` *before* a single one-shot `ntpd -q` that runs before the data call, with a dead RTC — so the marker meant "we tried" and the clock stayed in 1970. This waits for a WAN address, tries the vendor's configured peers then reachable pools, and writes the marker only on a real sync. |
| `lib/qmi/{bin,lib}` | `qmicli` + the two private `.so`s (staged from `dependencies/qmi/`). The neighbour page's **Live** range is served only by the poller's QMI tick, so their absence is a permanently empty table. Keep the `.so`s separate and dynamically linked — LGPL-2.1, and the firmware's own `libqmi.so.1` is a different ABI. |
| `phy_metrics_x16_devinfo.patch` | Applied to `lib/phy_metrics.sh` at build time: adds the vendor dialer's `/tmp/.devinfo_module_data` as a third PHY source, because Tier 3's gate wants `ubus`/`modemd` (absent here) and its AT half speaks Quectel `AT+QNWCFG` (SIMCom has none). This is what fills Detailed Metrics. |
| `qmi_read_ld_library_path.patch` | Applied to `lib/qmi_read.sh`: exports `LD_LIBRARY_PATH` instead of prefixing it to `qm_timeout`, which `platform.sh` defines as a shell *function* — ash does not export a prefix into a function's children, so `qmicli` could not find `libqmi-glib`. |
| `smartdns/` | **SmartDNS module** — resolver + dnsmasq wiring + guard + the page's history sampler. Own `install.sh`/`--check`/`--uninstall`; see its README and [docs/25](../docs/25-smartdns-enablement.md). |

## Why a boot hook (the trap that cost an outage)

The units are `enabled` with correct symlinks in `multi-user.target.wants/`,
yet after a real reboot on 2026-10-26 **none of them started** —
`InactiveExitTimestamp` was empty, i.e. never attempted.

**`/etc` is a separate ubi volume mounted ~10 s into boot, after systemd has
already loaded its unit files.** Everything under `/etc/systemd/system` —
symlinks included — is invisible for that boot. `systemctl enable` therefore
cannot make a unit start at boot here, and a `daemon-reload` only repairs the
in-memory graph until the next reboot. (Same finding that made
`router-fix/ipacm/` use a boot script instead of a drop-in.)

What works is the vendor boot chain: `/etc/initscripts/StartTZApp`, invoked by
`TZApp.service` (`RemainAfterExit=yes`) after `/etc` is mounted, is what starts
telnet, ssh, `atcmd_daemon`, the dialer and the vendor web server. `install.sh`
hooks QManager in there via `/etc/initscripts/start_qmanager`, backing the vendor
file up to `/etc/initscripts/StartTZApp.pre-qmanager` first.

Verified on a real reboot: the four units came up **43–54 s into a 137 s
uptime**, i.e. from the hook, not by hand. `tests/check_boot_wiring.sh` asserts
exactly that (systemd's monotonic start time vs `/proc/uptime`), and treats
graph membership as INFO because it is expected to be empty after a boot.

Re-verified after the Traffic Engine and clock-sync work (2026-10-26 17:55
reboot, the first full `--build` + `--install` rather than hand-pushed files):
all five units came up **61–62 s into a 234 s uptime**, both timers armed, the
`nat` REDIRECT for the Traffic Engine re-asserted (`nat989=1`), `qmi live:
available` with real neighbour rows, the WAN re-dialled on a new address, and
`install.sh --check` passed **29 assertions**. That reboot is also what proved
the DPI units need the hook: they had been started by hand before it, and only
`start_qmanager` brings them back.

> Practical consequence for any future unit you add here: **do not rely on
> `systemctl enable`**. Add a line to `/etc/initscripts/start_qmanager` (or your
> own `/etc/initscripts/start_*` invoked from `StartTZApp`).

## The healer — a running unit is not a unit that stays running

Booting them is only half the contract. On 2026-10-26 `qmanager-poller` was found
`inactive (dead) … Process: (code=killed, signal=TERM)` two minutes after a reboot
and stayed dead: **`Restart=always` does not undo an explicit `systemctl stop`**, so
nothing brought it back. The damage is silent — the dashboard kept rendering the
last `/tmp/qmanager_status.json` as if it were live, and no test looked until the
boot-wiring check ran hours later.

The only code in the QManager tree that stops the poller is
`qmanager_health_check`'s `_pause_poller_if_running` (it pauses the poller while its
diagnostics contend for the AT daemon, and resumes it from a trap). That path is not
proven to be the actor here — no health-check status file was ever written this boot
— so the fix is deliberately actor-agnostic:

`qmanager-guard.timer` → `start_qmanager ensure`, once a minute: for each unit that
is `enabled`, if it is not `active`, start it and append why+when to
`/data/log/qmanager-guard.log` (journald does not persist here, so that file is the
only durable evidence). A healthy run is four `systemctl is-active` calls and no
output; `systemctl disable <unit>` still means "leave it down".

Verified deterministically: `systemctl stop qmanager-poller` → `start_qmanager
ensure` → poller active, and the log reads
`2026-10-26 07:17:58 ensure: qmanager-poller.service was not active; restarted (now active)`.
A healthy run prints nothing.

## The AT transport, in one paragraph

There is **no AT tty** on this device: the modem is on-die with the CPU and AT is
IPC to `atcmd_daemon`, whose only public client is `/bin/atcmd`. Using it means
inheriting the vendor's serialisation against `/bin/dialer`, which reboots the
router after repeated AT failures. The daemon serves **one request at a time
with no timeout**, so a single command the modem never answers wedges every
other client — that happened during the first endpoint sweep and took the WAN
down. Hence the shim's three guards: allowlist (unverified commands answer
`ERROR` without touching the daemon), `timeout 6` per call, and a boot-scoped
blacklist for anything that ever times out.

## Verification

```sh
cd .. && sh tests/run-all.sh --device
```

- `tests/unit_atcli_smd11.sh` — 101 assertions against a fake `atcmd` built from
  a live capture (field positions, RSRP truncation vs RSRQ hundredths, PCC/SCC
  offsets, WAN-context selection, allowlist/timeout/blacklist, CPSI cache).
- `tests/check_boot_wiring.sh` — 19 assertions that QManager survives a reboot.
- `tests/smoke_endpoints.sh` — all 48 CGI endpoints, with real data.

Expected: `46 ok · 2 known-unsupported · 0 failures`. The two are FPLMN
(`AT+CRSM`) and MBN (`AT+QMBNCFG`) — commands this firmware does not answer.

## Known gaps

SMS bodies (storage counts are accurate), per-antenna ports 1–3 (one composite
value exists; ports 1–3 report `null`), CA SINR per component carrier, tower and
frequency locking, cell scanner, dual-SIM failover, IP passthrough (`ql_qmap`
does not exist here), Traffic Engine/DPI. Full detail in
`docs/09-features.md`.

## Rollback

`./install.sh --uninstall` removes the payload, the units and the boot hook.
The vendor boot file can be restored byte-for-byte from
`/etc/initscripts/StartTZApp.pre-qmanager`, and every file overwritten during
install is copied to `/data/zlt-backups/<YYYYMMDD>/qmanager/` first.
