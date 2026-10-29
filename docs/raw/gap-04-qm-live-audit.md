# GAP-04 — QManager live audit on http://192.168.3.1:8080

**Date:** 2026-10-26 22:56–23:22 PKT · **Device:** ZLT X16 `sdxlemur`, kernel 5.4.210-perf, armv7l, 1 core
**Method:** all probes ran **on the device over loopback** via `ssh zlt-root` wrapped in a retry helper
(6 attempts, 3 s spacing). Session cookie jar kept in `/tmp/qmjar.txt` only. **No file on the device was
written outside `/tmp`; nothing was modified.** Destructive CGIs were deliberately not called.

```
login:  curl -c /tmp/qmjar.txt -d '{"password":"<redacted-password>"}' \
          http://127.0.0.1:8080/cgi-bin/quecmanager/auth/login.sh   -> 200 {"success":true}
cookies: qm_session (HttpOnly) + qm_logged_in
```

Everything below is measured, not inferred, except where a row is explicitly marked *inferred*.

---

## 0. Frame: what a "200" means here

The UI is a **Next.js static export** (`trailingSlash:true`), served by busybox httpd with docroot
`/data/qmanager/www`. Consequences that shape this whole audit:

* **Every route whose `index.html` exists returns 200 — always, with or without a session cookie.**
  Verified: `/dashboard/` = 200 with no cookie; `auth/check.sh` then says `{"authenticated": false}`.
  Auth is enforced **only** on the CGIs (protected CGIs return **401** `unauthorized` when uncookied).
  So HTTP codes on routes prove *existence*, never *workingness*.
* A route is "working" iff the **CGI it calls** returns real data. A page whose CGI returns
  `success:false` or an empty array still renders its full chrome — that is the silent-gap class this
  audit is looking for.
* Endpoints are referenced in the JS **two ways**: literal (`"/cgi-bin/quecmanager/network/ttl.sh"`) and
  **base + filename** (`let g="/cgi-bin/quecmanager/tower"` then `` `${g}/status.sh` ``). A naive
  "endpoint string not found in the bundle" check produces ~25 false positives; the base-composed
  groups are `bands/`, `frequency/`, `tower/`, `profiles/`, `scenarios/`, `system/health-check/`,
  `system/language-packs/`, `at_cmd/`, and `at_cmd/speedtest_*`.
  Net result: **56 literal + 8 base groups ⇒ all 87 on-disk CGIs are reachable from the UI; zero
  referenced-but-missing endpoints.** There is no frontend/backend version skew on this device.

On-disk route inventory: **44 page routes** (+ `/404`, `/_not-found`, the `login`/`setup` flow).
Sidebar/nav definition lives in `_next/static/chunks/55afa4cbb77647a9.js` and contains **43 entries**.

---

## (a) Route table — HTTP code, populated/empty, note

"Populated" = the CGI behind the page returns real, non-empty data **right now**.
Route sizes are the served `index.html` byte count (chrome only — the pages are client-rendered).

### Entry / auth

| Route | Code | Size | Data | Note |
|---|---|---|---|---|
| `/` | 200 | 12382 | — | shell only, client-side redirect to `/dashboard/` or `/login/` |
| `/login/` | 200 | 13920 | **populated** | `auth/login.sh` → 200 `{"success":true}` |
| `/setup/` | 200 | 13093 | n/a | first-run only; `is_setup_required` is false (`/etc/qmanager/auth.json` present, v1 salt+hash) |

### Cellular

| Route | Code | Size | Data | Note |
|---|---|---|---|---|
| `/cellular/` | 200 | 14853 | n/a | section parent, client-side landing |
| `/cellular/antenna-alignment/` | 200 | 15332 | **populated (partial)** | per-antenna `lte_rsrp[4]` / `nr_sinr[4]` present; `lte_rsrq[]`/`nr_rsrq[]` are **all `null`** |
| `/cellular/antenna-statistics/` | 200 | 15089 | **populated (partial)** | `fetch_signal_history.sh` 5377 B; RSRP+SINR series real, **RSRQ series permanently null** |
| `/cellular/calls/` | 200 | 15308 | **backend up, browser-broken** | page + `x16-webrtc` on :8443/:8444 answer 200 to `curl -k`; a live browser at `192.168.3.176` is failing TLS trust every 2 s — see §c |
| `/cellular/cell-locking/` | 200 | 15322 | **populated** | `frequency/status.sh` + `tower/status.sh` OK, nothing locked |
| `/cellular/cell-locking/tower-locking/` | 200 | 15793 | populated | `tower/status.sh`; `nr_read_ok:false` |
| `/cellular/cell-locking/frequency-locking/` | 200 | 15801 | populated | `frequency/status.sh` |
| `/cellular/cell-scanner/` | 200 | 15567 | **empty (by design)** | `cell_scan_status.sh` → `{"status":"idle"}` until the user starts a scan |
| `/cellular/cell-scanner/neighbourcell-scanner/` | 200 | 16299 | empty (by design) | `neighbour_scan_status.sh` → `idle` |
| `/cellular/cell-scanner/frequency-calculator/` | 200 | 15561 | populated | pure client-side calculator |
| `/cellular/custom-profiles/` | 200 | 15608 | **EMPTY** | `profiles/list.sh` → `{"profiles":[],"active_profile_id":null}` |
| `/cellular/custom-profiles/connection-scenarios/` | 200 | 16261 | **EMPTY + orphan** | `scenarios/list.sh` → `{"scenarios":[],"active_scenario_id":"balanced"}` — see §d/§c |
| `/cellular/detailed-metrics/` | 200 | 15085 | **populated** | `fetch_data.sh` 6177 B, `errors: []` |
| `/cellular/history/` | 200 | 15312 | **populated (partial)** | `fetch_signal_history.sh`; RSRQ columns null |
| `/cellular/settings/` | 200 | 15314 | **populated** | `cellular/settings.sh` → sim_slot 1, cfun 1, `AUTO`, roam 1 |
| `/cellular/settings/apn-management/` | 200 | 15787 | **populated** | `cellular/apn.sh` → 6 profiles, `data_source:"at"` |
| `/cellular/settings/fplmn-settings/` | 200 | 15542 | **BROKEN CGI** | `cellular/fplmn.sh` → `success:false error:"crsm_failed"` |
| `/cellular/settings/imei-settings/` | 200 | 15540 | populated | `cellular/imei.sh` → IMEI `<imei-redacted>` |
| `/cellular/settings/network-priority/` | 200 | 15791 | populated | `LTE:NR5G:WCDMA` |
| `/cellular/sms/` | 200 | 15549 | **populated — contradicts docs/08** | `cellular/sms.sh` → `source:"store"`, real bodies (`"JAZZ 5G"`). The "SMS bodies cannot be read" limitation in `docs/08` is **no longer true** |
| `/cellular/sms/forwarding/` | 200 | 15524 | populated (disabled) | `enabled:false`, 0 failures |

### Local network

| Route | Code | Size | Data | Note |
|---|---|---|---|---|
| `/local-network/` | 200 | 13777 | n/a | section parent, **no inbound link** |
| `/local-network/custom-dns/` | 200 | 15083 | **populated** | `dnsMode:"ABSENT"`, upstream `119.160.122.146`/`119.160.80.146` (carrier) |
| `/local-network/ethernet/` | 200 | 15078 | **populated** | `link_status:"up"`, 1000 Mb/s full duplex |
| `/local-network/ip-passthrough/` | 200 | 15091 | populated (inactive) | `enabled:false, state:"inactive"` |
| `/local-network/smartdns/` | 200 | 15324 | **populated** | `enabled:true, running:true, pid 2318`, 12.9 KB cfg; `smartdns_stats.sh` hit-rate 34.5 % |
| `/local-network/traffic-engine/` | 200 | 15336 | **populated** | `video_optimizer.sh` → running, 888 packets, 21 domains |
| `/local-network/ttl-settings/` | 200 | 15332 | **populated** | `ttl.sh` → enabled, ttl 65; note `autostart:false` |

### Monitoring

| Route | Code | Size | Data | Note |
|---|---|---|---|---|
| `/monitoring/` | 200 | 14995 | n/a | section parent, **no inbound link** |
| `/monitoring/alerts/` | 200 | 15314 | **populated (all channels off)** | sms/email/discord `configured:false`; `alert_after_min:5` |
| `/monitoring/connection-quality/` | 200 | 15092 | **RENDERS 13 EMPTY CARDS** | `monitoring/sites.sh`: `enabled:true`, `interval_sec:300`, **`checked_at:null`, `answered:0/total:13`, every site `latest:null`, `series:[]`** and **no sampler process, no `/tmp/qmanager_sites.json`** — see §c |
| `/monitoring/events/` | 200 | 15559 | **populated (after warm-up)** | `[]` at 22:59, real `band_change`/`pci_change` events from 23:07 — events only appear once things change |
| `/monitoring/latency/` | 200 | 15561 | **populated** | `fetch_ping_history.sh` 1562 B, avg 50–57 ms |
| `/monitoring/tailscale/` | 200 | 15320 | populated (stopped) | `installed:true, version 1.92.5, daemon_running:false, enabled_on_boot:true` |
| `/monitoring/watchdog/` | 200 | 15317 | populated (disabled) | `enabled:false`, thresholds present |
| `/monitoring/discord-bot/` | 200 | 15473 | real page — **orphan** | no nav entry, no inbound link anywhere (§d) |
| `/monitoring/email-alerts/` | 200 | **232** | **redirect stub** | `<meta http-equiv="refresh" content="0; url=/monitoring/alerts/">` — intentional, not broken |
| `/monitoring/sms-alerts/` | 200 | **232** | **redirect stub** | ditto → `/monitoring/alerts/` |

### System settings / misc

| Route | Code | Size | Data | Note |
|---|---|---|---|---|
| `/system-settings/` | 200 | 14867 | n/a | section parent |
| `/system-settings/at-terminal/` | 200 | 15334 | **page up, CGI not probed** | `at_cmd/send_command.sh` is an AT write → *not probed (destructive)* |
| `/system-settings/languages/` | 200 | 15330 | **EMPTY** | `language-packs/list.sh` → `{"installed":[],"manifest":null}` — nothing installable/served |
| `/system-settings/logs/` | 200 | 15075 | **populated** | `system/logs.sh` 16592 B of entries |
| `/system-settings/software-update/` | 200 | 15342 | **page up, CGI not probed** | `system/update.sh` GET is read-only by inspection (line 81) but is on the do-not-touch list → *not probed* |
| `/system-settings/system-health-check/` | 200 | 15350 | **EMPTY (never run)** | `health-check/status.sh` → `status:"none", tests:[], total:0` |
| `/system-settings/web-console/` | 200 | 15659 | populated | AT web console front |
| `/system-settings/connection-quality/` | 200 | 15497 | **duplicate route, orphan** | byte-identical size to `/monitoring/connection-quality/` (15092 vs 15497 — same page, two routes); only the `/monitoring/` one is in the nav |
| `/about-device/` | 200 | 14616 | **populated** | `device/about.sh` → `SIMCOM_SIM8260E` / `V1.0.01`, IMEI, 3GPP block |
| `/support/` | 200 | 14606 | static | donation/dev links — fine |
| `/reboot/` | 200 | 11741 | n/a | `system/reboot.sh` is POST-only → *not probed (destructive)* |

**Route verdicts in one line:** 34 of 44 routes carry live data · 4 are intentionally empty/idle
(cell-scanner ×2, ip-passthrough, watchdog) · **4 are silently empty when they should not be**
(`custom-profiles`, `connection-scenarios`, `languages`, `system-health-check`) · **1 renders 13 empty
cards** (`monitoring/connection-quality`) · **1 has a failing CGI** (`fplmn-settings`) · 2 are redirect
stubs · 2 are orphan duplicates.

---

## (b) CGI table — 87 endpoints, read-only ones probed with a session cookie

`B=http://127.0.0.1:8080/cgi-bin/quecmanager`

### Failing / silently wrong

| Endpoint | Code | Bytes | Response | Verdict |
|---|---|---|---|---|
| `network/dns_test.sh?domain=<x>` | **200** | **0** | *(empty body)*, **25.00 s per call** | **BROKEN.** Server-side it shells `smartdns resolve --https @sky.rethinkdns.com/ example.com`, which stalls; the CGI emits nothing and holds a worker for 25 s on a **1-core** box. 3/3 attempts identical (0 B, 25.0009 s). The DNS-test widget has nothing to render and the router is unresponsive for the duration |
| `cellular/fplmn.sh` | 200 | 99 | `{"success":false,"error":"crsm_failed","detail":"Failed to read FPLMN data from SIM"}` | **BROKEN** — `AT+CRSM` path unsupported on SIM8260E |
| `cellular/mbn.sh` | 200 | 103 | `{"success":false,"error":"read_failed",...}` | **BROKEN** — no MBN/PDC surface on this vendor stack |
| `profiles/current_settings.sh` | 200 | 134 | `apn_profiles:[]`, `imei:""`, `iccid:""`, `mcc:""`, `mnc:""`, `spn:""` | **SILENT GAP** — every field empty while `apn.sh` has 6 profiles and `imei.sh` has the IMEI. Aggregator is not wired on X16 |
| `monitoring/sites.sh` | 200 | 2004 | `checked_at:null, answered:0/total:13`, all `latest:null` | **SILENT GAP** — sampler never runs (no process, no `/tmp/qmanager_sites.json`) |
| `scenarios/list.sh` vs `scenarios/active.sh` | 200 | 58 / 39 | `scenarios:[]` **and** `active_scenario_id:"balanced"` | **INCONSISTENT** — active id points at a scenario that does not exist in the list |
| `system/language-packs/list.sh` | 200 | 68 | `installed:[], manifest:null, manifest_error:null` | empty — no manifest served, so the Languages page can never install anything |
| `system/health-check/status.sh` | 200 | 152 | `status:"none", tests:[], total:0` | empty until a run is triggered (run itself not probed) |
| `at_cmd/fetch_signal_history.sh` | 200 | 5377 | `lte_rsrq:[null,null,null,null]`, `nr_rsrq:[null,…]` | **known limitation** (`docs/08`: SIMCom exposes no per-layer RSRQ) — but the charts still draw an RSRQ axis |
| `tower/status.sh` | 200 | 897 | `nr_read_ok:false`, `lte_read_ok:true` | partial — NR lock state unreadable |
| `vpn/tailscale.sh` | 200 | 144 | `installed:true, daemon_running:false, enabled_on_boot:true` | config says autostart, daemon is down |
| `profiles/get.sh`, `tower/settings.sh` | 200 | 79 / 80 | `no_id` / `method_not_allowed` "Use POST" | correct behaviour, listed so they aren't mistaken for faults |

### Healthy, populated (all **200**)

| Endpoint | Bytes | Key content |
|---|---|---|
| `public/overview.sh` | 509 | `state:"ok"`, `5G-NSA`, carrier `Jazz`, B1 10 MHz, rsrp −88 |
| `public/units.sh` | 78 | `celsius` / `km` |
| `public/hostname.sh` | 29 | `sdxlemur` — **open without a cookie (by design: `credentials:"omit"`)** |
| `auth/check.sh` | 28 | `{"authenticated":true}` / **`false` without cookie** (gate works) |
| `cellular/settings.sh` | 236 | sim 1, cfun 1, `AUTO`, nr5g 0, roam 1 |
| `cellular/apn.sh` | 4704 | 6 profiles, `data_source:"at"` |
| `cellular/imei.sh` | 115 | `<imei-redacted>` |
| `cellular/network_priority.sh` | 51 | `LTE:NR5G:WCDMA` |
| `cellular/sms.sh` | 6003 | `source:"store"` + real bodies (docs/08's SMS limitation is stale) |
| `cellular/sms_forwarding.sh` | 128 | disabled, 0 failures |
| `bands/current.sh` | 241 | LTE `1:3:5:41`, NSA/SA `1:8:40:41:78` |
| `bands/failover_status.sh` | 73 | off |
| `frequency/status.sh` | 209 | nothing locked |
| `device/about.sh` | 557 | `SIMCOM_SIM8260E`, `V1.0.01` |
| `monitoring/alerts.sh` | 2041 | channels unconfigured |
| `monitoring/watchdog.sh` | 459 | disabled |
| `network/custom_dns.sh` | 267 | `dnsMode:"ABSENT"`, carrier upstreams |
| `network/data_used.sh` | 241 | 3.76 GB rx / 4.93 GB tx, `modem_reset_count:18` |
| `network/ethernet.sh` | 195 | up, 1000 Mb/s full |
| `network/ip_passthrough.sh` | 101 | inactive |
| `network/mtu.sh` | 70 | `is_enabled:false, current_value:1400` |
| `network/smartdns.sh` | 12944 | enabled, running, 11.9 KB cfg |
| `network/smartdns_stats.sh` | 2325 | hit rate 34.5 %, 245 insertions |
| `network/ttl.sh` | 90 | enabled, ttl 65, `autostart:false` |
| `network/video_optimizer.sh` | 244 | running, 888 pkts |
| `profiles/list.sh` | 50 | `[]` |
| `profiles/apply_status.sh` | 23 | `idle` |
| `scenarios/active.sh` | 39 | `balanced` |
| `settings/ping_profile.sh` | 270 | `relaxed`, 5 s, cloudflare+google |
| `settings/quality_thresholds.sh` | 277 | `tolerant`, 250 ms / 30 % |
| `system/known_sims.sh` | 36 | 2 SIMs seen |
| `system/logs.sh` | 16592 | full log feed |
| `system/modem-subsys.sh` | 560 | `online`, 0 crashes, uptime 418 s |
| `system/settings.sh` | 680 | hostname, `PKT-5`/`Asia/Karachi`, units |
| `system/sim_registry.sh` | 426 | ICCID `8992300002415281727` (Jazz) |
| `tower/failover_status.sh` | 73 | off |
| `at_cmd/fetch_data.sh` | 6177 | `errors: []`, full LTE+NR block, WAN `10.141.57.64` |
| `at_cmd/fetch_events.sh` | 3→n | `[]` at boot, populated after first band/PCI change |
| `at_cmd/fetch_ping_history.sh` | 1562 | 50–57 ms |
| `at_cmd/cell_scan_status.sh` | 23 | `idle` |
| `at_cmd/neighbour_scan_status.sh` | 23 | `idle` |
| `at_cmd/speedtest_check.sh` | 24 | `available:true` |
| `at_cmd/speedtest_servers.sh` | 1480 | Jazz Faisalabad + PTCL servers resolved |
| `at_cmd/speedtest_status.sh` | 18 | `idle` |
| `system/language-packs/install_status.sh` | 70 | `state:"idle"` |

### Not probed (destructive or state-changing) — 20 endpoints

`auth/logout.sh`, `auth/password.sh`, `auth/ssh_password.sh` (all POST; password change also rewrites
the root SSH password), `at_cmd/send_command.sh`, `at_cmd/cell_scan_start.sh`,
`at_cmd/neighbour_scan_start.sh`, `at_cmd/speedtest_start.sh`, `bands/lock.sh`,
`bands/failover_toggle.sh`, `frequency/lock.sh`, `tower/lock.sh`, `tower/schedule.sh`,
`tower/settings.sh` (POST), `profiles/{save,apply,deactivate,delete}.sh`,
`scenarios/{save,activate,delete}.sh`, `network/data_used_reset.sh`, `system/health-check/{run,clear,download}.sh`,
`system/language-packs/{install,install_cancel,remove}.sh`, `system/reboot.sh`, `system/update.sh`,
`system/settings.sh` (POST).

---

## (c) Broken right now — evidence

**1. `/cellular/calls` cannot be used from a browser (TLS trust).** *[highest impact]*
`x16-webrtc` serves its own self-signed cert on :8443 (signalling/media) and :8444 (QManager HTTPS
front). Server side is healthy — `curl -k https://127.0.0.1:8444/` = **200**, `/cellular/calls/` = 200,
`/cgi-bin/.../public/overview.sh` = 200. But the device log shows a real client failing continuously:

```
x16-webrtc: 2026/10/26 23:18:07 http: TLS handshake error from 192.168.3.176:51041:
            remote error: tls: unknown certificate authority
```
one line **every 2 seconds** (23:17:57 → 23:18:07 shown, ongoing). The Calls page loads and then can
never talk to its own API. `docs/27-call-terminal.md` should state that the cert must be trusted
(or the page must use same-origin `/calls-api/` on :8080).

**2. `zlt-webrtc.service` is `enabled` but `inactive (dead)`, while its process runs un-supervised.**
```
● zlt-webrtc.service - ZLT X16 call terminal
     Loaded: loaded (/etc/systemd/system/zlt-webrtc.service; enabled; preset: disabled)
     Active: inactive (dead)
ps: 2121 root  /data/webrtc/bin/x16-webrtc --addr :8443 --qm-addr :8444 ...   (parent PID 1)
```
The unit launched the binary, the unit's own process exited, and the child was re-parented to PID 1.
Nothing supervises it: **if `x16-webrtc` dies, calls stay dead until reboot.** Every other QManager unit
has a guard; this one does not.

**3. `network/dns_test.sh` hangs for 25 s and returns an empty 200.** See §b. On a 1-core router this is
not just a dead widget — it is a 25 s stall of a CGI worker, and the UI's DNS-test affordance appears
to do nothing at all. Root cause: the CGI resolves through `smartdns --https @sky.rethinkdns.com/`,
which does not answer here (consistent with the boot-time SmartDNS warning below).

**4. `/monitoring/connection-quality` is a 13-card page with zero data.** `monitoring/sites.sh` says
`enabled:true, interval_sec:300` yet `checked_at:null` and `answered:0/13`; there is **no site-checker
process** in `ps`, and **no `/tmp/qmanager_sites.json`** among the poller's outputs
(`/tmp/qmanager_{status,ping,ping_history,signal_history,traffic,dns,dns_stats_history,events,event_state,neighbours_live,pci_state}.json`
exist — sites does not). No unit owns the job. This is the single largest silent gap in the UI.

**5. Two pages open onto a hard CGI error.** `fplmn-settings` shows `crsm_failed`, MBN shows
`read_failed` (§b). Both are "the feature does not exist on SIM8260E" rather than regressions, but the
pages still render as if the data were merely unavailable.

**6. SmartDNS boot check failed once, then recovered.** `/data/log/zlt-smartdns.log`:
```
22:54:02 ok   dnsmasq forwards to the resolver
22:54:06 WARN resolver did not answer debian.org (upstream/WAN?)
22:54:09 FAIL LAN path on 192.168.3.1 does not answer
```
Now healthy: `http://debian.org` from the device = **302 in 0.55 s**; `smartdns_stats.sh` hit-rate 34.5 %.
It is a boot-ordering transient (WAN not up at 22:54), not a live fault — but it needs ~2 min of "WAN
down" before DNS works, and the guard's FAIL line is easy to misread as a permanent failure.

**7. Device load right now is audit-induced, not a device fault.** `load average: 14–16` on 1 core looks
alarming and is **entirely our own `grep -r` sweeps**: `top` shows 4–5 concurrent
`busybox grep -oh … /data/qmanager/www/_next/static/chunks/*.js` from this audit and sibling scouts
(`CPU: 45 % usr, 35 % sys, 0 % idle`, and a sibling's `grep -rls web_page_hide /etc /data` had 3:54 of
CPU). Baseline services are cheap: `dialer` 10 %, `atcmd_daemon` 5 %, `smartdns` transient.
**Do not read this load as a device regression** — but it does show the box has no headroom: any
`grep -r` over the 16.7 MB docroot saturates it, and a 25 s DNS-test stall (§c3) queues behind that.

### Health snapshot (23:22, uptime 23 min, booted 22:53)

| Item | Value |
|---|---|
| Load / memory | `14.10 12.92 8.44` (audit-induced, see §c7) · 643 MB used, **17 MB free**, 437 MB cached, 330 MB swap unused |
| WAN | `rmnet_data0` **UP** `10.141.57.64`, MTU 1400, default route present; 5G-NSA, carrier **Jazz**, APN `connect.mobilinkworld.com`, B1 10 MHz, RSRP −88, SINR −1 (overview reports `sinr:0`) |
| IPA offload | `hw_tx=369930 sw_tx=0 tx_compl=369930 act_clnt=6` — **hardware TX, no software fallback** |
| QManager units | `qmanager-httpd`, `poller`, `ping`, `traffic`, `dpi`, `dpi-ensure`, `dns` = **active**; `qmanager-guard.timer`, `zlt-smartdns.timer`, `dns-edge.timer`, `dns-stats.timer` = **active (waiting)** |
| **`zlt-webrtc`** | **inactive (dead)**, `enabled` — process running detached (§c2) |
| Guard log | 2 lines total, last `poller was not active; restarted (now active)` at **16:00:38** (previous boot) — guard healthy this boot, no restarts |
| Listeners | `:80`, `:443` (vendor), `:8080` (QManager), `:8443`, `:8444` (webrtc) |
| Failed vendor units | `adbd`, `mbim_copybind`, `ninfod`, `pcie-diag`, `QCMAP_Bootup`, `qcmap_dhcp_release`, `qcmap_wlan`, `qps615`, `rdisc` — the documented background noise from `AGENTS.md` §5.5, no new ones |
| Poller freshness | `qmanager_status.json` and `qmanager_ping.json` both written within the last minute |

---

## (d) Routes that exist but are unreachable from the nav

Nav ground truth = `_next/static/chunks/55afa4cbb77647a9.js` (43 entries). Cross-checked against a
literal `"/route"` scan of all 260 JS/HTML files, so "no inbound link" means no href **and** no
`router.push` anywhere in the shipped bundle.

| Route | Code | Size | Why it matters |
|---|---|---|---|
| `/cellular/custom-profiles/connection-scenarios/` | 200 | 16261 | **Real page, completely orphaned.** The sidebar has no `connection-scenarios` entry and nothing links to it. `AGENTS.md` describes exactly this failure mode: the payload is extracted *over* an existing `www/`, so a page can survive a rebuild with no nav entry. `scenarios/list.sh` is empty anyway (§b) — this page would show an empty list *if* you could reach it |
| `/monitoring/discord-bot/` | 200 | 15473 | Real page, orphaned. Its function is now a channel inside `/monitoring/alerts/` (`monitoring/alerts.sh` returns `channels.discord`), so it is a superseded duplicate that should either be linked or removed |
| `/system-settings/connection-quality/` | 200 | 15497 | Duplicate of `/monitoring/connection-quality/` under a second path; only the `/monitoring/` one is in the nav. Two routes, one feature — the `/system-settings/` copy is dead weight |
| `/monitoring/email-alerts/`, `/monitoring/sms-alerts/` | 200 | 232 | **Not gaps**: deliberate `<meta refresh>` redirect stubs to `/monitoring/alerts/`. Recorded here so a future audit does not "fix" them |
| `/local-network/`, `/monitoring/`, `/cellular/`, `/system-settings/` | 200 | 13777–14995 | Section parents with 0 inbound references; harmless (`trailingSlash` landing pages) |
| `/reboot/`, `/login/`, `/setup/` | 200 | — | Reachable, just not via an href (button / auth flow) |

Reverse check — **nav entries with a dead target: none.** All 43 nav routes return 200 and every one
maps to a real `index.html`.

---

## Where the gaps are, ranked (input to the gap-filling plan)

1. **`monitoring/sites.sh` sampler does not exist on X16** → 13 empty cards. Needs a unit (piggyback on
   `qmanager-pinger` or a `qmanager-sites.timer`) plus a `qmanager-guard` entry.
2. **`network/dns_test.sh` blocks 25 s and returns nothing** → dead widget + worse responsiveness.
   Needs a timeout (`timeout 5`) and a JSON error path instead of an empty 200.
3. **`/cellular/calls` unusable in a browser** → serve the API same-origin under :8080 (the docroot
   already proxies `/cgi-bin` on :8444) or ship trust instructions; and **supervise `x16-webrtc`**
   (the unit is dead while the process lives).
4. **`profiles/current_settings.sh` is an empty aggregator** → any "current profile" summary is blank
   while `apn.sh`/`imei.sh` have the data. Cheap fix, high visible payoff.
5. **`custom-profiles` + `connection-scenarios` empty and one of them orphaned** → nav entry missing and
   `scenarios/list.sh` returns `[]` while `active.sh` names `balanced`.
6. **`fplmn-settings` / MBN pages show hard errors** → decide "unsupported on SIM8260E" and render that,
   rather than an error toast.
7. **`system-health-check` never ran** (`status:"none"`) and **`language-packs` has no manifest** → both
   pages can only ever be empty as shipped.
8. **RSRQ nulls in every chart** (`fetch_signal_history.sh`) — documented limitation, but the UI still
   plots the series; hide the axis when the whole series is null.

## Caveats / residual risks

* Route "populated" verdicts are derived from the **CGI that backs the page**, not from executing the
  client JS. A page could still mis-render data it received; that class is invisible to curl and needs a
  headless browser.
* Endpoint↔page mapping was established from the string references in each route's JS chunk
  (`sites.sh` → `/monitoring/connection-quality` via `01dfb96d280d7d23.js`), which is reliable but was
  not exhaustively verified for every page.
* All timings/load numbers were taken **while the audit's own `grep -r` sweeps were running** on a
  1-core box; treat absolute values as pessimistic ceilings, not baselines.
* The `smoke` claim "SMS works" (§a) contradicts `docs/08`; the doc is stale — confirmed twice, 6003 B
  of real messages with bodies from the vendor store.
* No destructive CGI was executed, so every "write path" (lock/apply/reboot/update/save) is **unverified
  by this audit**; their failure modes remain unknown.
