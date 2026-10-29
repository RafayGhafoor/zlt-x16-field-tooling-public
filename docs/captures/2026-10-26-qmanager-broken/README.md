# Capture — 2026-10-26 — QManager features reported broken

Taken before any change. Device `192.168.3.1` (ZLT X16), up 2 min, all four
QManager units `active`, AT daemon answering.

## 1. Neighbour cell scan — completes with zero rows

```
POST /cgi-bin/quecmanager/at_cmd/neighbour_scan_start.sh   -> {"success": true}
GET  /cgi-bin/quecmanager/at_cmd/neighbour_scan_status.sh  -> {"status":"complete","results":[]}
```

`qmanager_neighbour_scanner` run by hand:

```
$ /data/qmanager/bin/qmanager_neighbour_scanner
$ cat /tmp/qmanager_neighbour_scan_error
Both AT commands failed
```

Root cause visible in `device-state.txt`:

| Path | `AT+QENG="neighbourcell"` result |
|---|---|
| `/bin/atcmd` (native vendor client) | **12 real neighbour rows** (`neighbourcell intra/inter`, LTE) |
| `/data/qmanager/bin/atcli_smd11` (QManager's dialect shim) | `+QENG: "servingcell",...` — **one serving cell** |

The shim's dispatch table (`deploy-x16/atcli_smd11`):

```sh
'AT+QENG="servingcell"'|AT+QENG*)      emit_qeng ;;
```

`AT+QENG*` matches everything, so `="neighbourcell"` is swallowed by the
serving-cell translator. The SIM8260E *does* implement the neighbour query
natively, so the shim is masking a command that works. The scanner then greps
for `neighbourcell intra|inter`, finds only a servingcell line, and parses
zero neighbour rows. A zero-row status is not evidence that the RF scan ran.

## 2. Speedtest — reported unavailable

```
GET /cgi-bin/quecmanager/at_cmd/speedtest_check.sh -> {"available": false}
GET /cgi-bin/quecmanager/at_cmd/speedtest_status.sh -> {"status":"idle"}
```

`command -v speedtest` on the X16 → **not installed**.
The working GreenPacket O5A has `/usrdata/qmanager/bin/speedtest`:

```
Speedtest by Ookla 1.2.0.84 (ea6b6773cf) Linux/arm-linux-musleabihf 5.4.210-perf arm/armv7l
```

Same SoC, same userspace ABI, statically linked musl — it will run on the X16.

## 3. Tower schedule — refuses to arm

```
POST /tower/schedule.sh {"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1,2,3,4,5]}
-> {"success":false,"error":"no_lock_targets",
    "detail":"Configure LTE or NR-SA lock targets before enabling schedule"}
```

`GET /tower/status.sh`:

```json
"modem_state": { "lte_locked": false, "lte_cells": [], "lte_read_ok": false,
                 "nr_locked": false, "nr_cell": null, "nr_read_ok": false }
```

`tower/status.sh` reads lock state with `AT+QNWLOCK="common/4g"`. On this modem:

```
AT+QNWLOCK=?
ERROR
AT+QNWLOCK="common/4g"
ERROR
```

`AT+QNWLOCK` is a Quectel command the SIM8260E does not implement, so the
original read always failed. The X16's own LTE lock path is described below.

## Post-fix verification (same device, 2026-10-26)

### Neighbour scan

The specific `AT+QENG="neighbourcell"` query now passes through the X16
translator unchanged. The synthetic `AT+QENG="servingcell"` path is
unchanged for the poller. The real API returns `status: complete` with LTE
intra/inter cells; the source data and UI units are normalized (e.g. raw
`EARFCN=1312, PCI=256, RSRQ=-95, RSRP=-942, RSSI=-648` becomes
`frequency=1312, pci=256, rsrq=-10, signalStrength=-94, rssi=-64`). NR
measurement remains unavailable; an empty NR response does not invalidate
successful LTE results.

### Speedtest

The GreenPacket's 2,280,128-byte static ARMv7/musl Ookla 1.2.0.84 binary was
installed at `/data/qmanager/bin/speedtest` and included in the X16 installer
payload. Verified on the X16:

```
GET  /at_cmd/speedtest_check.sh   -> {"available":true}
GET  /at_cmd/speedtest_servers.sh -> {"success":true,"servers":[...],"favourite":...}
POST /at_cmd/speedtest_start.sh   -> {"success":true,"pid":...}
GET  /at_cmd/speedtest_status.sh  -> running → complete, result preserved
```

One real Ookla test completed against Ufone's Karachi server. Download:
10,418,730 B/s = **83.35 Mbps**, 151,971,060 bytes; upload: 1,877,493 B/s =
**15.02 Mbps**, 27,620,196 bytes; 38.2 ms ping, 0% packet loss. Total traffic
was 179,591,256 bytes (~171 MiB); the WAN stayed up. The initial CGI run logged
an Ookla config write failure because `/root` is read-only, so the start/server
scripts now use `/data/qmanager/data/speedtest-home` for writable persistent
state. No second large speedtest was run after that HOME-path adjustment.

### Tower lock and schedule

The native `AT+CCELLCFG?` read now maps into QManager's LTE lock-status shape:

```
AT+CCELLCFG? -> +CCELLCFG: 0,0 / OK
QManager -> +QNWLOCK: "common/4g",0 / OK
GET /tower/status.sh -> lte_locked=false, lte_read_ok=true
```

No lock was applied. The schedule API correctly still returns `no_lock_targets`
because `/etc/qmanager/tower_lock.json` has no configured LTE/NR target. Native
LTE lock writes are limited to one target and have a known clear form
(`AT+CCELLCFG=0`), but the active-radio write was not exercised on the customer's
cell. NR-SA writes and modem `save_ctrl` persistence are refused as unverified;
NR-targeted schedules are explicitly rejected on SIMCom.

### Test results

The schedule helper originally returned `unit_absent`: the two static oneshot
service units were never installed by the X16 installer. The installer now
ships them, and `start_qmanager` re-arms any saved schedule after `/etc` is
mounted (the vendor loads systemd units before the writable `/etc` mount).
`qmanager_tower_schedule_arm install 23:58 23:59 1` created both runtime
timers; `systemctl list-timers` showed their future Monday firings; `teardown`
removed both timers/symlinks. This tested the timer pair without configuring
or applying a cellular lock.

`sh tests/run-all.sh` passes **180 host assertions** (101 AT shim + 8 traffic +
14 neighbour + 18 speedtest + 28 tower/schedule + 11 history). The live
`tests/smoke_endpoints.sh` result is stored in `smoke-after-fix.txt`:
**46 ok · 2 documented unsupported · 0 failed**, plus 5 semantic checks.

### History tab

The X16 had no `/usr/bin/ubus`, `qm_phy_available` failed, and
`/data/qmanager/metrics/` stayed empty; GreenPacket had `/usr/bin/ubus`, a
successful `modemd` status read, and a populated daily CSV. The X16 poller
incorrectly used optional `modemd` availability as the gate for archiving the
otherwise-real Tier-1 LTE context. It now archives when cell/signal context is
present while continuing to leave optional CQI/MCS fields null. After deploying
and restarting only `qmanager-poller`, the History API window returned
**7 samples, 1 RSRP point, 2 serving-cell timeline runs**; the durable CSV is
under `/data/qmanager/metrics/`. See [24](../../24-history-archive-on-x16.md)
and the summarized API capture `history-after-fix.json`.
