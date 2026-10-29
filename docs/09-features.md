# 09 — Feature audit & test suite

Every QManager CGI on the X16, its verdict, and the tests that keep it honest.

```
sh tests/run-all.sh            # unit tests, no device needed
sh tests/run-all.sh --device   # + endpoint smoke test over SSH
```

| Suite | What it proves | Assertions |
|---|---|---|
| `tests/unit_atcli_smd11.sh` | transport, dialect, scaling, safety, compound ordering, performance | **101** |
| `tests/unit_traffic_sampler.sh` | 1 Hz traffic maths, counter-reset, upload/download orientation | **8** |
| `tests/unit_neighbour_scan.sh` | native QENG passthrough, real LTE rows, field scaling, LTE-only completion | **14** |
| `tests/unit_speedtest.sh` | ARMv7 binary, availability probe, real Ookla NDJSON/result state machine, failure handling | **18** |
| `tests/unit_tower_schedule.sh` | LTE lock translation, unsupported NR refusal, schedule validation, timer arm/teardown, boot re-arm wiring | **28** |
| `tests/unit_history_archive.sh` | Tier-1-only archive eligibility, durable row writer, History CGI response | **11** |
| `tests/smoke_endpoints.sh` | all CGIs + semantic checks against false/empty “healthy” responses | **48 endpoints + 5 semantic checks** |

All unit tests run on the host with captured modem/speedtest fixtures and no
network/device changes. The endpoint smoke result is recorded at
`docs/captures/2026-10-26-qmanager-broken/smoke-after-fix.txt`.

## Endpoint results (2026-10-26, post-fix)

`46 ok · 2 known-unsupported · 0 failures`

Every read endpoint below returned HTTP 200 with parseable JSON and the
expected payload key. The smoke suite also checks semantic values such as
`speedtest_check.available == true` and nonempty signal/ping history. Mutating
paths need POST; only the schedule guard and safe, read-only lock path were
checked live.

### Working with real data

| Area | Endpoints | Notes |
|---|---|---|
| Dashboard | `public/overview.sh`, `at_cmd/fetch_data.sh` | carrier, RAT, band, RSRP/RSRQ/SINR, CA, temperature. Reports **5G-NSA** correctly since 2026-10-26: the shim was dropping the modem's second `+CPSI` record (`+CPSI: NR5G_NSA,...`), so `parse_at.sh`'s EN-DC branch never fired and the tile said 4G on an n41 connection. |
| Detailed Metrics | `at_cmd/fetch_signal_history.sh` → `qmanager_status.json .phy` | CQI, RI, MCS for both the LTE anchor and the NR leg, plus `registered`, sourced from the vendor dialer's `/tmp/.devinfo_module_data` dump — the same numbers the stock `sysInfo` page renders. Tier 3 had been gated on `ubus`/`modemd` (absent here) and on `AT+QNWCFG` (Quectel; SIMCom has none), so every figure was a dash. See `captures/recon-detail-metrics.md`. |
| History | `fetch_signal_history.sh`, `fetch_ping_history.sh`, `fetch_events.sh` | X16 now archives real Tier-1 LTE cell context without optional ubus/modemd; see [24](24-history-archive-on-x16.md) |
| Device | `device/about.sh`, `system/modem-subsys.sh`, `system/logs.sh`, `system/health-check/status.sh` | model `SIMCOM_SIM8260E`, fw `V1.0.01`, temp |
| Cellular | `settings.sh`, `apn.sh`, `sms.sh`, `imei.sh`, `network_priority.sh` | APN list, storage 17/23, mode `AUTO`, IMEI |
| Bands | `bands/current.sh`, `bands/failover_status.sh`, `frequency/status.sh` | `1:3:5:8` live |
| Network | `ttl.sh`, `mtu.sh`, `ethernet.sh`, `ip_passthrough.sh`, `smartdns*.sh`, `custom_dns.sh`, `data_used.sh`, `video_optimizer.sh` | |
| Tower | `tower/status.sh`, `tower/failover_status.sh`, `tower/schedule.sh` | read-only status + schedule; one-cell LTE lock adapter, no NR-SA/persistence; see [23](23-cell-locking-on-sim8260e.md) |
| Monitoring | `alerts.sh`, `sites.sh`, `watchdog.sh` | |
| Profiles / scenarios | `list.sh`, `current_settings.sh`, `active.sh` | |
| Settings | `ping_profile.sh`, `quality_thresholds.sh`, `system/settings.sh` | |
| Scanners / speedtest | `cell_scan_status.sh`, `neighbour_scan_*.sh`, `speedtest_*.sh` | native LTE neighbours + Ookla availability, servers, progress and final results; one live run completed at 83.35/15.02 Mbps, 0% loss |

### Known-unsupported (answer with an explicit error, never fake data)

| Endpoint | Why |
|---|---|
| `cellular/fplmn.sh` | needs `AT+CRSM` for SIM file access; this firmware never answers it (and one unanswered command wedges the whole AT daemon — see below) |
| `cellular/mbn.sh` | needs `AT+QMBNCFG`; absent. Real MBN selection on this module is a PDC/QMI operation, not AT |

## Live daemons

| Daemon | State file | Verified |
|---|---|---|
| `qmanager-poller` | `/tmp/qmanager_status.json` | `errors: []`, LTE B3, 3-carrier CA |
| `qmanager-ping` | `/tmp/qmanager_ping.json` | `reachable: true`, RTT 34 ms |
| `qmanager-traffic` (shell) | `/tmp/qmanager_traffic.json` → `www/live-traffic.json` | `{"rx_bps":5064,"tx_bps":4192,...}` served over HTTP |

`qmanager-traffic` is a **shell** sampler on this device, not the upstream Rust
binary: the X16's `/proc/net/dev` counts both the LAN bridge and the WAN rmnet
interface (the Rust version exists because the GreenPacket's IPA path did not).
Removing the cross-compile removed a musl/glibc hazard at the same time.

## The incident that shaped the design (2026-10-26)

During the first full endpoint sweep the **WAN went down** and did not come back
on its own.

Root cause: `atcmd_daemon` serves **one request at a time with no timeout**. A
single command the modem never answers leaves its client queued forever, and
every later client — including `/bin/dialer`'s own — blocks behind it. A dozen
`/bin/atcmd` clients were found queued; killing them and restarting the daemon
(`killall -9 atcmd_daemon; /etc/initscripts/start_atcmd_daemon start`) restored
AT immediately and the dialer re-dialled within a minute.

Three permanent fixes, all unit-tested:

1. **Allowlist, not passthrough.** `atcli_smd11` only sends commands verified on
   this unit. Anything else answers `ERROR` without touching the daemon. This
   alone would have prevented the outage.
2. **Bounded calls.** Every modem call runs under `timeout 6`.
3. **Blacklist.** A command that ever times out is recorded in
   `/tmp/qmanager_at_blacklist` and never retried that boot — the test
   (`FAKE_HANG`) reproduces the outage and asserts the command is refused on the
   second call.

## Boot persistence: `enabled` was not enough

On 2026-10-26 the box rebooted and **all four QManager units stayed down** while
`systemctl is-enabled` reported every one of them as `enabled`.

```
$ uptime → up 1 min
$ systemctl is-active  qmanager-httpd qmanager-poller qmanager-ping qmanager-traffic
inactive inactive inactive inactive
$ systemctl is-enabled ...
enabled enabled enabled enabled
$ systemctl show qmanager-httpd -p InactiveExitTimestamp
InactiveExitTimestamp=        # never even attempted
```

**Actual cause: `/etc` is a separate ubi volume mounted ~10 s into boot, after
systemd has already loaded its unit files.** Everything under
`/etc/systemd/system` — enable symlinks included — is invisible for that boot.
`systemctl enable` therefore cannot start a unit at boot on this device, and a
`daemon-reload` only repairs the in-memory graph until the next reboot (which is
why the graph looked correct when tested by hand and empty after a boot). Same
finding that made `router-fix/ipacm/` use a boot script rather than a drop-in.

What works is the vendor boot chain: `/etc/initscripts/StartTZApp`, called by
`TZApp.service` (`RemainAfterExit=yes`) *after* `/etc` is mounted. It is what
starts telnet, ssh, `atcmd_daemon`, the dialer and the vendor web server.
QManager now hooks in there too:

   ```sh
   # /etc/initscripts/StartTZApp, right after start_dialer
   /etc/initscripts/start_qmanager start &
   ```

   `/etc/initscripts/start_qmanager` waits up to 60 s for `/data` to be mounted,
   then starts each unit independently so one failure cannot take the rest down.
   A backup was kept at `/etc/initscripts/StartTZApp.pre-qmanager`.

`tests/check_boot_wiring.sh` (18 assertions) asserts the hook, not the
enablement graph: "StartTZApp invokes the hook", "the hook is executable",
"each unit's `ActiveEnterTimestampMonotonic` is within the current uptime" (i.e.
it was started **by this boot**, not by hand), and "the UI answers". Graph
membership is reported as INFO because it is expected to be empty after a boot.

**Proven on four consecutive reboots** (2026-10-26 04:57–05:14, the box was
rebooted repeatedly while the parallel ipacm work validated its own boot
ordering): every time, all four units came up 43–54 s into boot without any
manual action.

Manual recovery if it ever happens again:

```sh
systemctl daemon-reload
/etc/initscripts/start_qmanager start
```

## Speed

| Path | Before | After |
|---|---|---|
| `+QENG` translation | 0.35 s (13 `cut` forks + awk) | **0.03 s** (one split, shell arithmetic) |
| Tier-1 chain (`QENG;QCAINFO×3`) | 0.92 s | **0.05 s** |
| `+CPSI` calls per poller pass | 4 | **1** (1 s cache) |

The remaining latency users see is **not** the device: a 1.1 MB asset transfers
at 6.4 MB/s once a connection survives, but roughly one connection in three dies
after ~7.8 s on the load-balancing uplink in front of the X16. Fewer requests per
page load is the only lever that helps, and that is a frontend concern.

## Known gaps (deliberate, documented)

| Gap | Reason |
|---|---|
| SMS bodies | **Fixed 2026-10-26 — no longer a gap.** The modem path really is dead: `AT+CMGR`/`AT+CMGL` answer a bare `ERROR` (not `+CMS ERROR`; there is no final result code at all), and `AT+CPMS?` reports 0 used because the vendor's `/bin/sms_mgr` drains every received message out of the SIM. But it writes them to `/data/sms/sms_read/<slot>`, one plain-text file each, and `sms.sh` now reads that store: 17 messages with bodies in 0.12–0.37 s, where the modem path took 6–15 s and returned nothing. See `captures/recon-sms.md`. |
| Per-antenna RSRQ | `AT+CRSRP?` and `AT+CSINR?` give four chains per RAT, but `AT+CRSRQ?`/`AT+CSRQ?` answer `ERROR`: RSRQ has no per-chain source, so all four ports are null rather than one aggregate mislabelled "Main". RSRP/SINR/RSSI are per-chain. See [26](26-antenna-stats-on-x16.md). |
| CA SINR | `+CCAINFO` does not report SINR per component carrier; the PCC value comes from `+CPSI`. |
| NR-SA cell locking and modem persistence | `AT+C5GCELLCFG` write/state and `QNWLOCK save_ctrl` are unverified/unsupported; only the native LTE `AT+CCELLCFG` path is mapped, limited to one EARFCN+PCI. The LTE lock write has not been applied on the live device. |
| Full-band cell scanner | The upstream `AT+QSCAN` is Quectel-only. The separate LTE neighbour scan is supported via native `AT+QENG="neighbourcell"`, and the **Live** range now works over QMI (`libqmi` `qmicli` is shipped in `lib/qmi/`; the poller's live tick publishes 1 Hz LTE neighbours). NR neighbour data remains unavailable on both paths. See `captures/recon-cell-scanner.md`. |
| Dual-SIM failover | No `AT+QUIMSLOT` equivalent; single slot reported. |
| IP passthrough | Upstream drives `ql_qmap`, a Quectel vendor binary that does not exist here. |
| Traffic Engine (DPI) | **Fixed 2026-10-26.** `tpws` v72.13 *is* deployed; the reason the Video Optimizer toggle never turned on was that `qmanager-dpi.service` and `qmanager-dpi-ensure.*` were never installed, so the CGI's `systemctl restart qmanager-dpi` answered "No files found" and it reported `engine_start_failed` after persisting `enabled=1`. The units, the hostlist seed and `chmod 711 /etc/qmanager` (tpws drops to `nobody` and must traverse to its hostlist) now ship in `deploy-x16/`. Verified: `status: running`, `domains_loaded: 21`, `packets_processed` incrementing. |
