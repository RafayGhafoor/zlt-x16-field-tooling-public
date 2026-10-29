# 30 — Gap-fill plan: what the vendor UI at `:80` has that QManager at `:8080` does not

**Question this answers:** `192.168.3.1:80` is the original vendor interface. What
interesting things does it do that our QManager (`:8080`) is missing, what else can
this ODU usefully do, and in what order should we build it.

**Method.** Five parallel read-only scouts, evidence in `docs/raw/`:

| Scout | Deliverable | What it established |
|---|---|---|
| 1 | [raw/gap-01-vendor-ui.md](raw/gap-01-vendor-ui.md) | Every vendor page (13 sections, 162 rows), the one `http.cgi` request contract (189 cmd ids), and **real vs dead-on-this-ODU** per feature |
| 2 | [raw/gap-02-backend-capability.md](raw/gap-02-backend-capability.md) | Which binaries/kernel features exist, the cost model, **12 installed-and-idle subsystems** |
| 3 | [raw/gap-03-qm-source-contract.md](raw/gap-03-qm-source-contract.md) | The exact 15-file checklist to add a page+backend, and what QManager **already has but never deployed** |
| 4 | [raw/gap-04-qm-live-audit.md](raw/gap-04-qm-live-audit.md) | Live audit of all 44 routes / 87 CGIs — what is actually broken right now |
| 5 | [raw/gap-05-hardware-ceiling.md](raw/gap-05-hardware-ceiling.md) | The hardware ceiling, measured CPU budget, and 12 ideas the ODU cannot do today |

Nothing on the device was modified. Note: `/tmp/qm` (the default `QM_SRC`) is **not a
git checkout** — Scout 3's finding — so every QManager-side path below must be
re-checked against the real tree before a build.

---

## 1. The two interfaces, side by side

**Vendor `:80`** — one CGI (`/cgi-bin/http.cgi`), JSON envelope, 189 command ids, three
account levels, all state in a `tzcfg` key/value store readable as `mdlcfg -g <KEY>`. It
is a *management console for a whole product family*, so a large share of its menu is
for other ZLT models.

**QManager `:8080`** — Next.js static export + 87 shell CGIs, 44 routes. Deep where the
vendor is shallow: per-band/cell lock, antenna statistics, cell scanner, detailed
metrics, history archive, SmartDNS, DPI, latency/watchdog/connection-quality, logs,
health-check, the browser call terminal, Tailscale (page written, never deployed).

So this is **not** "the vendor UI is better". It is: the vendor covers **router
plumbing** (NAT/DHCP/QoS/VPN) that a CPE customer expects, and QManager covers
**radio telemetry** far better. The gaps are concentrated on the plumbing side.

### 1.1 Confirmed dead on this ODU — do not chase

No WiFi radio exists at all (`/proc/net/wireless` empty, 0 wiphys, no `wlan*` netdev,
dmesg `QCA-WIFI driver not supported`, `/etc/config/wireless` 0 B) — yet the vendor
ships 2.4G/5G/WPS/mesh/MAC-filter pages, hostapd configs and a 60 s boot stall for it.

Also dead: **IPTV**, OneNET, network slicing, second SIM, USB host (`dwc3 mode=device`,
0 devices), IP-passthrough (upstream Quectel `ql_qmap` absent), NR-SA (`+C5GREG: 0,0`),
tcpdump pages (no binary), TR-069 (page and ACS config real, **no `cwmpd`**), and
`ecgiLock`/`wanSettings`/`remotePin` (their client JS calls `RequestCmd` keys that do not
exist in this build). **eSIM** is dead too, but for a subtler reason — see §1.2.

### 1.2 eSIM — challenged, re-probed, and confirmed unavailable

The first pass dismissed eSIM as "`SYS_ESIM_SW=0`, no eUICC/LPA strings". That was the
weakest link in the evidence set and one clause of it was **wrong**: `/bin/dialer`
*does* carry `APP_ID_LPA_MGR` and `g_esim_lock`, and the vendor client has a real feature
behind it — `advance/esimManage.js` builds a genuine activation code
`esim://?e=<EID>&i=<imei>&m=<m>&d=<d>` rendered as a QR code, driven by
`RequestCmd.{CHANGE_CARD_TYPE:246, GET_ESIM_INFO:247, RESET_ESIM_INFO:249,
DOWNLOAD_ESIM_INFO:250}`. So it is implemented software, not a stub.

It is unavailable because the **hardware below it is not there**, proven at three layers:

| Layer | Probe | Result |
|---|---|---|
| Card itself | `qmicli -d qrtr://3 --uim-get-card-status` (libqmi 1.34, `LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib`) | `Slot [1]: Card state: 'present'`, one slot only, **`Application type: 'usim (2)'`**, Application ID `<mac-redacted>:<mac-redacted>:FF:FF:FF:FF` = the GSMA **USIM** applet. Not `ISD-R` (`A0000005591010FF…`). No `eUICC` card type is reported. |
| Host APDU path | `AT+CCHO=?` | **ERROR** — logical channel open unsupported. This is the standard host-LPA route (`CCHO` to ISD-R, `CGLA` to send APDUs); without it no host-side LPA (lpac et al.) can work. |
| Raw APDU | `AT+CSIM=?` → `OK`, but `AT+CSIM=42,"00A4040010A0000005591010FFFFFFFF8900000100"` → `+CME ERROR: phone failure`; `AT+CSIM=10,"00A4040000"` → `+CME ERROR: memory failure` | The command exists in the AT table but is not functional against this card. |
| Vendor eSIM AT | `AT+CESIM=?`, `AT+ESIM=?`, `AT+EID?`, `AT+CEID?`, `AT+SIMTYPE?`, `AT+CARD?` | **all `ERROR`** — no SIMCom proprietary eSIM surface on this module/firmware. |
| Vendor switch | `mdlcfg -g SYS_ESIM_SW` | `0` — the vendor's own capability flag for the menu. |

The physical SIM meanwhile is entirely healthy: `ICCID 8992300002415281727`,
`IMSI <imsi-redacted>`, `+CPIN: READY`. So this ODU is a **single-slot physical-USIM
device**; the eSIM pages are family-wide template, exactly like the ~30 WiFi pages on a
box with no radio.

**Two consequences worth recording:**

1. **Do not build eSIM UI**, and do not treat `APP_ID_LPA_MGR` in the dialer as an
   opportunity. The Qualcomm modem firmware merely *has an LPA manager client*; with no
   eUICC on the SIM interface and no logical-channel support, there is nothing to talk to.
   The gate is closed at the modem interface, so this is not a "medium effort" item — it
   is out of reach without different hardware.
2. **A removable eSIM still works**, and it is not a software feature: a plastic-carrier
   eSIM (5ber/eSIM.me class) presents as an ordinary USIM, so the ODU will accept it in
   the slot with zero changes. Worth knowing for field deployments, not worth code.

Porting any of those would be building a UI for a feature the hardware cannot perform.

---

## 2. Phase 0 — remediate before adding anything (blocking)

The scouts surfaced three live liabilities. Adding features before fixing these means
shipping them onto a box with an open root shell.

| # | Finding | Evidence | Action |
|---|---|---|---|
| P0.1 | **Unauthenticated root telnet on `:::23`** — `busybox telnetd -l /bin/sh`, pid 3284, while `SYS_TELNET_SWITCH=0` | `ps`, `mdlcfg -g TZ_ENABLE_DMZ` | `killall telnetd`; `mdlcfg -a TZ_ENABLE_DMZ=no`; `mdlcfg -a TZ_DMZ_DEST_IP=127.0.0.1`; `mdlcfg -c`; neutralise `iptables_dmz_function`. This is `docs/19` V1/V2 **recurring** — the record was cleaned, the payload was not. Needs a boot-time re-check, not a one-shot kill. |
| P0.2 | **Stored shell injection via the DMZ field** — `TZ_DMZ_DEST_IP` = `127.0.0.1;busybox telnetd -l /bin/sh` | `mdlcfg -g` | Same fix; and treat every vendor `tzcfg` string that reaches a shell as untrusted when we proxy it. |
| P0.3 | **All LAN HTTP/HTTPS is secretly redirected into `tpws`** (`:989`, a Tor transproxy): `PREROUTING -i bridge0 -p tcp --dports 80,443 -j REDIRECT --to-ports 989`, 833 packets matched | `iptables-save` | Not ours, undocumented, and it makes every "site is slow/blocked" report unreadable. Decide: keep (and document it as a feature) or remove. |
| P0.4 | `/cellular/calls` is unusable in a browser: `x16-webrtc` self-signed cert → `TLS handshake error` every 2 s; `zlt-webrtc.service` `enabled` but `inactive (dead)` while pid 2121 runs re-parented to PID 1 — **nothing supervises it** | device log, `systemctl` | Fix during Phase 1 (P1.3). |
| P0.5 | `network/dns_test.sh` → HTTP 200, **0 bytes, 25.0 s**, ×3 (calls `smartdns resolve --https @sky.rethinkdns.com/` which stalls; on 1 core that blocks a worker) | live curl | Add `timeout`, fall back to plain UDP, return a real error. Cheap, and it is currently a wedged widget. |

---

## 3. Phase 1 — free wins already installed (days, not weeks)

These need **no new frontend and no new daemon** — the vendor already put the engine on
the box and never wired it, or QManager already wrote the page and never deployed it.

| # | Item | Why it is nearly free | Effort |
|---|---|---|---|
| P1.1 | **Deploy Tailscale** | Full stack exists: `app/monitoring/tailscale/page.tsx`, 5 components, `hooks/use-tailscale.ts` (474 L), `vpn/tailscale.sh` (612 L), `qmanager_tailscale_mgr` (421 L), `tailscaled.service`. Binaries v1.92.5 at `/data/tailscale/`, `/dev/net/tun` present, unit **enabled in `multi-user.target.wants`** — it only fails because `/etc/systemd/system` is invisible at boot. Add to `start_qmanager`; add to `smoke_endpoints.sh` (absent from all 48 rows). | S |
| P1.2 | **Fix breadcrumbs + nav** — `use-breadcrumbs.ts` `routeKeyMap` lacks `smartdns`, `calls`, `detailed-metrics`, `history` → renders "Smartdns"/"Smartdns" via the capitalise fallback. 2-line fix, same file keeps biting every new route. | S |
| P1.3 | **Supervise `x16-webrtc`** — second instance of the shipped-but-unwatched pattern. Extend `qmanager-guard` (already 1-min) with one `systemctl is-active` check. Also decide on the cert: the page needs a browser-trusted cert or an explicit "accept the exception" hint. | S |
| P1.4 | **`/monitoring/connection-quality` renders 13 empty cards** — `sites.sh` reports `enabled:true, interval:300` but `checked_at:null`, `answered:0/13`; **no sampler process and no `/tmp/qmanager_sites.json`**. The job has no owner on X16. Either give it a 5-min timer or make the page say "not configured" instead of showing 13 blanks. | S–M |
| P1.5 | **`profiles/current_settings.sh` is an all-empty aggregator** (`imei:""`, `apn_profiles:[]`) while `apn.sh`/`imei.sh` have the data. A merge bug, not a missing feature. | S |
| P1.6 | **`scenarios/list.sh` → `[]` but `active.sh` → `"balanced"`** — the list reader and the active reader disagree. | S |
| P1.7 | **Wire `miniupnpd`** — v2.2.3 with netfilter backend, full 6.5 KB config at `/etc/data/miniupnpd/miniupnpd.conf` (only `ext_ifname` commented out), and `/etc/initscripts/start_miniupnpd` already exists and is unwired. Console/app auto port-forwarding. Highest value-per-hour on the box — but it must ship *with* P2.1's UI or users cannot audit the pinholes it opens. | S |
| P1.8 | **Correct four stale docs** — `docs/08` says SMS bodies are unreadable (they read fine now, `source:"store"`); "shell only, no jq" is false (`/data/qmanager/bin/jq` exists, plus `perl 5.30.1` and `lua 5.2.2`); "no `iptables`" is false (`/usr/sbin/iptables` v1.8.4 — it is a **PATH** problem: dropbear root gets `PATH=/usr/bin:/bin`, and `/etc/profile` only adds `/sbin:/usr/sbin` when `$HOME=/home/root`); "no `ip`" is false (`/sbin/ip`, iproute2 5.10.0). This one is worth doing first because the wrong belief steers every design decision below. | S |

---

## 4. Phase 2 — router parity: the actual gaps

This is the block the question is really about. Ranked by value ÷ work, using the
mechanism Scout 1 found for each (so we copy the vendor's *field list*, never its shell).

### P2.1 Port forwarding + DMZ + firewall switch — **the single biggest hole** · M

A CPE with no DNAT is not a router for anyone with a camera, NAS or DVR. QManager has
**zero** hits for port-forward. The vendor drives plain `iptables` through
`iptables_other` (port forward) and `iptables_dmz_function` (DMZ) from a rule file in
`/productinfo/tzcfg/iptables/` — no modem involvement, no AT.

- Backend: one rule-file writer + idempotent apply, reusing the `QMANAGER_FW` chain
  pattern already in `qmanager_firewall` (13 iptables-using files ship the shape).
- Note: the vendor's own `mobileap_firewall.xml` has `FirewallEnabled=0` and
  `UPNPInboundPinhole=0`, and `grep DNAT /etc/data` finds nothing — so we are also
  **fixing** a vendor non-feature, not just porting a page.
- Must land with an explicit "this is the only inbound hole on a CGNAT WAN" warning —
  the WAN is `10.x` CGNAT, so DNAT only works if the carrier has a public route.

### P2.2 DHCP server + reservations + connected-clients list · M

Vendor: `NETWORK_CONFIG:3`, `STATIC_LEASE:115`, `DHCPCLIENT_INFO:223` via `lan_mgr` +
dnsmasq. QManager shows eth0 link speed only; `dnsmasq.leases` is *read* by
`network/ip_passthrough.sh` but never managed. `dhcp-hostsfile` is already
`/etc/data/dhcp_hosts` on this box — the reservation mechanism exists and is empty.

Cheap parts: leases table, per-client hostname/MAC/IP, "who is on my LAN" with
ARP + conntrack. The one thing to get right is not fighting `lan_mgr` for ownership of
the dnsmasq config — the SmartDNS module already proved that pattern (a guard that
rewrites only its own block and restarts only on change).

### P2.3 QoS / SQM: a real CAKE shaper · S–M

**Everything is present and unused.** `CONFIG_NET_SCH_CAKE/HTB/TBF/FQ_CODEL/PRIO/INGRESS=y`,
`cake_qdisc_ops` in kallsyms, `/sbin/tc` works, current defaults are `mq`+`fq_codel`.
Neither vendor nor QManager offers prioritisation, and the uplink is the scarce resource
(~15 Mbps) — bufferbloat on a 1-core LTE ODU is exactly what CAKE fixes.

Design constraint: apply **once** on a change/WAN-up event, never re-fork per tick. At
15 Mbit CAKE on one core is a rounding error; a per-second `tc show` is not.

Then extend to per-client caps via `iptables hashlimit`/`connlimit` (both compiled in)
or `tc` classes per LAN IP. This replaces the vendor's `SPEED_LIMIT:25` rule-file feature.

### P2.4 Parental control — a running daemon with an empty input file · S–M

`parent_control` is **running and enabled** (`USR_PARENTAL_CONTROL_SW=1`) and its input
`/productinfo/tzcfg/parent_control_json` is **empty**. The whole vendor feature is
available and unused: backend is "write that JSON, daemon applies `iptables_pcl_*`".

QManager: 0 hits. Cheapest full-feature parity on the list after UPnP — a form and a
JSON writer, no new daemon. Field value for a shared connection is high (per-child
internet windows, URL block, speed cap).

### P2.5 DDNS · S

`ddclient` + `perl 5.30.1` installed, `/etc/data/ddclient.conf` is the **unmodified
upstream sample** — shipped and never configured. Matters precisely because the WAN is
CGNAT: for the carriers/plans that do hand out a public v4, a hostname is the only way
to reach the box.

### P2.6 Static routes + ARP/neighbour table · S

0 hits in QManager; both are read-only `/proc` views plus a `route` write. Low excitement,
but an "ODU behind another router" deployment is common and currently undebuggable from
the UI. (Scout 3 explicitly argues *against* building a shell page for
`route`/`arp`/`traceroute`/`tcpdump` — that is a diagnostic surface, not a feature. Build
the two tables, not a console.)

### P2.7 SIM PIN/PUK state and unlock · S

`MODEM_CMD:51` / `QUERY_SIM_STATUS:134` expose `pin_left_times`/`puk_left_times` plus
PIN change. Today a SIM-locked ODU is a **dead box with no QManager path to fix it** —
two AT commands close that. First write-path that must obey the allowlist rule (§7).

### P2.8 VPN beyond Tailscale: IPsec IKEv2 read-only status first · M → L

`strongSwan U5.8.4` with `charon/starter/stroke/vici/xfrmi` and the complete plugin set
is installed; `/etc/ipsec.conf` and `/etc/strongswan.conf` are symlinks into `/tmp`
**where the files do not exist**. `vpn_mgr` is running. QManager offers Tailscale only.

Do it in two steps: (a) read-only tunnel status page from `/tmp/cmdlib/vpn_mgr/ipsec.status`
— small, immediately useful; (b) profile CRUD + config generation — the real cost is
strongswan config, not the UI. L2TP/IPsec is the same shape (`xl2tpd 1.3.7` + `pppd 2.4.7`,
`start_l2tp` exists, `/etc/data/l2tp_cfg.xml` is an empty `<l2tpcfg/>`).

---

## 5. Phase 3 — things only this ODU can do (the interesting half)

These are not vendor parity. The vendor does not have them, the hardware does, and they
are the strongest argument for QManager over the stock UI.

| # | Feature | Feasibility | Why it matters here |
|---|---|---|---|
| **P3.1** | **USSD balance engine** — scheduled `AT+CUSD`, parsed, cached, charted, alerted | **easy–medium** | `AT+CUSD=?` → `(0-2)` works. A prepaid Pakistani data SIM on an unattended ODU **runs out of data silently**; this is the difference between "the link died" and "out of balance" (Jazz `*111#`, Zong `*102#`, Telenor `*345#`, Ufone `*124#`). QManager has zero USSD, and the vendor's own USSD page shows the exact button set to copy. Must be one-shot-per-hour, bounded, never retried on timeout — it shares the AT gate with the dialer. |
| **P3.2** | **SMS command channel** (`STATUS`/`REBOOT`/`BALANCE`/`LOCK B3` in, reply out) | medium | The WAN is **CGNAT** (`10.127.74.180/29`) so there is no inbound IP, and the LAN link has been seen to vanish for minutes. An SMS survives both. Receiving is already solved (vendor `/data/sms/sms_read/<slot>`, 0.12–0.37 s); `CMGF`/`CMGS` are device-verified. Needs a sender allowlist and a fixed verb table — no free-form command execution. |
| **P3.3** | **Antenna-chain health + LED aiming** | **easy** | `AT+CRSRP?` returns **4 live chains** and this install shows an **11 dB spread** (`-99,-100,-89,-88` LTE; `-74,-76,-78,-76` NR) — a dead port or a mis-aimed ODU. A per-chain balance tile turns an invisible install fault into a ticket. Bonus: 8 writable `signal_*` GPIO LEDs mean an installer can aim the unit by watching bars, **no browser at all** — the cheapest available field-throughput win. |
| **P3.4** | **Per-client data accounting + quota alerts** | medium | Only an aggregate sampler exists today. `iptables-legacy` + `nf_conntrack` are present and the 1 Hz sampler already has the tick to piggyback on — no new daemon. "Which client ate the balance" is the #1 support question and it pairs with P3.1. |
| **P3.5** | **Thermal telemetry in the dashboard** | **easy** | 43 thermal zones, ~7 populated (`cpuss-0-usr` 38 °C, `modem-skin-usr` 34.6 °C, `modem-ambient-usr` 35.1 °C), trips at 115/125 °C. QManager shows one "temperature". A pole-mounted ODU in a Pakistani summer is a thermal story; correlating skin/ambient against throughput throttling is credible and needs no modem write. |
| **P3.6** | **Durable telemetry ring on `/cache`** | **easy** | journald does not persist, and `/cache` (ubi2_1) is **292 MB free, 276 K used** — unused writable space while `/data` has 79 MB. A ring of serving cell / RSRP / per-chain / WAN events would have answered several past investigations ("which tower did it drop on") that had to be reconstructed from poller samples. Also makes P3.1–P3.5 debuggable in the field. |
| **P3.7** | **NTP/timezone/DST + scheduled reboot** | **easy** | Vendor `TIME_TO_RESTART:263`, `SET_DATETIME:11`, `DST_SETTING:351`; QManager has **no time page at all** and no reboot scheduler, while the device ships `time_daemon`, `ntp.sh` and a reboot daemon. A field ODU needs "reboot at 04:00" and a correct clock (the wall clock is only right after boot). |
| **P3.8** | **Config backup / restore** | easy–medium | Every field deployment needs "save this working config". Vendor has `CONFIG_EXPORT:180` / `CONFIG_UPDATE:184` as a format reference; QManager owns its own state under `/etc/qmanager` so its export is cheap. Pairs with the module model — the archive is the rollback artefact `docs/17` wants. |
| **P3.9** | **Audit the vendor's 00:00 timers** | easy (defensive) | `triggerBkScan.timer`, `triggerChanPrefQuery.timer`, `triggerTopologyOpt.timer` all fire at midnight. Background scans and topology optimisation can move the serving cell, distort signal history and collide with any scan feature we add. Prerequisite for P3.10 and a credibility item on its own. |
| **P3.10** | **PLMN lock via the vendor CGI, not our AT shim** | medium | `AT+COPS=?` blocks and aborts the dialer, so our shim must never scan — the vendor ships `lockPlmn`/`sccan_plmn`/`lockBand`. At band edges the ODU squats on a weak PLMN. Design: proxy the vendor CGI, single-flight, never concurrent with the poller. |

### 5.1 Deliberately deferred (real, but risky or low value per effort)

- **IPv6 / dual-stack** to escape CGNAT — `+CGDCONT` has cid 1 as `IPV4V6` but the active
  context (cid 6) is `IP`-only and `rmnet_data0` has no global v6. The dialer owns the
  context, so it needs a vendor dual-stack switch or a PDA/PDN path. Hard.
- **WAN-outage supervisor** — `docs/29` proved the 2–60 s outage is the dialer's own
  50–60 s watchdog tick with **no external lever** (CGEREP is a no-op, CGACT hangs,
  `start_dialer restart` is an empty case). The only remaining option is
  `killall -9 dialer; dialer &` behind a verification gate and a hard cap. Highest
  customer pain, highest risk — gate behind `AGENTS.md` §5 rule 4 and never ship it
  without a measured before/after.
- **SNMP** (`net-snmp 5.9.1` present, zero code) — enterprise checkbox, carrier-facing.
- **GNSS** — kernel `[gps]` thread, `simcom_gnss` daemon and a live `/dev/gps` exist. One
  bounded read settles whether it produces a fix; do not build on it before that.

---

## 6. Constraints every item above must obey

From the measured budget (Scout 5 §3) — CPU, not RAM or flash, is the wall: **one
Cortex-A7-class core, `idle` jiffies frozen at 6718 for 28 minutes, `loadavg` 4–13, ~15 %
of the core already consumed by the stack we ship.**

1. **No new long-lived pollers.** Extend the existing 1 Hz `qmanager_poller`, use a CGI,
   or a 1-minute timer. A third `while true; sleep 1` costs more than it reports.
2. **Fork is the expensive unit** (~35 ms under load). Prefer one `awk` / one read loop
   over a 10-iteration shell loop; prefer `flock`+`cmp` idempotent guards, which is why
   both shipped guards are silent when healthy.
3. **1-minute timers, not sub-10 s.** A `systemctl`-only guard tick is 0.1 % of the core.
   Anything forking 20×/minute is not affordable.
4. **Event-driven beats periodic** — `/proc/net/route`, `/sys/class/net/*/operstate` and
   rtnetlink markers are free next to a poller.
5. **Never add a listener.** There are already 11 listening sockets (`:23` root telnet,
   `:80`, `:443`, `:8080`, `:989`, `:7777`, `:8443`, `:8444`, `:22`, dnsmasq `:53` v4+v6)
   on a CGNAT box with a documented injection history. Features are CGIs behind the
   existing front.
6. **Respect the boot shape.** Start from `StartTZApp`/`start_cfgd`, arm timers there,
   keep state in `/etc`/`/data`, put bulky archives on `/cache`.
7. **Serialise and bound every AT call** (`timeout 6`, allowlist, denylist). One
   unanswered command takes the WAN down. USSD/SMS are the new injection surface: accept
   digits only, reject everything else, rate-limit.
8. **`systemctl enable` never works here.** `/etc` is a separate ubi volume mounted ~10 s
   after systemd loads units (`ubi2` attaches at 9.6–10.3 s, rootfs R/O at 5.7 s). The
   only boot path is a hook — `deploy-x16/start_qmanager` for units, `StartTZApp` for
   timers.

---

## 7. Sequencing

Per `AGENTS.md` §4 and §7 a feature is **not done until it is a module and a commit**:

```
<module>/
├── README.md          what it does, how to verify, how to roll back
├── install.sh         --install | --check | --uninstall, idempotent, backs up
└── <payload>          exact bytes that land on the device
```

and the commit body carries `Verified: <command> -> <result>` for anything touched on the
device. `tests/run-all.sh` gates it; a new feature adds its route to the smoke suite
(Tailscale is currently missing from all 48 rows — do not repeat that).

| Sprint | Contents | Gate to close it |
|---|---|---|
| **0** | P0.1–P0.3 (telnet, DMZ payload, tpws decision) + P1.8 (fix the four stale docs) | `killall telnetd` then reboot → `:23` closed; `mdlcfg -g TZ_ENABLE_DMZ` = no; `ss`/`netstat` shows 10 listeners |
| **1** | P1.1–P1.7 (Tailscale, breadcrumbs, webrtc guard, sites sampler, profiles, scenarios, UPnP) | Tailscale reachable; `/monitoring/connection-quality` shows real data; `dns_test.sh` returns <2 s; `calls` page loads without a cert error; `run-all.sh` green |
| **2** | P2.1 + P2.2 together (port forward/DMZ + DHCP/clients) — they are one mental model, "the LAN edge" | A forwarded port verified from outside the LAN; a reservation honoured across a reboot; leases table matches `dnsmasq.leases` |
| **3** | P2.3 QoS (CAKE, once, verified), P2.4 parental control, P2.7 SIM PIN | CAKE applied on uplink, `tc -s qdisc` shows drops not bufferbloat; parental rule blocks a host; PIN state read |
| **4** | P3.1 USSD, P3.3 antenna chains + LED, P3.5 thermal, P3.6 `/cache` ring | One USSD exchange decoded and cached; per-chain tile shows the 11 dB spread; ring file survives reboot |
| **5** | P3.2 SMS channel, P3.4 per-client accounting, P3.7 time/reboot, P3.8 config backup | `STATUS` SMS answered; quota alert fires; scheduled reboot verified; exported config restored on a scratch box |
| **6** | P2.8 IPsec (status first), P3.9 timer audit, P3.10 PLMN lock | IPsec status page shows real state; midnight timers documented; operator lock applied and reverted |

Sprints 0–1 are roughly a day each. Sprint 2 is the one to protect — it is the answer to
the original question and it is two modules, not one.

---

## 8. Residual risks

- `/tmp/qm` is not a git checkout, so the QManager-side file inventory (Scout 3) must be
  re-confirmed against the real tree before any build. A payload built from the wrong
  tree silently half-disappears (`AGENTS.md` §4, the Calls-button incident).
- Scout 1's cmd/param mapping comes from a **same-platform reference build**
  (`http.cgi.bak`) corroborated by the client JS — per-feature *live JSON* could not be
  captured without an admin login. Enough to copy a field list, not to claim schema parity.
- The vendor's `parent_control`, `flow_ctrl` and `vpn_mgr` daemons are already running and
  we do not own their state files. Any write into their config space needs a backup and a
  `--check`-style read-back before it is trusted.
- Load 14–16 observed during the audit was **scout-induced** (five concurrent greps over a
  16.7 MB docroot, 0 % idle) and the LAN stopped answering for ~2 minutes. That is a
  warning about this box's headroom, not a device fault — and a reason the "no new
  pollers" rule is not negotiable.
