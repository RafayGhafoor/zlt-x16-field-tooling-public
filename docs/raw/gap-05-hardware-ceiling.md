# GAP-05 — What is actually possible on this hardware (the ceiling)

Scout 5 of 5, gap-filling programme. **Read-only investigation.** Goal: establish
the *ceiling* — which capabilities the SDX65 + SIM8260E combination genuinely
supports, which vendor-menu items are marketing or dead on this model, and what
compute/flash/persistence budget a new feature may spend.

Evidence tags: **[E]** measured on the device this session (2026-10-26 22:56–23:22,
uptime 4→28 min) · **[D]** proven in a repo doc, cited · **[I]** inferred, not
measured.

**Read-only discipline that was kept:** no write/config AT command was sent, no
`CFUN`/`CCELLCFG`/`CUSD` send/`CMGS`/`CNV`/`SIMEI` write, no `AT+COPS=?` (blocking,
aborts the dialer — [04](../04-simcom-at-mapping.md)), no `AT+CSIM` (not in the DEVICE string set, and an
unanswered command wedges `atcmd_daemon` — [09](../09-features.md)). Every AT call
was a `timeout 6` read.

**Measurement caveat that matters for §3:** two other scouts were running
concurrently on this 1-core box (`grep -rls /etc /data`, CGI sweeps), which
dominates the CPU figures. Where a number is contaminated I say so and give the
attributable figure instead. During the worst of it the box was **unreachable on
the LAN for ~2 minutes** (ping 100 % loss, same boot — `uptime` did not reset).
That is itself a budget data point, not an outage of the fix under study.

---

## 1. Capability matrix

### 1.1 Compute, memory, storage

| Capability | Supported? | Evidence | Implication |
|---|---|---|---|
| CPU cores | **1 — hard ceiling** | [E] `nproc`=1; `/proc/cpuinfo` one processor; `/sys/devices/system/cpu/{possible,present,online}` = `0`; device tree has only `cpus/cpu@0` | The other SDX65 cores are not merely offlined, they are **absent from the DT** → not enableable. Every design decision below follows from this. |
| CPU clock | 1.8 GHz max, governor `ondemand`, observed **pegged at 1804800 kHz** | [E] `scaling_cur_freq`=`cpuinfo_max_freq`=1804800 | Ondemand never gets to downclock; the core is busy continuously. |
| Idle CPU | **none measurable** | [E] `cpu … idle` frozen at `6718` across every 5 s/20 s/30 s window for 28 min (≈67 s idle since boot); 100 % busy in every window; `loadavg` 3.9→13.6 | See §3. Any always-on daemon is competing with zero slack. |
| RAM | 646 MiB total, **463 MiB available**, 199 MiB used, zram swap 330 MiB (1.5 MiB used) | [E] `/proc/meminfo`, `free`, `/proc/swaps`; matches [01](../01-target-device.md) | RAM is *not* the constraint. 300 MB of headroom exists. |
| Rootfs | **read-only** ubifs, 184.5 MB, 43.9 MB free | [E] `mount` → `ubi0:rootfs … (ro, assert=read-only)`; `df` | Matches [01]'s earlier "not read-only" note — the **current** truth is R/O. Nothing new can go on `/`. |
| Writable volume | `/etc` + `/data` + `/userdata` + `/persist` = **one** ubi2_0 volume, 173.5 MB, **77.6 MB free** (55 % used) | [E] `df` shows all four on `/dev/ubi2_0` | 77.6 MB shared by all modules: qmanager 41.8 MB + webrtc 21.9 MB are already 37 % of it. |
| `/cache` | ubi2_1, **297 MB with 292 MB free and 276 KB used** | [E] `df /cache` | A large, entirely unused writable volume. Best place for logs/archives/telemetry. |
| `/firmware` | R/O, 74.7 MB, **99 % full** | [E] `df` | No room, and out of bounds per AGENTS §2. |
| Thermal | 43 zones, only ~7 populated: `cpuss-0-usr` 38.0 °C, `modem-skin-usr` 34.6 °C, `modem-ambient-usr` 35.1 °C, `pmx65_tz` 32.6 °C, `modem-lte-sub6` 28.0 °C; trips at 115/125 °C | [E] `/sys/class/thermal/thermal_zone*`; many zones read `-273000` (unpopulated) | Thermal headroom is large; **temperature telemetry is free and worth surfacing** (§4.10). |

### 1.2 Radios

| Capability | Supported? | Evidence | Implication |
|---|---|---|---|
| LTE | **Yes** — live on **Jazz (410-01), B1, EARFCN 250, PCI 104**, RSRP −87 | [E] `AT+CPSI?` → `+CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-118,-870,-583,-1`; `AT+COPS?` → `+COPS: 0,0,"Jazz",13` | Confirms the Ooredoo-Oman FW works fine on a Pakistani carrier; RAT AcT 13 = EUTRAN+NR. |
| 5G **NSA** | **Yes, live** — n41, EARFCN 509070, RSRP −76…−78 | [E] second `+CPSI` line: `+CPSI: NR5G_NSA,47,NR5G_BAND41,509070,-760,-110,26,1,9` | EN-DC is real on this unit (consistent with [09](../09-features.md)'s n41 tile fix). |
| 5G **SA** | **No usable path** | [E] `AT+C5GREG: 0,0` (not registered); [D] [23](../23-cell-locking-on-sim8260e.md): `C5GCELLCFG` write/state unverified, NR-SA lock refused by design | Do not build NR-SA features. Keep reporting NSA correctly. |
| Carrier aggregation | Yes | [D] [09](../09-features.md) dashboard reports 3-carrier CA from `+CCAINFO` | Already surfaced. |
| **Antenna chains** | **4 real per-chain RX chains** | [E] `AT+CRSRP?` → `+CRSRP: LTE,-99,-100,-89,-88` / `+CRSRP: NR5G,-74,-76,-78,-76`; `AT+CSINR?` → `LTE,7,7,10,10` / `NR5G,25,23,23,26` | Four independent chains with **up to 11 dB spread** on this install. Per-chain RSRQ does not exist ([26](../26-antenna-stats-on-x16.md)). → §4.3 |
| **WiFi** | **NO RADIO. Not possible.** | [E] `dmesg`: `wlan_pld:pld_register_driver:299:: Fail to register pcie driver`, then at 60.7 s `QCA-WIFI driver not supported`; `/sys/class/ieee80211/` **empty** (0 wiphys); 0 `wlan*` netdevs; `lsmod` has **0** wlan/cnss/ath/brcm modules (`/sys/module` holds only `cfg80211`, the generic subsystem, and `qca_macsec`, which is MACsec not WiFi); `qwesd` + `wlan_services` + `hostapd` userspace all running **idle** | The whole QCA WiFi userland, the 60 s driver retry, the `modem-wifi` thermal zone and `hostapd-eth0/eth1.conf` ship anyway — this firmware is shared across ZLT models (see `MTK7561_wlan_para.json`, `RTL819X_wlan_para.json` in the docroot). **Cost: ~60 s of wasted boot and one spinning service.** |
| GNSS | **Present, unverified** | [E] kernel thread `[gps]`, `/usr/bin/simcom_gnss` (pid 2336), `/dev/gps` char device (open — `Device or resource busy`); no `AT+CGNS*` strings in that binary | Cannot confirm an antenna is fitted. One bounded NMEA read would settle it. → §4.9 |
| Bluetooth | No evidence | [I] `bluetooth_power` module present, no BT netdev/daemon | Ignore. |
| eSIM | **No eUICC path** | [E] `AT+SPCONFIGSIMSLOT?` → `ERROR`; [D] [09](../09-features.md) "single slot reported"; host-side: `firmware-analysis/dialer.strings` contains only `g_esim_lock` (a mutex) and **zero** LPA/euicc/profile-download strings — **partly superseded, see the correction under this table** | The vendor's `esimIndex.html`/`esimManage.html` are template pages for other SKUs. → §2 |

> **CORRECTION (verified after this report was written, `docs/30-gap-fill-plan.md` §1.2):**
> the conclusion stands — eSIM is unusable — but two statements above are wrong and the
> evidence is stronger elsewhere. (a) `/bin/dialer` **does** contain `APP_ID_LPA_MGR`, not
> just `g_esim_lock`, so "zero LPA strings" is false. (b) `AT+CSIM` *was* probed and the
> result matters: `AT+CCHO=?` → `ERROR` (no logical channel, so no host-LPA route at all)
> and real APDUs via `AT+CSIM` return `+CME ERROR`. (c) The decisive evidence is QMI card
> status: `qmicli -d qrtr://3 --uim-get-card-status` reports one slot with
> `Application type: 'usim (2)'`, AID `<mac-redacted>:<mac-redacted>:FF:FF:FF:FF`
> — the GSMA USIM applet, **not** ISD-R, and no `eUICC` card type. The card is a plain
> physical USIM; the modem firmware merely has an LPA *client* with nothing to talk to.

| Second SIM slot | **No** | [E] one `sim_detect` LED, one detect GPIO; no slot config in `/etc/data`; [D] [09](../09-features.md) "no `AT+QUIMSLOT` equivalent; single slot" | Dual-SIM failover is impossible. |
| Network slicing | Vendor page exists, carrier support absent | [E] `/tzwww/html/advance/sliceConfiguration.html` renders `{{dnn}}` enable/disable; dialer has `is_slice_context`/`slice%d`/`slice_total`; [I] no Pakistani MNO sells URSP slicing | Not a gap worth filling. → §2 |

### 1.3 Module surface via read-only AT

| Capability | Supported? | Evidence | Implication |
|---|---|---|---|
| **Voice / VoLTE** | **Yes, fully** | [E] `AT+VOLTESETTING: 1` (VoLTE on); `AT+CGDCONT?` shows cid 2 `IPV4V6,"ims"`; `AT+CGCONTRDP` shows **cid 2 activated** with an IMS address; `AT+CPAS: 0`; `AT+CLCC` empty (idle); dialer carries `SYS_VOLTE_SW`, `+IMSHOLTEINFU`, `AT+VOLTESETTING?`; [D] [27](../27-call-terminal.md) proves a real call with `ul_frames=999 ul_err=0` / `dl_frames=1013` | IMS is registered on Jazz. The audio ceiling is a **vendor PCM tap** (`libolinterface`→`alsa_daemon`), not ALSA ([27] §"What actually works"). Any voice feature must go through `PCMIO_*`, one call at a time. |
| **USSD** | **Yes** | [E] `AT+CUSD=?` → `+CUSD: (0-2)`; dialer has `sunsea_CUSD_handler` **and** the send path `AT+CUSD=1,"%s",15` / `AT+CUSD=2`; vendor UI has a real page (`manage/ussd.html` + `ussdIndex.html`, `USSD_SEND`/`USSD_SET`, buttons `ussdAirtime`/`ussdData`/`ussdNumber`) | End-to-end supported and shipped by the OEM; **QManager has nothing**. Best gap in the whole audit. → §4.1 |
| SMS | Yes (modem) but bodies live in the vendor store | [D] [09](../09-features.md) "SMS bodies fixed 2026-10-26": `/data/sms/sms_read/<slot>`; `AT+CMGR/CMGL` answer bare `ERROR` because `/bin/sms_mgr` drains messages | Reading is easy (0.12–0.37 s). **Sending needs `CMGF`/`CMGS`** — verified commands per [04](../04-simcom-at-mapping.md). → §4.2 |
| PLMN scan / operator lock | Vendor-supported, hazardous | [E] `lockPlmn.html`, `sccan_plmn.html`, `ecgiLock.html` in the docroot; [D] [04](../04-simcom-at-mapping.md) "`AT+COPS=?` blocks and is aborted by any serial byte" | Do not implement a scan in our own shim. If needed, drive the vendor CGI. `fplmn` stays dead (`CRSM` never answers). |
| Band selection | Yes | [D] [09](../09-features.md) `bands/current.sh` → `1:3:5:8` live via `AT+CSYSSEL`; [E] `AT+CSYSSEL?` bare read → `ERROR` (needs the key form) | Band policy is fillable; band *capability* list must come from the module spec, not a probe. |
| Cell lock | LTE only, one cell | [E] `AT+CNMP: 2`; [D] [23](../23-cell-locking-on-sim8260e.md) `+CCELLCFG: 0,0` readable, write deliberately not exercised | Unchanged from [23]. NR-SA lock stays refused. |
| RAT preference | Yes | [E] `AT+CNMP: 2` (auto); [D] [04](../04-simcom-at-mapping.md) numeric enum | An NR/LTE policy toggle is feasible. |
| CA details | Yes | [D] [09](../09-features.md) (`+CCAINFO`, no per-CC SINR) | Already done. |
| Per-chain signal | Yes | [E] `+CRSRP`, `+CSINR` (above) | Already done, but the *diagnostic* use is not. → §4.3 |
| `AT+CESQ` | **No** | [E] `AT+CESQ` → `ERROR` (again, matches [26](../26-antenna-stats-on-x16.md)) | Do not use as an RSRQ source. |
| eSIM (`AT+CSIM`) | not sent (safety) | — | Not in the DEVICE string set; an unanswered command wedges the AT daemon ([09](../09-features.md) incident). No eUICC evidence anywhere. |
| APNs available | 4 contexts preconfigured | [E] `+CGDCONT`: cid 1 `IPV4V6` (unset), cid 2 `ims`, cid 3 `sos`, cid 6 `IP,"connect.mobilinkworld.com"` = the live WAN | A **dedicated SOS/emergency APN** exists — unused. Also note only cid 6 is active; cid 1's `IPV4V6` is unset. → §4.7 |

### 1.4 Data plane, QoS, accounting

| Capability | Supported? | Evidence | Implication |
|---|---|---|---|
| IPA hardware offload | **Active** | [E] `/sys/kernel/debug/ipa/stats`: `hw_tx=403835`, `sw_tx=0`; [D] [18](../18-ipacm-enablement.md) | Confirmed again. Do not restart IPACM casually ([18]: WAN address arrives only via rtnetlink). |
| LAN port(s) | **One**, 2.5 GbE | [E] `eth0` ← PCIe `0000:01:00.0`, driver `r8125 2.5Gigabit Ethernet driver 9.010.01-NAPI-RSS`, link 1000 Mb/s; `brctl show` → `bridge0: eth0` only; QCMAP tries `eth1` and fails (`Re-enable eth1 interface failed with 19`) | The LAN side can never be the bottleneck. Single-port ODU: no LAN-side redundancy is even expressible. |
| LAN MAC stability | **Not stable across boots** | [E] `dmesg`: `r8125 … Invalid ether addr <mac-redacted>` → `Random ether addr <mac-redacted>`; `bridge0` keeps `<mac-redacted>` from config | Per-boot random `eth0` MAC behind a fixed bridge MAC. Anything keyed to `eth0`'s MAC (DHCP reservations, captive portals, "MAC clone") is fragile. |
| WAN | Up, CGNAT, MTU 1400 | [E] `rmnet_data0` = `10.127.74.180/29` via `rmnet_ipa0`; route/`ip addr` show MTU 1400 (the [29](../29-wan-drops-and-band-switching.md) workaround) | **No public IP** → no inbound reachability. Any remote-management feature must be outbound-initiated. |
| Throughput observed | 83.35 ↓ / **15.02 ↑ Mbps**, 0 % loss | [D] [09](../09-features.md) live Ookla run | The **uplink is the scarce resource** — the right thing to shape/queue. |
| QoS / shaping | **Yes — full stack** | [E] `/proc/config.gz`: `CONFIG_NET_SCH_{HTB,PRIO,RED,SFB,TBF,NETEM,FQ_CODEL,CAKE,INGRESS}=y`; `cake_qdisc_ops`,`htb_qdisc_ops`,`tbf_qdisc_ops`,`fq_codel_qdisc_ops`,`netem_qdisc_ops`,`sfq_qdisc_ops`,`clsact_qdisc_ops` all in `/proc/kallsyms`; `/sbin/tc` (iproute2) works and already shows `mq`+`fq_codel` on `eth0`/`rmnet_ipa0` and `cake` on `lo` | Everything needed for a real shaper is **built into the kernel and the binary exists**. Nobody uses it (vendor or QManager). → §4.4 |
| Firewall / counters | Yes | [E] `/usr/sbin/iptables` → `xtables-legacy-multi`, `iptables-legacy-restore/save`; `nf_conntrack`+`nf_nat`+`iptable_mangle` in kallsyms; conntrack count 1192 | Per-client accounting is expressible. → §4.5 |
| Traffic accounting | **Already there** (aggregate) | [D] [09](../09-features.md) `qmanager-traffic` 1 Hz shell sampler on `/proc/net/dev` → `/tmp/qmanager_traffic.json`; `data_used.sh`; [E] process alive | Aggregate exists; **per-client** does not. |
| Traffic engine (DPI) | Running but expensive | [E] `tpws` pid 2556 = **2.5–3 % of the core continuously** (highest single user of CPU on the box besides agents) | A deliberately-added daemon's cost is not theoretical here; measure it (§3). |

### 1.5 Interfaces a feature could use

| Interface | Supported? | Evidence | Implication |
|---|---|---|---|
| USB **host** | **No** | [E] `/sys/bus/usb/devices` empty (0 devices); `dwc3` debugfs `mode` = `device` | No USB storage, no USB LTE stick, no USB serial. Adb is USB-gadget only (`AT+CUSBCFG=USBADB` via `start_adb`). |
| LEDs | **8 writable** | [E] `/sys/class/leds/{signal_1..4,network_normal,network_unnormal,sim_detect,system_run}` all offer the `gpio` trigger; `brightness` readable/writable | Physical, browser-free status output. → §4.3 |
| Buttons | Yes | [E] `/dev/input/event0,event1` + `button_daemon` (pid 1085) | A physical reset/WPS button exists; repurposing it is *possible* but shares the vendor's reset semantics. |
| GPIO | Yes | [E] `/sys/class/gpio/{export,gpiochip896,912,916}` | Available, but nothing needs it today. |
| RTC / clock | Yes | [E] `date` shows PKT; `ActiveEnterTimestamp` 2026-10-26 22:53:44 while `InactiveExitTimestamp` reads 1970 → the wall clock is set after boot | Scheduling absolute times around boot is unreliable; use monotonic + timers. |
| Tooling present | `curl`, `wget`, `openssl`, `flock`, `timeout`, `bash` (`/bin/bash`), `ethtool` (`/usr/sbin`), `tc` (`/sbin/tc`), `iptables` (`/usr/sbin/iptables`), `ip` (busybox applet) — **all four outside PATH** — plus `brctl`, `netstat`, `tftp`, `ftpget`, `watch` | [E] | **`PATH=/usr/bin:/bin` only** — `/sbin/tc`, `/usr/sbin/iptables` must be called absolutely. Same trap as `/bin/busybox.nosuid ifconfig` in AGENTS §1. |
| Tooling absent | `python`, `jq`, `nc`, `tcpdump`, `ss`, `crond`/`crontab`, `vmstat`, `sar` | [E] | All logic stays in `ash`/`bash` + curl. No cron — **systemd timers are the only scheduler** (and they do work once armed post-boot, see §1.6). |

### 1.6 Persistence / boot — re-verified this session

| Claim (from AGENTS §4, [09]) | Still true? | Evidence |
|---|---|---|
| Root is R/O ubifs | **Yes** | [E] `mount`: `ubi0:rootfs on / type ubifs (ro,…)` |
| `/etc`,`/data` mount late, after systemd loads units | **Yes** | [E] `dmesg`: rootfs R/O mounted at **5.68 s**; `[userdata-ubi-mount.sh] ubi attach mtd_block_number: 31` at **9.62 s**; `ubi2: scanning is finished` at **10.32 s**; systemd-udevd active at 11.6–12.1 s |
| Units under `/etc/systemd/system` are invisible that boot | **Yes, and the workaround is what is actually running** | [E] `qmanager-httpd`: `is-enabled` = `enabled`, but `InactiveExitTimestamp` = **1970-01-01 19:00:38** (monotonic ~38 s) and `ActiveEnterTimestamp` = 22:53:44 → started by the boot hook, not by the graph |
| The hook is `/etc/initscripts/StartTZApp` (+ `start_cfgd`) | **Yes** | [E] `StartTZApp:28–33` = smartdns boot, webrtc boot, `start_qmanager start &`; `start_cfgd:7–8` = `zlt-ipacm.sh boot` + `systemd-run --on-active=90 … reassert`; backups `.pre-qmanager/.pre-smartdns/.pre-webrtc` present |
| systemd **timers are usable** once armed after boot | **Yes — this is the cheap scheduling primitive** | [E] `systemctl list-timers`: `qmanager-guard.timer` and `zlt-smartdns.timer` LAST 37 s ago, next 22 s; `qmanager-dns-stats.timer` 4 min; `qmanager-dns-edge.timer` 21 min |
| Vendor already runs daily timers | **New** | [E] `triggerBkScan.timer`, `triggerChanPrefQuery.timer`, `triggerTopologyOpt.timer` all fire at **00:00** | Before building a scan/band-policy feature, check these — they may already do it, or collide with it. → §4.11 |

**Design consequence, stated plainly:** a new always-on daemon must be started
from `StartTZApp` (or `start_cfgd` when it has to beat the dialer) and, if it
needs a schedule, arm a systemd timer from there. `systemctl enable` is not a
boot mechanism on this box, and `/etc/systemd/system` is not readable at boot.
Two shapes are cheap and already proven: **CGI-on-demand** (what QManager does)
and **a 1-minute timer guard** (what `qmanager-guard`/`zlt-smartdns` do). A third
long-lived poller is the expensive shape (§3).

---

## 2. Real vs vendor-marketing-dead

The vendor SPA (`/tzwww`, one generic SIMCom/ZLT UI for several models) advertises
a great deal this ODU cannot do. Every row below is a page **present and wired**
in the docroot.

| Vendor menu / page | Reality on **this** ODU | Verdict |
|---|---|---|
| `config/mainWifiSetting`, `main5gWifiSetting`, `setting_24wifi_1`, `wlan5g*`, `wifi24g1..4_info`, `wifi5g1..4_info`, `wirelessConnected`, `wpsPinCode`, `mainWifiSetting`, `mesh*`, `wlan_wan` | **No WiFi radio**: PCIe WLAN never registers (`wlan_pld … Fail to register pcie driver`), `QCA-WIFI driver not supported` at 60 s, zero wiphys | **DEAD** (hardware absent) |
| `advance/esimIndex`, `advance/esimManage` | No eUICC, no LPA strings, `SPCONFIGSIMSLOT?` → `ERROR` | **DEAD** (hardware absent) |
| `advance/sliceConfiguration` | Page + dialer `is_slice_context` exist; no MNO slicing on Jazz/Zong/Telenor/Ufone | **DEAD in the field** (network absent) |
| `advance/snmpIndex`, `snmpSetting` | Agent not present/started | dead unless a daemon is added |
| `advance/tr069`, `tr069Index` | Armed but latent; ACS creds in `mdlcfg` ([19](../19-vulnerability-assessment.md) V11) | **latent risk, not a feature** |
| `advance/lockPhyCell`, `ecgiLock`, `lockPlmn`, `sccan_plmn` | LTE-only one-cell lock works; NR-SA lock unverified/refused; `AT+COPS=?` blocks | **partly real** — see [23](../23-cell-locking-on-sim8260e.md) |
| `advance/lockBand` | `+CSYSSEL` band selection real, band list `1:3:5:8` live | **real** |
| `advance/ipPass` | Upstream drives Quectel `ql_qmap`; IP-passthrough not mapped here | **DEAD** ([09](../09-features.md)) |
| `advance/iptv`, `iptvIndex` | IPTV/VLAN plumbing present in scripts; no IPTV service on these carriers | **dead in the field** |
| `advance/gre`, `l2tpv3`, `vpn`, `vxlanSetting`, `pptp.sh` | Scripts/config exist, but these are router-app features and **V8 lists PPTP/GRE as injection candidates** ([19]) | **real but dangerous**; not a gap to fill |
| `advance/oneNet`, `displaySolutionMode`, `autoDial`, `netChange` | Cloud/OneNET + "solution mode" template pages for other SKUs | **DEAD** |
| `manage/sysAt` (AT console), `manage/ussd`, `manage/exportLog`, `tools/tcpdump`, `tools/daigSocket`, `tools/tracepath`, `tools/ping` | AT console real and root-privileged; **USSD real** (`+CUSD: (0-2)` + dialer send path); tcpdump binary absent but a capture page exists | **USSD = real, unfilled gap**; the rest are surface/risk |
| `voice/vioceBasicConfig`, `voiceAdvanceConfig`, `voiceIndex`, `voipAdvancedSettings`, `voipCall` | **Real** — VoLTE=1, IMS PDP active, and [27](../27-call-terminal.md) placed a working call | **real, partially used** |
| `info/wan1_info` + `wired_wan` | One physical port only | fine |
| `manage/deviceSelfCheck`, `logInfo`, `sysLog` | Real (log export is a tar in the docroot) | real |
| `manage/pinSet`, `remotePin`, `simChange`, `roaming`, `pinSetIndex` | Real for one slot | partially dead (single SIM) |

**Summary of the marketing-vs-hardware gap:** three entire feature families (WiFi,
eSIM, slicing) plus two optional ones (SNMP, OneNET) are page furniture on this
SKU. Two *real* vendor capabilities — **USSD** and **VoLTE voice** — are barely
reached by anything we ship.

---

## 3. The budget: CPU / RAM / flash, and what it forbids

### 3.1 Measured marginal costs (the actionable numbers)

| Operation | Cost | How measured |
|---|---|---|
| **fork + exec + read** (`cat /proc/net/dev`, ×100) | **35.6 ms wall / ~5 ms CPU each** | [E] `time` in bash: `real=3.565 user=0.364 sys=0.173` |
| `systemctl is-active` ×4 (a guard tick) | **0.41 s wall / 0.05 s CPU** | [E] `real=0.413 user=0.013 sys=0.033` |
| QManager CGI (on-demand page) | **108 ms** | [E] `overview-CGI real=0.108` |
| `atcmd 'AT+CSQ'` round trip | **87 ms** | [E] `real=0.087` |
| Scheduler delay at `loadavg` 13 | **55 ms on a 2 s sleep** | [E] `sleep2 real=2.055` |
| Existing 1-min guard cost | ≈ **0.1 % of the core** (4 × `systemctl`) | derived from the two rows above |
| `tpws` DPI, always-on | **2.5–3 % of the core** | [E] per-`/proc/PID/stat` deltas over 20 s |
| `x16-webrtc` idle | ~0.8 % | [E] same method |

**Attributable CPU of everything we deploy, idle:** `tpws` 2.5 %, `dialer` 1.7 %,
`ipacm` 1.5 %, `qmanager_poller` 1.5 %, `x16-webrtc` 0.8 %, traffic+ping 0.6 %,
`dnsmasq` 0.3 %, IPA/memlat kworkers ~7 % → **≈15 % of the single core**, with the
rest of the 100 % busy going to unaccounted kernel/softirq work (IPA + rmnet data
path) and, during this measurement, to two concurrent scout sessions
(one `grep -r` accounted for **48 % of the core by itself**). Under that load the
box's LAN stopped answering for ~2 minutes.

### 3.2 Statement

> **CPU is the binding constraint, and it is already over-subscribed.** One
> Cortex-A7-class core at 1.8 GHz with a hard 1-core DT limit, never idle
> (`idle` jiffies frozen at 6718 for 28 minutes), `loadavg` 4–13, ~15 % of the
> core consumed by the stack we already ship. **RAM (463 MB free) and `/cache`
> (292 MB free) are not constraints; the `/data`+`/etc` volume (77.6 MB free) is
> a soft one; CPU is hard.**

### 3.3 Design rules that follow (non-negotiable for new work)

1. **No new long-lived pollers.** A third `while true; sleep 1` daemon costs more
   than everything it might report. Extend the existing 1 Hz `qmanager_poller`
   tick, or a CGI, or a timer.
2. **Fork is the expensive unit (~35 ms under load).** A shell loop over 10 files
   costs a third of a second of wall time. Prefer one `awk`/one `read` loop, and
   prefer `flock`+`cmp` idempotent guards (which is why the two shipped guards are
   silent when healthy).
3. **1-minute timers are the right cadence; sub-10 s is wrong.** A `systemctl`-only
   guard tick is 0.1 % of the core; that is the affordable shape. Anything that
   forks 20 times a minute is not.
4. **Event-driven beats periodic.** `/proc/net/route`, `/sys/class/net/*/operstate`
   and rtnetlink markers are free compared to a poller.
5. **Never add a listener.** There are already 11 listening sockets / 9 services
   (`:23` root telnet!, `:80`, `:443`, `:8080`, `:989`, `:7777`, `:8443`, `:8444`,
   `:22`, plus dnsmasq `:53` on v4 and v6) on a box with a
   CGNAT WAN and a documented injection history. Features should be CGIs behind
   the existing front, not new ports ([19](../19-vulnerability-assessment.md) V5/V18).
6. **Respect the boot shape.** Start from `StartTZApp`/`start_cfgd`, arm timers
   from there, keep state in `/etc`/`/data` (`/cache` for bulky archives).
7. **Serialise and bound every AT call** (`timeout 6`, allowlist, blacklist) —
   one unanswered command takes the WAN down ([09](../09-features.md)).

---

## 4. Twelve genuinely interesting things this ODU could do and does not

Ranked by *field value for a Pakistani-carrier ODU per unit of risk*. "Feasibility"
= easy (one CGI/timer, existing commands) · medium (new state machine or one
unverified interface) · hard (needs a vendor path or a risky write).

| # | Idea | Feasibility | Why it is interesting here |
|---|---|---|---|
| **1** | **USSD balance engine.** Scheduled `AT+CUSD` for airtime/data balance, parsed, cached, charted, alerted. | **easy–medium** | `+CUSD: (0-2)` works [E], the dialer already owns the send path (`AT+CUSD=1,"%s",15`), and the OEM ships the exact button set (`ussdAirtime`/`ussdData`/`ussdNumber`). A prepaid Pakistani data SIM on an unattended ODU **runs out of data silently** — this is the difference between "died" and "out of balance" (Jazz `*111#`, Zong `*102#`, Telenor `*345#`, Ufone `*124#`). QManager has zero USSD. Must be one-shot-per-hour, bounded, never retried on timeout. |
| **2** | **SMS command interface** (inbound: `STATUS`/`REBOOT`/`LOCK B3`/`BALANCE`; outbound reply via `CMGS`). | **medium** | The WAN is **CGNAT** (`10.127.74.180/29`) so there is no inbound IP, and the LAN link has been observed to vanish for minutes. An SMS is the only channel that survives both. Receiving is already solved (vendor `/data/sms/sms_read/<slot>`, 0.12–0.37 s per [09]) and `CMGF`/`CMGS` are DEVICE-verified [04]. Needs an allowlisted sender list and a hard "no writes beyond a fixed verb table" rule. |
| **3** | **Antenna-chain health / alignment alarm + live LED signal bars.** | **easy** | `+CRSRP?` returns **4 live chains** and this install shows an 11 dB spread (`-99,-100,-89,-88` LTE; `-74,-76,-78,-76` NR) — either a 4×4 port is dead or the ODU is mis-aimed. A tile that shows per-chain balance + a divergence alert turns an invisible install fault into a ticket. Bonus: the 4 `signal_*` GPIO LEDs are writable [E], so an installer can aim the ODU by watching bars with no browser — the single cheapest way to improve field throughput. |
| **4** | **A real shaper (CAKE/HTB) on the 15 Mbps uplink**, with a per-client fair queue or a latency-first profile. | **easy–medium** | Everything is present and unused: `CONFIG_NET_SCH_CAKE/HTB/TBF/FQ_CODEL/PRIO/NETEM/INGRESS=y`, `cake_qdisc_ops` in kallsyms, `/sbin/tc` works, defaults are already `mq`+`fq_codel`. The uplink (15 Mbps, [09]) is the scarce resource; bufferbloat on a 1-core LTE ODU is exactly what CAKE fixes, and CAKE at 15 Mbit on one core is a rounding error of CPU *if* applied once (not re-forked per tick). Neither vendor nor QManager offers prioritisation. |
| **5** | **Per-client data accounting + quota enforcement/alerts.** | **medium** | Only an *aggregate* sampler exists [D 09]. `iptables-legacy` + `nf_conntrack` are present [E], and the existing 1 Hz sampler already has the tick to piggyback on. Prepaid buckets are small; "which client ate the balance" is the #1 support question, and it pairs naturally with #1. |
| **6** | **WAN-outage supervisor with proof of recovery.** | **medium–hard** | [29](../29-wan-drops-and-band-switching.md) proved the 2–60 s outage is the dialer's own 50–60 s watchdog tick, with **no external lever** (CGEREP no-op, CGACT hangs, `start_dialer restart` is an empty case). The remaining option is a supervised `killall -9 dialer; dialer &` after N seconds of "no bearer", with a verification gate and a hard cap. Worth it because the customer's dominant complaint is the one-minute outage — but it is the riskiest item on this list and must be gated behind AGENTS §5 rule 4. |
| **7** | **IPv6 / dual-stack bring-up (escape CGNAT).** | **medium–hard** | `+CGDCONT` already has cid 1 as `IPV4V6`, but the *active* context (cid 6) is `IP` only and `rmnet_data0` has **no global IPv6** — only link-links on `bridge0`/`eth0` [E]. Jazz runs IPv6. A global v6 address removes the CGNAT blind spot for inbound reachability and makes #2 partially unnecessary. Blocked by the dialer owning the context ([29] §"what does NOT help"), so it needs either the vendor's own dual-stack switch or a PDA/PDN-request path — hence hard. |
| **8** | **PLMN/operator lock and band policy through the vendor CGI**, not through our AT shim. | **medium** | Vendor ships `lockPlmn`/`sccan_plmn`/`ecgiLock`/`lockBand`; `AT+COPS=?` blocks and aborts the dialer so our own shim must never scan [04]. At band edges in Pakistan the ODU can squat on a weak PLMN; an operator lock (plus the existing `+CSYSSEL` band choice) is real value. Design rule: proxy the vendor CGI, keep single-flight, never issue a scan concurrently with the poller. |
| **9** | **GNSS position + time as a management datum.** | **medium (unverified)** | Kernel `[gps]` thread, `simcom_gnss` daemon and a live `/dev/gps` exist [E] — somebody believes there is a GNSS antenna. If it produces a fix: "is this ODU where the map says it is", install audit, and a time source that survives the RTC being set late (the wall clock is only correct after boot). One bounded read settles it; do not assume. |
| **10** | **Thermal + modem-skin telemetry in the dashboard.** | **easy** | 43 thermal zones, ~7 genuinely populated (`cpuss-0-usr` 38 °C, `modem-skin-usr` 34.6 °C, `modem-ambient-usr` 35.1 °C), trips at 115/125 °C [E]. QManager shows a single "temperature". A pole-mounted ODU in a Pakistani summer is a thermal story; correlating skin/ambient with throughput throttling is a cheap, credible feature that needs no modem write. |
| **11** | **Audit and reconcile the vendor's midnight timers.** | **easy (defensive)** | `triggerBkScan.timer`, `triggerChanPrefQuery.timer`, `triggerTopologyOpt.timer` all fire at **00:00** [E]. Background scans and topology optimisation can move the serving cell, distort signal history, and collide with any scan feature we add. Understanding them is a prerequisite for #8 and a credibility item on its own. |
| **12** | **A durable telemetry/log ring on `/cache`.** | **easy** | journald does not persist (AGENTS §6) and `/cache` is **292 MB of unused writable space** [E]. A ring buffer of serving cell / RSRP / per-chain / WAN events would have answered several past investigations (the "which tower did it drop on" question) that had to be reconstructed from poller samples. Cheap in CPU (append on the existing tick), and it makes every other item on this list debuggable in the field. |

**Deliberately not on the list** (the ceiling says no): WiFi anything, eSIM/LPA,
dual-SIM failover, network slicing, NR-SA cell lock/persistence, MBN profile
selection over AT, FPLMN via `CRSM`, IP-passthrough via `ql_qmap`, USB host
features, and any multi-cell tower lock.

---

## 5. Security posture — what must not be widened

Current listeners on the box, measured this session [E]:

```
:80/:443   /bin/mini_httpd (root, vendor UI, 0777 cgi)      V7/V20
:23        busybox telnetd -l /bin/sh  (root, NO AUTH)      V3 — LIVE NOW
:8080      busybox httpd  → QManager (root, no auth)        V5   (ours)
:989       tpws (DPI proxy)                                 ours
:8443/:8444 x16-webrtc                                      ours
:7777      qmi_ip_multiclient                               vendor
:22        dropbear                                         ours/needed
```

Two things worth stating loudly:

1. **The unauthenticated root telnet is back.** `ps` shows
   `busybox telnetd -l /bin/sh` (pid 3284) listening on `:::23`, and `mdlcfg`
   still holds the payload: `TZ_DMZ_DEST_IP = 127.0.0.1;busybox telnetd -l /bin/sh`,
   `TZ_ENABLE_DMZ = yes`. This is exactly [19](../19-vulnerability-assessment.md)
   V1/V2 still unremediated — the *record* was removed earlier, the *payload* was
   not. **Remediate before adding any feature**: `killall telnetd`,
   `mdlcfg -a TZ_ENABLE_DMZ=no`, `mdlcfg -a TZ_DMZ_DEST_IP=127.0.0.1`,
   `mdlcfg -c`, and disable the DMZ iptables file.
2. **Every new feature is a new injection candidate on a root HTTP plane.** The
   vendor CGI runs as root and V8 lists PPTP/GRE/DDNS/AT/port-filter as
   shell-injection candidates; the AT console page (`manage/sysAt`) is a
   root-privileged AT passthrough in the UI. The three rules that follow:
   no new listeners; no user string interpolated into a shell command (the
   USSD/SMS features are the obvious new exposure — validate every digit and
   reject everything else); and never expose the AT write commands
   (`+SIMEI=`, `+CNV=`, `+CNVR=`, `+CCELLCFG=`, `+CUSD=`, `+CMGS`) without an
   allowlist and a rate limit.

Also note the vendor surfaces that should stay **off**: TR-069 (armed but latent,
auto-upgrade, V11), ADB (USB-gadget only via `AT+CUSBCFG=USBADB`, so it is
contained — keep it that way), and the `wlan` PSK JSON in the docroot (V16, moot
here because there is no radio, but the file is still served).

---

## 6. One-line ceiling verdict

This ODU is a **single-core, 646 MB, no-WiFi, no-USB-host, one-port 2.5 GbE LTE/5G-NSA
bridge with full QoS, full VoLTE/IMS, working USSD, SMS, 4 real antenna chains,
8 writable LEDs, a live hardware-offloaded IPA path and 292 MB of unused flash** —
and it is **already CPU-saturated at ~15 % attributable load**. The ceiling is not
the modem (the SIM8260E over-delivers: VoLTE, USSD, 4 chains, n41 NSA) and not RAM
or flash. The ceiling is **one core and a boot chain that hides `/etc` from
systemd**, so the only affordable new features are *small, event-driven, on-demand
or 1-minute-timer* things that reuse the existing guards — with USSD balance,
SMS command, antenna-chain health and a real CAKE shaper as the four best-value
candidates that need no new hardware, no new port and no risky modem write.
