# GAP-01 — Vendor web UI feature inventory (ZLT X16 @192.168.3.1:80, `/tzwww`)

**Purpose.** A complete, evidence-backed list of every feature the *original vendor* UI
exposes, the exact backend mechanism behind each one, whether it is real or dead **on this
ODU**, and whether QManager (:8080) has an equivalent. This is the input to the
"what should QManager grow next" decision — not a port plan.

Read-only recon. Nothing on the device was modified. Every claim below is tied to a
command in §18 or to a file in the pulled tree.

---

## 0. Sources (all pulled 2026-10-26, read-only)

| Source | Local copy | Notes |
|---|---|---|
| `/tzwww/html` | `/tmp/scout-vendor/html` (193 files) | 13 sections + `home.html` |
| `/tzwww/js` | `/tmp/scout-vendor/js` (222 files) | `main.js` holds `RequestCmd` (189 ids), `MenuItem` (81 routes) |
| `/tzwww/index.html`, `login.html`, `home.html` | `/tmp/scout-vendor` | |
| `/tzwww/cgi-bin/http.cgi` | `/tmp/scout-vendor-cgi/http.cgi` | sha256 `7d996ad9…aa1025` — **ELF, statically linked, app strings obfuscated** (see §2) |
| `/tzwww/cgi-bin/http.cgi.bak` | `/tmp/scout-vendor-cgi/http.cgi.bak` | sha256 `8ad00e41…4fa5b6` — ELF PIE, `with debug_info, not stripped`, built from `SDX65_LE12_AP` (**same platform**). Contains the plaintext string table, function symbols and backend paths → used as the reference implementation map |
| live config | `/productinfo/tzcfg/main_config` + `mdlcfg -g <KEY>` | the device's own capability/key-value store |
| QManager tree | `/tmp/qm` (`QM_SRC`) | 51 `app/**/page.tsx` routes + `scripts/www/cgi-bin/quecmanager/**` (87 CGI endpoints) |

Two caveats stated up front, because they change how the inventory should be read:

1. **`main_config` is the default template, `system_config.use` + `mdlcfg -g` are live.**
   Where the two disagree I quote the `mdlcfg -g` value and say so (e.g.
   `USR_TR069_SW`: `main_config`=1, live=0).
2. **The UI is one firmware for many models.** `/tzwww` ships pages for WiFi variants,
   IPTV, eSIM/OneNET and a WAN-over-WLAN variant that this ODU does not have. Those are
   marked *dead* only with device evidence (§3), never by guesswork.

---

## 1. One request contract for the whole UI

```js
// js/main.js
Url.DEFAULT_CGI = "/cgi-bin/http.cgi"
RequestCmd = { SYS_INFO:0, ..., DEVICE_SELF_CHECK:484 }      // 189 ids
Page.postJSON({json:{cmd:N, method:"GET"|"POST", sessionId:"…", language:"EN", subcmd:n, …}})
```

* **Single endpoint** `/cgi-bin/http.cgi`, one JSON envelope in, one JSON out.
  `Page.postJSON` (`main.js:39133`) injects `method` (default `GET`), `language` and
  `sessionId` (from `sessionStorage`) if absent. Everything is `POST` +
  `Content-Type: application/json`-ish; `dataType:"text"`, parsed client-side.
* **Auth**: `POST {cmd:100 LOGIN, username, passwd}` where the client sends
  `passwd = sha256(token + sha256(pw))`; the server answers
  `Set-Cookie:sessionId=%s; SameSite=Strict; path=/; HttpOnly` and keeps
  `/tmp/.sessionId`, `/tmp/.auth_sessionId`. Without a valid session every command
  returns an **empty body** (verified, §18) — only the envelope check is pre-auth
  (`{"success":false,"cmd":-1,"message":"SessionId parameter is missing"}`).
* **Three account levels** (`SYS_USER_*` / `SYS_SENIOR_*` / `SYS_SUPER_*` in
  `main_config`): level 1 sees everything incl. the raw AT page, 2 is senior, 3 is the
  plain admin the customer gets. `home.js` builds the sidebar from `pageHideCheck(id)` /
  `pageHideCheck2(id)` against `INIT_PAGE.web_page_hide`.
* **HTML is fetched through the same CGI**: `GET_HTML:50` returns a page fragment,
  `GET_FILE_DATA:204` returns file bytes, `GET_HTML` is how `Page.getHtml()` loads
  `html/**` into the iframe. So even *static* page serving is CGI-mediated.

### Backend mechanism families found behind the cmds

| Family | How it shows up | Examples |
|---|---|---|
| **tzcfg key/value store** | `get_single_config_attr` / `set_config_attr` on `/productinfo/tzcfg/main_config`; keys `USR_*`, `SYS_*`; CLI on device is **`mdlcfg -g/-s <KEY>`** | every setting page (`USR_DHCP_LAN_IP`, `SYS_VOLTE_SW`, …) |
| **Shell + `iptables` helper scripts** | CGI writes a rule file to `/productinfo/tzcfg/iptables/<name>` then runs the matching helper; 24 helper names are in the `.bak` string table | `iptables_other` (port forward), `iptables_mac_filter`, `iptables_url_filter`, `iptables_pcl_speed_limit` … |
| **`/tmp/cmdlib/*` command channels** | JSON request files dropped for a resident daemon | `vpn_mgr`, `iptables`, `sms`, `ddns` |
| **Resident daemons (all verified running)** | `QCMAP_ConnectionManager`, `dialer`, `atcmd_daemon`, `sms_mgr`, `lan_mgr`, `vpn_mgr`, `flow_ctrl`, `parent_control`, `firewalltools`, `configtools`, `wlan_services`, `diag-router`, `tz_phone` | |
| **AT modem commands** | via `/bin/atcmd` (the same gate QManager wraps) | band/cell/PLMN lock, PIN, USSD, CFUN (flight mode), slicing, SCG |
| **`/sys`, `/proc`** | direct reads/writes | ARP aging (`gc_stale_time`), route table, mount info |
| **Upload/download endpoints** | `UPDATE_PARTIAL:106` (multipart), `CONFIG_EXPORT:180`, `CONFIG_UPDATE:184`, `EXPORT_LOG:241` | firmware upload, config backup/restore |

---

## 2. Note on `http.cgi`

The shipped `http.cgi` (468 680 B) is a static ELF whose `.rodata` carries **no plaintext
application strings**: `success`, `sessionId`, `cmd`, `tcpdump`, `iptv`, `esim`, `AT+`,
`/tmp/` are all absent from the binary while it demonstrably emits
`{"success":false,…,"message":"SessionId parameter is missing"}` at runtime. The string
table is obfuscated (only glibc strings survive). `http.cgi.bak` (2 188 384 B) is the
*same product line* built from `SDX65_LE12_AP` with DWARF and 773 `T` symbols, and it
still carries `web_page_hide`, `iad_ready_status`, `wifi_show_display_config`, `aeraId`,
`/productinfo/tzcfg/…`, the `iptables_*` helper names and the `/tmp/cmdlib` paths. All
"mechanism" columns below are derived from the `.bak` (reference) plus the client JS
(which is the authority for cmd ids/param names) plus on-device verification of the
backend artefact.

---

## 3. Device facts that decide real vs dead

| Fact | Evidence (§18) | Consequence |
|---|---|---|
| **No WiFi radio at all** | `/sys/class/net` = `bridge0 dummy0 erspan0 eth0 gre0 gretap0 ip6gre0 ip6tnl0 lo rmnet_data0-5 rmnet_ipa0 sit0 teql0 tunl0`; `/proc/net/wireless` header only; no `wlan*` module in `/proc/modules`; no `/lib/modules/**/*wlan*`; **`/sys/class/ieee80211` empty** (class exists, zero PHYs), **no `/sys/bus/sdio`**; `/etc/config/wireless` = 0 bytes; dmesg `QCMAP:WLAN_Ex attach not Found` | every 2.4G/5G/WPS/MAC-filter/Mesh page is **dead**; `wlan_services` runs but has nothing to drive |
| **No TR-069 agent** | no `cwmpd`/`cwmptool` in `/bin /sbin /usr/bin /usr/sbin`; page + `USR_TR069_*` config exist (`USR_TR069_ACS_URL=http://acs.isp.nawras.om:7547/`, live `USR_TR069_SW=0`) | TR-069 page is real *configuration*, but nothing acts on it |
| **No `tcpdump`** | not in `/usr/bin`,`/usr/sbin`, not a busybox applet | vendor "Packet capture"/"Remote packet capture" pages are dead |
| **`snmpd` IS present** | `/bin/snmpd` → `NET-SNMP version: 5.9.1` | SNMP page is real |
| **`miniupnpd` IS present** | `/usr/sbin/miniupnpd` + `/etc/initscripts/start_miniupnpd` | UPnP page is real |
| **`ipsec` (strongswan), `pppd`, `ddclient`, `ezmesh`, `traceroute`, `tc`, `siproxd`** present | §18 | IPSec/PPTP/L2TP/GRE/VXLAN/L2TPv3, DDNS, QoS, SIP are real *mechanisms* |
| **Kernel has `CONFIG_VXLAN=y`, `CONFIG_L2TP_V3=y`, GRE** | `/proc/config.gz` | VXLAN/L2TPv3/GRE pages are mechanically viable |
| **`bridge0` has `vlan_filtering`** | `/sys/class/net/bridge0/bridge/vlan_filtering` | VLAN page real |
| **Live switches** | `mdlcfg -g`: `SYS_VOLTE_SW=1`, `USR_VOIP_SW=0`, `USR_VOICE_TYPE=1`; `USR_PARENTAL_CONTROL_SW=1`; `SYS_GNSS_SW=1`; `USR_NR_BAND_LOCK_SW=1`, `SYS_LTE_CA_SW=1`, `SYS_NR_CA_SW=1`; `USR_FWT_SW=1`; `SYS_ESIM_SW=0`; `SYS_ONENET_CAPBILITY=`(empty); `SYS_FOTA_FUNCTION=0`/`USR_FOTA_SWITCH=0`; `SYS_ADB_SWITCH=0`, `SYS_TELNET_SWITCH=0`; `USR_DDNS_SW=0`; `USR_TR069_SW=0` | decides which "real" pages are actually *useful* today |
| **A telnetd is running that nothing enables** | `ps` → `busybox telnetd -l /bin/sh`; `SYS_TELNET_SWITCH=0`; `/productinfo/tzcfg/iptables/iptables_dmz_function` contains `{"enabled":"1","ip":"127.0.0.1;busybox telnetd -l \/bin\/sh"…}` | **stored command injection through the DMZ IP field** (already in `docs/19`); also proof the DMZ backend is a shell call with an unvalidated `ip` |

The **page-hide bitmap is a role mask, not a capability mask**:
`USR_WEB_PAGE_HIDE="1010000c00…40000001"` (live, 168 flags) decodes via
`parseHexPageHide`+`pageHideCheck` to levels 1/2/3 per page id, e.g. `29:1` IP-passthrough,
`31:1`/`57:1` VPN, `100,101,102:1` voice, `153:3` parent-control, `162:1` SCG,
`237` unset (self-check → level-1 only), `95` (MESH) unset. It tells us who *sees* a page,
not whether the hardware supports it.

**Reachability model.** `home.js` pushes 61 `MenuBody` entries into 10 menu heads
(`dashboard info wan wifi device data sms fw manage ussd`). Everything else is
reachable only through an `*Index.html` tab host. Routes that exist in `MenuItem`
(n=81) but are never pushed and never hosted are **orphans** (see per-section notes):
`DISPLAY_SOLUTION_MODE`, `ESIM_MANAGE`, `ONENET_SETTING`, `SLICE_CONIFIG`, `IPV6_CONFIG`,
`NETWORK_SERVICE`, `MODULE_LOG`, `LTE_AT`, `LTE_LOCK_FREQUENCY*`, `CHECKING_STATUS`,
`SYS_CHECK`, `FAIL_MESSSAGES`, `CLOSED_MANAGEMENT`, `FW_MAC_FILTER`, `FW_URL_FILTER`,
plus 8 `MenuItem` entries whose HTML does not exist in this build
(`html/config/ipv6Config.html`, `html/config/networkServiceConfig.html`,
`html/ddns/ddnsIndex.html`, `html/config/greVpn.html`, `html/config/pptpVpn.html`,
`html/check/checkIndex.html`, `html/manage/moduleLog.html`, `html/info/failInfo.html`,
`html/manage/closeManage.html`).

---

## 4. Section `advance/` (menu head `device_menu`, gate 49 → "Advanced" + VPN/DDNS tabs)

| Feature | Vendor page | Mechanism (cmd / params / backend) | Real on this ODU (evidence) | QManager |
|---|---|---|---|---|
| Band lock (NR + LTE) | `advance/lockBand.html` (`ADVANCED_CONFIG` tab) | `LOCK_BAND:161`, `band5gSwitch`, `supportAll5gArrayList`, `lockBandAll5gArrayList/index` → AT via dialer; masks `USR_NR_LOCK_BAND_MASK=20000000018000000081`, `USR_LTE_LOCK_BAND_MASK=2A0000800D5` | **real** — masks live, `USR_NR_BAND_LOCK_SW=1`, `SYS_LTE_CA_SW=1` | `cellular/cell-locking/frequency-locking` |
| Physical cell (PCI/EARFCN) lock | `advance/lockPhyCell.html` (`ADVANCED_CONFIG` tab) | `LOCK_PHY_CELL:160`, `FREQ`, `PCI`, `lte_lock_freq`, `lte_lock_pci`, `FREQ_5G` → AT | **real** (`docs/captures/recon-detail-metrics.md`) | `cellular/cell-locking/tower-locking` |
| DDNS | `advance/ddns.html` (`ADVANCED_CONFIG` tab) | `DDNS_DATA:221`, `ddnsStop`, `ddns`, `list`; `/tmp/cmdlib/ddns`, `*_login_status`; `/usr/sbin/ddclient`; `USR_DDNS_*` | **real**, currently off (`USR_DDNS_SW=0`); no daemon at rest → CGI spawns `ddclient` | **MISSING** |
| ARP aging | `advance/arp.html` (`routeIndex` tab) | `SET_ARP_AGING:258` → `/proc/sys/net/ipv4/neigh/<if>/gc_stale_time` (live 60) | **real** | **MISSING** |
| Auto dial / reconnect | `advance/autoDial.html` | `AUTO_DIAL:222` (+`DATA_SWITCH:227`, `clickConnect`) → dialer | **real** (`USR_NW_AUTO_DIAL=1`) | **MISSING** (no redial policy) |
| Mobile data on/off | `advance/dataSwitch.html` | `DATA_SWITCH:227` → dialer | **real** | **MISSING** |
| Flight mode (CFUN) | `advance/flight_mode.html` | `FLIGHT_MODE_INFO:226` → AT+CFUN | **real** (`USR_NW_AIRPLANE_MODE_ENABLE=0`) | **MISSING** |
| Data roaming | `advance/roaming.html` | `DATA_ROAMING:220` → `USR_DATA_ROAMING_SW` | **real** (live 0) | **MISSING** |
| GRE tunnel | `advance/gre.html` (VPN tab) | `GRE_SETTING:260`, `greSwitch`, `serverAddress`, `greTunnel`, `peerIp`, `greIP`; `/etc/initscripts/gre.sh`; `gre0` netdev exists | **real** | **MISSING** |
| L2TPv3 | `advance/l2tpv3.html` (VPN tab) | `L2TPV3_CONFIG:279`, `GET_L2TPV3_STATUS:398`; `/productinfo/tzcfg/l2tpv3_parameter_config_file`; `CONFIG_L2TP_V3=y` | **real** | **MISSING** |
| VXLAN | `advance/vxlanSetting.html` (VPN tab, `vpnIndex.js`) | `VXLAN_SETTING:332`, `vxlanSwitch`, `tunnelName`, `vni`, `dstport`, `remoteIP` → `vpn_mgr` | **real mechanism** (`CONFIG_VXLAN=y`, `ip` supports it) — no menu entry, reachable only as VPN sub-tab | **MISSING** |
| IP passthrough | `advance/ipPass.html` | `IP_PASSTHROUGH:251`, `ipPassMac`, `ipPassFlag`, `mode`, `looseMac` → `SYS_IP_PASSTHROUGH_{SW,MAC,MODE}` | **real**, currently off (`SYS_IP_PASSTHROUGH_SW=0`) | `local-network/ip-passthrough` |
| PLMN lock list | `advance/lockPlmn.html` | `LOCK_PLMN:219`, `addPlmn`, list → AT (COPS) | **real** | partial — `cellular/settings/fplmn-settings` is the *opposite* (forbidden) list |
| Manual PLMN scan/register | `advance/sccan_plmn.html` (`NETWORK_SET` tab) | `SCCAN_PLMN:228`, `sccan_plmn`, `plmn_select_cmd`, `plmn`, `act` | **real** | partial — `cellular/cell-scanner/neighbourcell-scanner` scans cells, not PLMNs |
| WAN mode / broadband / static-IP WAN | `advance/netChange.html` (`NETWORK_SET` tab) | `NETWORKMODE_SWITCH:277`, `BROADBAND_SETTING:302` (`LinkMode,IpVersion,IpMode,MTU,MRU,IpAddr4,Submask4,Gateway4,FirstDns4,SecDns4,NatEnable,UserName,PassWd,MacClone`), `GET_AROUND_SSID:412`, `WAN_WLAN_MODE:285` | **real** (router/bridge/broadband modes); the WLAN-WAN (`wlan_wan.html`) part is **dead** (no radio) | partial — `cellular/settings/network-priority`; **no static-IP/broadband WAN form** |
| Network-set host | `advance/networkSet.html` | `NETWORKSET_MODE_MT2731:256` (MT2731-specific build) | dead here (no MT2731) | n/a |
| Network mode + roaming + autodial host | `advance/networkConfig.html` | `NETWORKSET_MODE:218` → same keys as above | **real** | partial |
| SIM PIN/PUK | `advance/pinSet.html` | `MODEM_CMD:51` (`pin`,`puk`,`subcmd` 2/3), `QUERY_SIM_STATUS:134` (`pin_left_times`,`puk_left_times`) → `atcmd` | **real** (also the boot "SIM locked" overlay in `home.js`) | **MISSING** (only `sim_registry.sh`/`slot_verify.sh`, no PIN UI) |
| Remote web/management allow-list | `advance/remoteLogin.html` | `WEB_LIST:323`, `ipLists`, `remoteLoginPort`, `enableRemoteLogin`, `typeFlag` → tzcfg ACL | **real** | **MISSING** |
| Route table + static routes | `advance/route.html` (+`arp.html`) | `ROUTER_TABLE:164`, `LAN_INFO:208`, `btnAddRoute` → `ip route`, `/productinfo/tzcfg/iptables/apply_user_config_route` | **real** | **MISSING** |
| SIM card type / slot switch | `advance/simChange.html` | `CHANGE_CARD_TYPE:246` → AT | real mechanism, single-SIM (`SYS_SIM_SLOT_CONFIG=0`) | n/a |
| SNMP agent | `advance/snmpSetting.html` | `SNMP_SETTING:344`, `authPass`,`privPass`,`onAuthTypeChange`,`onPrivTypeChange` → **`/bin/snmpd` (net-snmp 5.9.1)** + tzcfg | **real** (agent present; menu gate 120 = level-1 only) | **MISSING** |
| TR-069 / ACS | `advance/tr069.html` | `TR069_CONFIG:212`, `tr069_object`, `apnSetting`, `tr069AuthType` → `USR_TR069_*` (ACS `acs.isp.nawras.om:7547`, CPE port 7676, `device_simcom5g.xml` data model) | **config real / agent absent** — no `cwmpd`; live `USR_TR069_SW=0` | **MISSING** |
| SIM network unlock | `advance/unlock.html` | `UNLOCK_SIM:340`, `locknck`, `getPLMNData` → AT | real mechanism, `SYS_LOCK_SIM_SW=0` | **MISSING** |
| VPN hub (PPTP / L2TP / IPSec entry) | `advance/vpn.html` (`vpnIndex` tab) | `VPN_CONFIG:272`: `vpnMode`,`lac_*`,`lns_*`,`lac_challenge_pass`,`lns_challenge_pass` → `vpn_mgr` (`/usr/bin/vpn_mgr`, running), `/etc/initscripts/{pptp.sh,start_l2tp,ipsec.sh}`, `pppd` | **real** | **MISSING** (`monitoring/tailscale` only) |
| eSIM download/manage | `advance/esimManage.html`/`esimIndex` | `GET_ESIM_INFO:247`, `RESET_ESIM_INFO:249`, `DOWNLOAD_ESIM_INFO:250` (QR render) | **dead** — `SYS_ESIM_SW=0`, no `lpac`/esim binary, no menu entry | n/a |
| OneNET (China IoT cloud) | `advance/onenet.html` | `ONENET_SETTING:252`, `onenetSwitch`, `level` | **dead** — `SYS_ONENET_CAPBILITY` empty, no binary, no menu entry | n/a |
| 5G network slicing | `advance/sliceConfiguration.html` | `SLICE_CONIFIG:254`, `dnn`, `sliceEnabled`, `apnUser` | **dead** — no menu entry, no slice switch in tzcfg | n/a |
| Solution/"display mode" preset | `advance/displaySolutionMode.html` | `DISPLAY_SOLUTION_MODE:235` | **dead** — no menu entry | n/a |
| ECGI/PCI lock + PCI scan range | `advance/ecgiLock.html` | page calls `RequestCmd.GET_ECGI_LOCK` / `SET_ECGI_LOCK` / `GET_PCI_CELL_LIST` / `SET_PCI_SCAN_RANGE` — **none of these exist in this build's `RequestCmd`** (`grep ECGI js/main.js` → 0) so it posts `{"cmd":undefined}` | **dead (broken client)** | n/a — QManager's tower-locking covers the intent |
| IPTV / multicast VLAN | `advance/iptv.html` | `GET_IPTV_SETTINGS`/`SET_IPTV_SETTINGS` — **undefined in `RequestCmd`**, no menu entry (only locale strings) | **dead** | n/a |
| WAN MAC clone page | `advance/wanSettings.html` | `WAN_MAC_GET`/`WAN_MAC_SETTINGS` — **undefined**, orphan | **dead** (MAC clone is instead a field on `BROADBAND_SETTING`, `MacClone`) | n/a |
| ICMP-ping allow-list | `advance/remotePin.html` | `GET_PING_LIST`/`SET_PING_LIST` — **undefined**, orphan | **dead** | n/a |

## 5. Section `config/`

| Feature | Vendor page | Mechanism | Real / dead | QManager |
|---|---|---|---|---|
| APN profiles | `config/setting_apn.html`, `setting_apn1.html`, `setting_apn2.html` | `APN_CONFIG:213` (`apnName`,`apn_list`,`selectAuth`,`ue`,`apnMTU`,`apnNat`,`select_type`), `MULTI_APN_INFO:130` (`multiApnNum`), `APN_INFO_PROCESS:248` → dialer; `USR_APN_*` (+`_1` VoIP APN!) | **real** — 2 APN slots, APN #1 is `Voip` (IMS APN) | `cellular/settings/apn-management` |
| LAN / DHCP server | `config/dhcpSetting.html` (`dhcpIndex`) | `NETWORK_CONFIG:3` (`lan_names`,`lan_values`), `STATIC_LEASE:115`, `IP_MAC_BINDING:24`, `APPLY_FILTER:20` → `lan_mgr`; `USR_DHCP_{LAN_IP,SUBNET_MASK,START_IP,END_IP,LEASE_TIME,PRIMARY_DNS,RESERVATION_IP/MAC,MTU,MSS}` | **real** | **MISSING** — `local-network/ethernet` only shows link status/speed |
| VLAN per port | `config/vlanSetting.html` | `MUTIL_VLAN_CONFIG:290`, `getPortList` → `SYS_BRIDGE_VLAN_MASK`, `ip link` vlan on `bridge0` (`vlan_filtering` present) | **real** | **MISSING** |
| WAN link detection | `config/wanLinkDetectSetting.html` | `WAN_LINK_DETECT_SETTING:336`, `listBase`, `action` → ping probe list | **real** | **MISSING** (`monitoring/watchdog` + `settings/ping_profile.sh` are adjacent but not the same) |
| Data traffic limit + SMS warning | `config/trafficLimit_settings.html` | `FLOW_STATISTICS:355` (`usr_set_used_flow_switch`,`usedPercent`,`flowALL`,`smsSw`), `SMS_SETTING:16` → `flow_ctrl` (running); `SYS_FLOW_STATISTICS_*`, `SYS_FLOW_WARNING_SMS_{SWITCH,PHONE}`; `/tmp/traffic.info` copied into tzcfg | **real** | partial — `network/data_used.sh` + `cellular/history` gives a cap/alerts, **no SMS warning**, no per-period reset UI parity |
| 5G SCG limit | `config/scg.html` | `SCG_SETTING:418` (`scgSwitch`,`scgValue`,`checkATSTR`) → AT; `USR_YOCTO_ORCA_SCG_LIMIT_SW=1`, `…_AT_STR="2,60,1800,5,3,120,1800,5"` | **real** (menu gate 162 set) | **MISSING** |
| 2.4G/5G SSID + security | `config/mainWifiSetting.html`, `setting_24wifi_1..4`, `setting_5wifi_1..4`, `main5gWifiSetting.html` | `WIRELESS_CONFIG:2`, `WIRELESS5G_CONFIG:211` (`ssid24G`,`ssid5G`,`cipherSuite`,`passType`,`showPsw`,`getwifiData`) | **dead** — no radio (§3) | n/a |
| WiFi advanced (WMM, max clients) | `config/wlan24gAdvance.html`, `wlan5gAdvance.html` | `WIRELESS_ADVANCE:230`, `WIRELESS5G_ADVANCE:231` (`wifiWmmVal`,`maxNum`,`butAble`) | **dead** | n/a |
| WPS (PBC/PIN, regenerate) | `config/wirelessWpsSetting.html`, `wireless5gWpsSetting.html`, `wpsPinCode.html` | `WPS_CONFIG:132`, `WPS_PIN_CODE:243`, `OPEN_RANDOM_PIN:244`, `SET_WPS_SUCCESS_FLAG:325`; shell `echo %d > /tmp/wsc_pin_regenerate && touch /tmp/wsc_2g` | **dead** | n/a |
| WiFi client MAC filter | `config/wifiList24g.html`, `wifiList5g.html` | `WIRELESS_MACFILTER:278` (`macfilter`,`maclist`,`addMac`,`Sync5g`) → `/productinfo/tzcfg/wifi_{white,black}_mac_list` | **dead** | n/a (QManager `network/ethernet.sh` also has a *wired* speed limit — different) |
| 5G TPC (TX power) | `config/wlan5gTpc.html` | `WLAN_5G_TPC:242` (`tpcSwitch`) | **dead** | n/a |

## 6. Section `dashboard/`

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Dashboard (signal gauge, net type, connect/disconnect, data used, SIM state) | `dashboard/dashboard.html` (`dashboardIndex` host, menu head only for `main.mtn.css`+`aeraId NG0131`) | `GET_DASHBOARD_INDEX:401` (`gnalValue`,`signal_lvl`,`connectStatus`,`RSRP_5G`) + `WIRELESS_CONFIG`/`NETWORKSET_MODE`/`AUTO_DIAL`; `get_dashboard_index()` in the CGI | **real** | `dashboard` ✓ |

## 7. Section `firewall/` (menu gate: `FW_SWITCH` always; rest gated by 61–67,85,118,38,39 — **most set in the live bitmap**)

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Firewall master switch | `firewall/fw_switch_setting.html` | `FW_SWITCH_SETTING:367` (`fw_switch`) + `APPLY_FILTER:20` → `iptables_default` enable/disable | **real** | **MISSING** |
| DMZ | `firewall/dmz.html` | `NETWORK_SERVICE:172` subcmd 6 (`dmzSwitch`,`ip`), `GET_DMZ:214` → writes `/productinfo/tzcfg/iptables/iptables_dmz_function` then shells out | **real** — file exists on device and contains an **injected `busybox telnetd`** in the `ip` field (stored command injection) | **MISSING** |
| Port forwarding (DNAT) | `firewall/portMapping.html` | `OTHER_FILTER:27` (`redirectAddrValue`,`portStartValue`,`portEndValue`,`redirectPortValue`,`ProtocolValue`,`isApply`) → `iptables_other`; `GET_SYSTEM_PORT:400` | **real** | **MISSING** |
| Port filter | `firewall/portFilter.html` | `PORT_FILTER:21` → `iptables_port_filter` | **real** | **MISSING** |
| IP+port filter | `firewall/ipFilter.html` | `IP_PORT_FILTER:32`, `DEFAULT_FILTER:28` → `iptables_ip_port_filter` | **real** | **MISSING** |
| MAC filter | `firewall/macFilter.html` | `MAC_FILTER:23` → `iptables_mac_filter`; default policy `MAC_DEFAULT_FILTER:30` | **real** | **MISSING** |
| URL / domain filter | `firewall/urlFilter.html` | `URL_FILTER:26` (`urlKeyword`,`advancedOptions`), `URL_DEFAULT_FILTER:29` → `iptables_url_filter` | **real** | **MISSING** (SmartDNS is not a URL filter) |
| Default rule policy (accept/reject all) | `firewall/default.html`, `default2.html`, `defaultMac.html` | `DEFAULT_FILTER:28`, `URL_DEFAULT_FILTER:29`, `MAC_DEFAULT_FILTER:30` (`acceptAllIPv4`,`acceptAllIPv6`,`ipv4FilterRule`) | **real** | **MISSING** |
| IP↔MAC binding | `firewall/ipMacBinding.html` | `IP_MAC_BINDING:24` (`addIpMacBinding`,`saveListMacIp`,`lanDiv`) → `iptables_ip_mac_binding` | **real** | **MISSING** |
| Static ARP binding | `firewall/staticArpBinding.html` | `STATIC_ARP_BINDING:216`, `ARP_BINDING:83` → `/productinfo/tzcfg/static_arp_binding` + `ip neigh` | **real** | **MISSING** |
| Per-host speed limit (QoS) | `firewall/speedLimit.html` | `SPEED_LIMIT:25` (`maxSpeed`,`kBPerSeconds`,`ipv4`,`ipv6`) → `/productinfo/tzcfg/qos_speed_limit_rules` + `iptables_speed_limit`/`tc` (`/sbin/tc` present) | **real** | **MISSING** |
| UPnP IGD + mapping table | `firewall/upnp.html` | `FW_UPNP_STATUS:333` parses `iptables -S -t nat \| grep MINIUPNPD`; `UPNP:202`/`FW_UPNP:215` → `miniupnpd` | **real** | **MISSING** |
| DDoS protection | `firewall/ddos.html` | `DDOS_PROTECTION:275` (`ddosSwich`,`ackFloodSwich`) → `/etc/initscripts/ddos.sh` + iptables | **real** (this repo already runs `ddos.sh` from `StartTZApp`) | **MISSING** |
| Simple access control (LAN web login / ICMP from WAN, 5 IP allow rules) | `firewall/accessControl.html` | `FW_ACCESS_CONTROL_SIMPLE:345` (`enable_web_login_from_lan_sw`,`enable_icmp_from_lan_sw`,`ip1..ip5`,`action`) → `iptables_filter_acl_rules` | **real** | **MISSING** |
| Remote web port (HTTP/HTTPS) | `firewall/remoteWebPortSetting.html` | `REMOTE_WEBPORT_SETTING:334` (`remotePort`,`remoteHttpsPort`) → tzcfg + restart `mini_httpd` | **real** (two `mini_httpd` instances run: `:80` and `:443`) | **MISSING** |

## 8. Section `info/`

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| System/network summary | `info/sysInfo.html` (`wan_index` tab) | `SYS_INFO_NETWORK:205` (`names_sysInfo`,`values_sysInfo`) | **real** | partial — `about-device` / `dashboard` |
| WAN status | `info/wan_info.html`, `wan1_info.html`, `wired_wan.html` | `ROUTER_INFO:133`, `MULTI_WAN_INFO:291` (`apnInfo`) | **real** (single PDP; the "multi-WAN" table has one row) | partial — `dashboard`, `cellular` |
| LAN status + clients | `info/lan_info{,1,2}.html`, `dhcpConnected.html` | `LAN_INFO:208`, `DHCPCLIENT_INFO:223` → `lan_mgr`, `/tmp/cmdlib/.all_devices_connected_via_wifi_list_file_for_web` | **real** | **MISSING** — QManager has no connected-clients/DHCP-leases page |
| Device/version info | `info/deviceInfo.html` | `DEVICE_INFO:207`, `INIT_PAGE:80` (`SYS_HW_MODEL=ZLT X16`, `SYS_AERA_ID=OMN247`, `SYS_CFG_VER=X16-OMN247-4.00`) | **real** | `about-device` ✓ |
| Calibration / mount info | `info/calibrationInfo.html` | `GET_MOUNT_INFO:274` (`mount_info`,`ListInfo`) — level-1 only | **real** | **MISSING** |
| WiFi status/clients (4 SSIDs × 2 bands) | `info/wifi24g*_info.html`, `wifi5g*_info.html`, `wireless{,5g}Connected.html` | `WIRELESS_CONFIG:2`, `WIRELESS5G_CONFIG:211`, `WIFI24G_LIST_INFO:224`, `WIFI5G_LIST_INFO:225` | **dead** — no radio | n/a |

## 9. Section `manage/`

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| System log viewer | `manage/sysLog.html` | `SYS_LOG:17` → `/productinfo/tzcfg/websys.log` (31 KB, live) + `/data/log` | **real** | `system-settings/logs` ✓ |
| Log level/size policy | `manage/logInfo.html` | `LOG_INFO:322` (`logGrade`,`logSize`) → `SYS_LIBCOMMLOG_{LEVEL,MAX_FILE_SIZE,BAKUP_*}` + `web_event*.log` | **real** | partial — `logs` |
| Config backup / restore (upload) | `manage/exportLog.html` | `EXPORT_LOG:241` (`exportCfg`,`exportDelegate*`), `CONFIG_EXPORT:180`, `CONFIG_UPDATE:184` → `/tzwww/cfg_export_config_file.conf` | **real** — the export file is in the docroot right now | **MISSING** — no backup/restore in QManager |
| USSD | `manage/ussd.html` (`USSD_SET`, gate 131 set) | `USSD_SEND:350` (`decodeMessage`,`hex2char`) → `atcmd` AT+CUSD | **real** | **MISSING** |
| AT command terminal | `manage/sysAt.html` | `SEND_AT:270`, body `Base64.encode(atCmd)` → `atcmd`; **menu only for level 1** | **real** | `system-settings/at-terminal` ✓ |
| Device self-check | `manage/deviceSelfCheck.html` | `DEVICE_SELF_CHECK:484` (gate 237 unset → level-1 only) | real mechanism, hidden for the customer login | `system-settings/system-health-check` ✓ (different checks) |
| Easymesh / topology | `manage/meshSetting.html`, `meshAdvSetting.html` | `MESH_SETTING:314` (`ssid24G`,`ssid5G`,`meshable`,`dK`,`dKey`), `NETWORK_TOPOLOPY:315` → `ezmesh` (`/usr/sbin/ezmesh` present) | **dead** — QCA SON needs a radio; `/etc/config/ezmesh` `Enable '0'`; no `wlan*` netdev | n/a |

## 10. Section `parentControl/`

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Per-device internet-time / URL / speed limits for kids | `parentControl/parentIndex.html` → `kidsDevice.html`, `deviceManage.html` | `PARENT_CONTROL:397` + `DHCPCLIENT_INFO:223`; `/productinfo/tzcfg/parent_control_json` (0 B); rules applied by `iptables_pcl_{internet_time_limit,url_filter,speed_limit,ip_port_filter}`; **`parent_control` daemon is running**; `USR_PARENTAL_CONTROL_SW=1` | **real and enabled** (menu gate 153 = level 3, i.e. the customer admin sees it) | **MISSING** |

## 11. Section `sms/`

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Inbox / read state / delete | `sms/smsInbox.html` | `SMS_INFO:12` (`subcmd`,`page_num`), `sms_list` base64 grammar, `SMS_DELETE:14`, `SMS_DELETE_ALL:15` → `sms_mgr` (running), store `/data/sms` | **real** — see `docs/captures/recon-sms.md` for the full contract | `cellular/sms` ✓ |
| Compose / send | `sms/smsNew.html` | `SMS_SEND:13` (`phoneNo`,`content`,`sms_list`) | **real** | `cellular/sms` ✓ |
| Outbox | `sms/smsOutbox.html` | `SMS_INFO:12` + `SMS_SEND` | **real** | partial (QManager shows a single thread view) |
| SMS centre/validity, status report, unread counter in header | `sms/smsSetting.html` | `SMS_SETTING:16`, `GET/SET_SMS_STATUS_REPORT:125/126`; `home.js` polls `SMS_INFO` for `unreadTotal` | **real** | partial — `cellular/sms/forwarding` exists, SMSC/status-report settings do not |
| Data-cap SMS warning | (inside traffic limit) | `SYS_FLOW_WARNING_SMS_SWITCH`, `SYS_FLOW_WARNING_PHONE` + `/usr/sms_send` | **real** | **MISSING** |

## 12. Section `sys/` (all under `SYS_SET` → `sysConfigIndex.html`, plus the manage-menu items)

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Change admin password | `sys/changePasswd.html` | `CHANGE_PASSWD:102` (`old_passwd`,`newPasswd` base64, `firstLogin`), `LOGOUT:101` | **real** | `auth/password.sh` ✓ |
| Change username | `sys/changeUsername.html` | `CHANGE_USERNAME:98` → `SYS_USER_LOGIN_NAME` | **real** | **MISSING** |
| NTP / timezone / sync client time | `sys/timeSetting.html` | `SET_DATETIME:11` (`timeServerValue`…`timezoneValue`), `SYNC_CLIENT_TIME:321`, `WRITE_TIME:170`; `USR_NTP_TIMEZONE=UTC-4`, `USR_NTP_SERVER=cn.pool.ntp.org`; `time_daemon` running | **real** | **MISSING** — no time/NTP page |
| DST rules | `sys/dstSettings.html` | `DST_SETTING:351` (`daylightSw`,`dst_start_*`,`dst_end_*`) | **real** | **MISSING** |
| Scheduled reboot / weekly timer | `sys/timeToRestart.html` | `TIME_TO_RESTART:263` (`restartHour`,`restartMinute`,`restartWeek`,`restartMode` → `USR_TIMER_REBOOT_*`) | **real** | **MISSING** (`reboot` page is immediate only) |
| Telnet service toggle | `sys/service.html` | `SYS_SERVICE_SET:234` (`telnetValue`,`telnetValue2`) → `SYS_TELNET_SWITCH` + `busybox telnetd` | **real** — live `SYS_TELNET_SWITCH=0` yet a telnetd **is** running (DMZ injection, §3) | **MISSING** |
| ADB toggle | `sys/adbSwitch.html` | `ADB_SWITCH:237` → `SYS_ADB_SWITCH` + `/etc/initscripts/start_adb`, `/etc/adb_devid` | **real** (live 0) | **MISSING** |
| Modem log switch | `sys/modemlogSwitch.html` | `MODEM_LOG_SWITCH:236` → `SYS_MDL_LOG_SW`, `/tmp/cmdlib/.reboot_module_log` | **real** | partial — `logs` |
| SFP/IPA acceleration ("Net acceleration") | `sys/netAcceleration.html` | `SFP_IPA_SETTING:255` (`sfpIpaSwitch`) → IPA offload toggle | **real** — this is the IPA box (`docs/18`) | **MISSING** |
| Phonebook | `sys/phoneBook.html` | `SET/GET/DEL_PHONE_BOOK:360/361/362` (`homeNumber`,`officeNumber`,`email`,`group`,`page_num`) | real mechanism (gate 165 unset → level-1 only) | **MISSING** |
| Unusual-reboot watchdog switch | `sys/sysUnormalRebootSwitch.html` | `UNORMAL_REBOOT_SWITCH:328` → `SYS_REBOOT_WHEN_MODEM_UNORMAL` | **real** (live 0) | **MISSING** |
| Restore factory defaults | `sys/restoreFactory.html` | `RESTORE_DEFAULT:112` (`rebootType`) | **real** | **MISSING** |
| TR-069 logging switch | `sys/tr069Log.html` | `TR069_LOG_SWITCH:268` → `SYS_LIBCOMMLOG_MOD_EN_TR069` | config only (no agent) | n/a |
| Auto remote-config update | `sys/remoteConfigUpdate.html` | `ONLINE_UPGRADE_AUTO:196` | **real** | **MISSING** |

## 13. Section `tools/` (`toolsIndex.html`)

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Ping | `tools/ping.html` | `NETWORK_TOOLS:168` subcmd ping; `killall -SIGINT ping` to stop; `/bin/ping` | **real** | partial — `web-console`/`monitoring/latency` |
| Traceroute (tracepath) | `tools/tracepath.html` | `NETWORK_TOOLS:168` subcmd traceroute; `/usr/bin/traceroute` present | **real** | **MISSING** |
| Packet capture (live tcpdump) | `tools/tcpdump.html` | `NETWORK_TOOLS:168` subcmd tcpdump; `killall -SIGINT tcpdump` | **dead** — no `tcpdump` binary, no busybox applet | **MISSING** (and would need a payload) |
| Remote packet capture (upload to server) | `tools/restoreFactory.html` (mis-named file) | `REMOTE_PACKET_CAPTURE:245`, `REMOTE_PACKET_VERIFY_PASSWORD:354` (`portBinding`,`checkPassword`) | **dead** — same missing `tcpdump` | **MISSING** |
| Diagnostic socket (DAIG) | `tools/daigSocket.html` | `DAIG_SOCKET:390` (`socketIp`,`socketPort`,`socketSw`) → `diag-router` (running) | **real** | **MISSING** |

## 14. Section `update/`

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| Local firmware update (upload) | `update/sysUpdate.html` | `SYS_UPDATE:5`, `UPDATE_PARTIAL:106` (`updateType`,`fileName`, multipart), `INPUT_8198D_LOGIN:229`; images staged in `/data/fw_*` | **real** — see `docs/21-fota-and-update-channels.md` | partial — `system-settings/software-update` updates *QManager*, not the ODU firmware |
| Online version check / auto upgrade | `update/sysAutoUpdate.html` | `DETECTION_VERSION_INFO:238`, `UPGRADE_IMMEDIATELY:239`, `SYS_AUTO_UPGRADE:240`, `/tmp/cmdlib/.tzupdate_result`, `/usr/web_sysupdate_time` | **real** | **MISSING** |
| FOTA (carrier/cloud) | `update/fota.html` | `FOTA_SETTINGS:373` → `/usr/sbin/fota` + `/etc/initscripts/start_fota` (`mdlcfg -g USR_FOTA_SWITCH`) | real mechanism, **disabled** (live `USR_FOTA_SWITCH=0`, `SYS_FOTA_FUNCTION=0`) | **MISSING** |

## 15. Section `voice/` (`voiceIndex.html`; menu gate 100/101/102 set)

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| VoLTE / SIP account provisioning (reg address, port, domain, proxy, alt server, keepalive, SRV) | `voice/vioceBasicConfig.html` | `VOICE_BASIC_CONFIG:295` (`altRegAddress`,`volteSw`,`voice_prefer`,`ims`,`pdpType`,`volteRegStatus`) → `USR_VOIP_*` / `USR_VOLTE_*`; live values point at **`ims.ooredoo.om`**, proxy `bosbc.ims.ooredoo.om:5060` | **real** — `SYS_VOLTE_SW=1`, `USR_VOICE_TYPE=1`, `tz_phone` running, `/etc/TzConfig.ini` present, `siproxd` installed | **MISSING** — QManager's `cellular/calls` is *our* WebRTC/PCM bridge, it does not provision SIP |
| Voice codec / DTMF / RTP range / TOS | `voice/voiceAdvanceConfig.html`, `voipAdvancedSettings.html` | `VOICE_ADVANCE_CONFIG:294`, `VOIP_ADVANCED_CONFIG:297` (`dtmfMode`,`rtpPortStart/End`,`sipTos`,`rtpTos`,`expireDuration`,`sessionDuration`,`minSe`,`firstCompressionType`,`echoCancellation`) | **real** (`USR_VOIP_DTMF_MODE=1`, RTP 60000-61000, TOS 184) | **MISSING** |
| Call barring / forwarding / DND prefixes | `voice/voipCall.html` | `VOIP_CALL_CIPHER:298` (`noAnswerEnable`,`noAnswerPrefix`,`busyEnable`,`disturbEnable`,`barringEnablePrefix`,`internationalSuffix`) | **real** | **MISSING** |

## 16. Section `vpn/` (reached through `advance/vpnIndex.html`, i.e. VPN menu)

| Feature | Page | Mechanism | Real | QManager |
|---|---|---|---|---|
| IPSec (IKEv1/v2, PSK, proposals, DPD, lifetimes) | `vpn/ipSec.html` | `IPSEC_CONFIG:281` (`ikeVersion`,`ikeEncrypt`,`ikeDic`,`preshare`,`ikeGroup`,`ikeLifeTime`,`ikeDpdSwitch`,`dpd*`,`lifeTime`,`encrypt`,`dic`,`group`) → `/tmp/cmdlib/vpn_mgr/ipsec.status`, `/usr/sbin/ipsec` (strongswan), `/etc/ipsec.conf`, `/etc/ipsec.d`, `/etc/ipsec.secrets` | **real** | **MISSING** |
| IPSec tunnel status | `vpn/ipSecStatus.html` | `IPSEC_CONFIG:281` (GET) + `VPN_ONLY_ONE:425` (single-tunnel constraint) | **real** | **MISSING** |

---

## 17. Top 10 highest-value vendor features QManager is missing

Ranked by (what the customer gains) ÷ (backend work), given the mechanism found above.
"Work" is the honest size of the QManager-side job *on this device*, reusing the
existing `qcmd`/AT gate and `cgi_base.sh` conventions.

1. **Firewall: port forwarding + DMZ + firewall switch** — the single biggest functional
   hole; a CPE without DNAT is not a router for any customer with a camera or NAS.
   Backend is plain `iptables` (`iptables_other`, `iptables_dmz_function`) driven from a
   JSON rule list; no modem involvement, no AT. **Work: medium** (3 pages + one rule-file
   writer + idempotent `iptables` apply; the vendor schema is already in front of us —
   copy its field list, not its shell-injection).
2. **LAN DHCP server + reservations + connected-clients list** — vendor exposes
   `NETWORK_CONFIG:3`, `STATIC_LEASE:115`, `DHCPCLIENT_INFO:223` (`lan_mgr` + dnsmasq).
   QManager currently shows eth0 link speed only. **Work: medium-small** (edit
   `/etc/dnsmasq.conf`-style state + leases file read; QManager already has endpoint
   conventions and a poller).
3. **Per-host speed limit / QoS + traffic limit with SMS warning** — `SPEED_LIMIT:25` is
   `tc`/iptables rule files; `flow_ctrl` is already running for the data cap and
   `SYS_FLOW_WARNING_SMS_*` triggers an SMS through the existing `sms_mgr`. QManager has
   a data cap but no per-client control and no SMS warning. **Work: medium**.
4. **Parental control (per-child internet time / URL / speed)** — `parent_control`
   daemon is *running and enabled* on this box (`USR_PARENTAL_CONTROL_SW=1`) and its
   input file `/productinfo/tzcfg/parent_control_json` is empty ⇒ the whole feature is
   available and unused. Backend = write that JSON + the daemon applies
   `iptables_pcl_*`. **Work: small-medium** (a form and a JSON writer, no new daemon).
5. **VPN set: IPSec (+ PPTP/L2TP/GRE)** — `vpn_mgr` + strongswan + `pppd` are installed
   and wired at boot; QManager offers Tailscale only. Even read-only tunnel *status*
   (`/tmp/cmdlib/vpn_mgr/ipsec.status`) plus IPSec profile CRUD would be a large win.
   **Work: medium-large** (strongswan config generation is the real cost).
6. **USSD** — `cmd 350` → one `atcmd` `AT+CUSD` exchange with hex/GSM-7 decode. Prepaid
   customers on this box need it (balance checks). **Work: small** (one CGI + one page;
   the AT plumbing already exists in `atcmd`).
7. **SIM PIN/PUK state + unlock** — `MODEM_CMD:51` / `QUERY_SIM_STATUS:134` expose
   `pin_left_times`/`puk_left_times` and PIN change; today a SIM-locked device is a
   dead box with no QManager path to fix it. **Work: small** (2 AT commands).
8. **Scheduled reboot + NTP/DST/timezone** — `TIME_TO_RESTART:263`, `SET_DATETIME:11`,
   `DST_SETTING:351`. QManager has no time page at all and no reboot scheduler, while the
   device ships `time_daemon`, `ntp.sh` and a reboot daemon. **Work: small**.
9. **Config backup / restore** — `EXPORT_LOG:241`/`CONFIG_EXPORT:180`/
   `CONFIG_UPDATE:184`. Every field deployment needs "save this working config"; QManager
   has nothing. Since QManager owns `/etc/qmanager`, its own export is cheap; the vendor
   export file already exists as a format reference. **Work: small-medium**.
10. **Remote-web-port + LAN access-control allow-list (+ telnet/ADB toggles)** —
    `REMOTE_WEBPORT_SETTING:334`, `FW_ACCESS_CONTROL_SIMPLE:345` (`ip1..ip5`),
    `SYS_SERVICE_SET:234`, `ADB_SWITCH:237`. Cheap to implement, and it is the natural
    place to *close* the vendor's own exposure (a telnetd is currently running because
    of the DMZ injection). **Work: small**.

Runners-up deliberately not in the top 10: SNMP (`snmpd` is present but carrier-facing),
TR-069 (agent is missing, so page parity buys nothing), band/PLMN/PCI lock (QManager
already covers the valuable half), DDNS and VXLAN (real but low demand), SMS
centre/status-report settings (partial parity exists), phonebook/diagnostic-socket/
calibration (operator tools).

**What QManager should *not* chase:** the entire 2.4G/5G/WPS/Mesh cluster, IPTV, eSIM,
OneNET, network slicing, `ecgiLock`, `wanSettings`, `remotePin`, and the tcpdump pages.
They are dead on this ODU for hardware/firmware reasons documented in §3, or their client
code is already broken in the shipped build.

---

## 18. Evidence index (commands actually run)

```sh
# tree + CGI pull (retry loop; scp unusable)
ssh zlt-root 'cd /tzwww && tar cf - html js index.html login.html version.json' | tar xf - -C /tmp/scout-vendor
ssh zlt-root 'cat /tzwww/cgi-bin/http.cgi'     > /tmp/scout-vendor-cgi/http.cgi      # sha256 7d996ad9…aa1025
ssh zlt-root 'cat /tzwww/cgi-bin/http.cgi.bak' > /tmp/scout-vendor-cgi/http.cgi.bak   # sha256 8ad00e41…4fa5b6
ssh zlt-root 'sha256sum /tzwww/cgi-bin/http.cgi'          # matches local pull (no transfer corruption)

# strings / symbols of the reference build
strings -n 5 http.cgi.bak | grep -E 'sessionId|Set-Cookie:sessionId|/productinfo/tzcfg|iptables_|/tmp/cmdlib'
llvm-nm http.cgi.bak | grep ' T ' | wc -l                 # 773 functions
strings http.cgi.bak | grep -c 'SDX65_LE12_AP'            # same platform as this ODU

# cmd id / param / route extraction from the shipped client
node -e '...RequestCmd from js/main.js...'                # 188 ids -> /tmp/scout-vendor/cmdmap.txt
node -e '...MenuItem table from js/main.js...'            # 81 routes -> /tmp/menuitem.txt
node /tmp/scan.js                                         # per-page cmds -> /tmp/pagescan.json
node /tmp/params.js                                       # per-cmd JSON params -> /tmp/params.txt
grep -o 'new MenuBody("[A-Z0-9_]*"' js/home.js | sort -u   # 61 menu entries

# envelope / auth contract
grep -o 'JSONMethod={[^}]*}' js/main.js                   # GET|POST
grep -c 'sessionId' /tmp/scout-vendor-cgi/bak.strings.txt
curl -s -X POST -d '{"cmd":113,"method":"GET"}' http://127.0.0.1/cgi-bin/http.cgi
#   -> {"success":false,"cmd":-1,"message":"SessionId parameter is missing"}
curl -s -X POST -d '{"cmd":113,"method":"GET","sessionId":""}' http://127.0.0.1/cgi-bin/http.cgi
#   -> HTTP 200 with an EMPTY body (auth required) => no live data could be pulled without a login

# real-vs-dead ground truth
cat /proc/net/dev ; cat /proc/net/wireless        # no wlan*; wireless header only
ls /sys/class/net; ls -la /sys/class/ieee80211; ls /sys/bus/sdio
#   -> no wlan* netdev; ieee80211 class present but EMPTY; sdio bus absent
cat /proc/modules | grep -iE 'wlan|qca|cnss|ath'  # none
wc -c /etc/config/wireless                        # 0
dmesg | grep -iE 'wlan|cnss'                      # 'QCMAP:WLAN_Ex attach not Found'
ps -o pid,user,args                               # 30+ daemons: dialer, atcmd_daemon, sms_mgr,
                                                  #   lan_mgr, vpn_mgr, flow_ctrl, parent_control,
                                                  #   firewalltools, diag-router, tz_phone,
                                                  #   wlan_services, mini_httpd(:80,:443)
for b in /usr/sbin/cwmpd /usr/sbin/snmpd /usr/sbin/miniupnpd /usr/sbin/tcpdump ...; do [ -e $b ] && echo YES $b; done
/bin/snmpd --version                              # NET-SNMP version: 5.9.1
zcat /proc/config.gz | grep -iE 'VXLAN|L2TP|GRE'  # CONFIG_VXLAN=y CONFIG_L2TP_V3=y
ls -l /productinfo/tzcfg/ /productinfo/tzcfg/iptables/
cat /productinfo/tzcfg/iptables/iptables_dmz_function
cat /productinfo/tzcfg/main_config
for k in USR_WEB_PAGE_HIDE USR_TR069_SW SYS_ESIM_SW SYS_VOLTE_SW ...; do mdlcfg -g $k; done
```

Local analysis artefacts kept for follow-up work (tmp, not committed):
`/tmp/scout-vendor/{cmdmap.txt,menuitem.txt,pagescan.json,params.txt,home.pretty.js,helper.pretty.js}`,
`/tmp/scout-vendor-cgi/{http.cgi,http.cgi.bak,bak.strings.txt,funcs.txt}`.
