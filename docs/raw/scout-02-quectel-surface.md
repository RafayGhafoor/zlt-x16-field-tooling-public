# Quectel / RM520N Surface Inventory — `/tmp/qm` (branch "greenpacket")

**Scope note first.** `/tmp/qm` is **not** a git work tree (no `.git`), and it is **not** the bare RM520N tree. It is `QManager-RM520N` **already ported once** to a GreenPacket O5A Pro (RG520N-EB, SDX55). A previous port therefore already established the seam: `deploy/` shims + `scripts/usr/lib/qmanager/{hw_profile,phy_metrics,qmi_read,parse_at}.sh`. A SIMCom SIM8260E port must move the same seam, but *further* — because SIMCom drops the **Qualcomm vendor layer** that GreenPacket kept (modemd, ql_qmap, qrtr/QMI, rmnet_ipa0, `4080000.qcom,mss` sysfs), not just the AT dialect.

Raw census (excludes `docs/`, `.orchestra/`, `.claude/`, `qm-diag-*.draft`, `native/qmanager_atd/tests/parity/`):

| Bucket | `AT+` occurrences |
|---|---|
| `scripts/` (shell + CGI) | 472 |
| `constants/` (TS registry) | 26 |
| `lib/` (TS helpers) | 10 |
| `app/` + `components/` + `types/` | 115 |
| **Total, all source roots** | **1055** |

Top files by density: `scripts/www/cgi-bin/quecmanager/cellular/apn.sh` (46), `scripts/usr/bin/qmanager_poller` (40), `scripts/usr/lib/qmanager/apn_apply.sh` (39), `scripts/www/cgi-bin/quecmanager/cellular/settings.sh` (36), `scripts/usr/lib/qmanager/parse_at.sh` (35), `scripts/debug_poller_at.sh` (31), `scripts/usr/bin/qmanager_watchcat` (26), `constants/at-commands.ts` (26).

**Commands genuinely NOT used** (do not list them as dependencies): `AT+QNWINFO`, `AT+QCSQ`, `AT+CESQ`, `AT+CLAC`, `AT+CSIM`, `AT+CCHO`, `AT+CGLA`, `AT+QDSIM`, `AT+QETH`, `AT+QMAPWAC`, `AT+QGDNRCNT`, `AT+CUSD`, `AT+CCLK`, `AT+QPOWD`, `AT+QINDCFG`. `AT+CSQ` (42) appears only in `scripts/usr/bin/qcmd_test` and docs — never in production paths.

---

## 1. AT command inventory by feature

| # | Feature | Count | Primary files (file:line) | Exact strings seen | Why it breaks on SIMCom SIM8260E | Difficulty |
|---|---|---|---|---|---|---|
| 1 | **Serving cell / signal** | `QENG` **165** | `qmanager_poller:1678` `'AT+QENG="servingcell"'`; `:1693` `T1_COMBINED='AT+QENG="servingcell";+QCAINFO=1;+QCAINFO;+QCAINFO=0'`; `parse_at.sh:145-438` (`parse_serving_cell`, awk over `/^[+]QENG:/`); `:1762` `AT+QRSRP;+QRSRQ;+QSINR` | `AT+QENG="servingcell"`, `AT+QRSRP`, `AT+QRSRQ`, `AT+QSINR` | SIMCom has **no `QENG`**. Signal comes from `AT+CESQ`/`AT+CSQ`/`AT+CPSI?`. The whole 300-line awk parser (`parse_at.sh:206-428`) keys on `+QENG:` field ordering incl. `NR5G SA`/`NR5G NSA` RAT tokens. Unusable, not tweakable. | **hard** |
| 2 | **Carrier aggregation** | `QCAINFO` **169** | `qmanager_poller:744` `CA_INFO_OFF='AT+QCAINFO=0'`; `:754` `CA_INFO_READ_ONCE='AT+QCAINFO=1;+QCAINFO;+QCAINFO=0'`; `:743-790` (`ca_ext_*`); `parse_at.sh:803` `parse_ca_info`; `types/modem-status.ts` | `AT+QCAINFO`, `AT+QCAINFO=1`, `AT+QCAINFO=0` | Quectel-only. No SIMCom equivalent with per-CC EARFCN/PCI/RSRP rows. Feature must be **removed or re-sourced** (SIMCom has no CA introspection AT). | **hard** |
| 3 | **Operator / registration** | `COPS` **174**, `CREG` 7, `CGREG` 5, `CEREG` 2, `QSPN` 8, `CNUM` 13 | `apn_apply.sh:261,453,467` (`AT+COPS=0/2` attach cycle); `qmanager_watchcat:302,304`; `poller:2053` `'AT+COPS?;+QUIMSLOT?;+CNUM;+QSIMSTAT?;+CPIN?'`; `parse_at.sh:565` `parse_carrier` | `AT+COPS?`, `AT+COPS=0`, `AT+COPS=2`, `AT+QSPN` | `COPS` itself is 3GPP-standard and survives. **`AT+QSPN` (8) is Quectel-only** — `parse_carrier` must fall back to `+COPS: <mode>,2,"<name>"`. The COPS=2/COPS=0 detach-attach re-attach primitive is standard but SIMCom needs a longer, differently-timed settle. | **easy–medium** |
| 4 | **Band locking** | `QNWPREFCFG` **112** | `bands/lock.sh:78` `AT_CMD="AT+QNWPREFCFG=\"${AT_PARAM}\",${BANDS}"`; `settings.sh:76,365,377,424`; `constants/at-commands.ts:43-103`; `band_failover:122,136,150`; `scenario_mgr.sh` | `AT+QNWPREFCFG="lte_band",…`, `="nr5g_band",…`, `="nsa_nr5g_band",…`, `="mode_pref",…`, `="nr5g_disable_mode",…`, `="roam_pref",…`, `="policy_band"` | `QNWPREFCFG` does not exist on SIMCom. SIMCom uses `AT+CNBP` (band preference bitmap) and/or `AT+CGDCONT`-adjacent vendor `AT+SIMCOMATCMD`. **Parameter names, value encodings (band-number CSV vs hex bitmap) and read-back shape all differ.** Also `mode_pref` → `AT+CNMP` (numeric enum). | **hard** (whole bands subsystem) |
| 5 | **Frequency / EARFCN lock** | `QNWCFG` **158** | `frequency/lock.sh:144` `AT+QNWCFG="lte_earfcn_lock",$count,$list`; `:166` `…,0`; `:273` `AT+QNWCFG="nr5g_earfcn_lock",…`; `:295`; `poller:1567,1570` `AT+QNWCFG="nr5g_mimo_layers"` / `"lte_mimo_layers"`; `:1590` `AT+QCFG="usbnet"` | `AT+QNWCFG="lte_earfcn_lock"`, `"nr5g_earfcn_lock"`, `"lte_mimo_layers"`, `"nr5g_mimo_layers"`, `"lte_ambr"`, `"nr5g_ambr"`, `"lte_csi"`, `"nr5g_csi"`, `"lte_ulMCS"`, `"nr5g_ulMCS"`, `"nr5g_dlMCS"`, `"rrc_state"`, `"nr5g_tx_pwr"`, `"ssb_beam_id"`, `AT+QCFG="usbnet"` | Entirely Quectel-vendor. `lte_earfcn_lock` has **no SIMCom analogue**; `QCFG="usbnet"` is Quectel USB-composition. Also `frequency/lock.sh:9` documents a Quectel-only mutual exclusion (`QNWCFG nr5g_earfcn_lock` ✗ `QNWLOCK common/5g`) that is meaningless elsewhere. | **hard** |
| 6 | **Tower (cell) locking** | `QNWLOCK` **103** | `tower_lock_mgr.sh:220` `AT+QNWLOCK="common/4g",$num`; `:305` `AT+QNWLOCK="common/5g",$pci,$arfcn,$scs,$band`; `:392` `AT+QNWLOCK="save_ctrl",$val,$val`; `:237,247,318,328,402` read/clear; `components/cellular/tower-locking/*.ts(x)` | `AT+QNWLOCK="common/4g"`, `="common/5g"`, `="save_ctrl"` | Quectel-only. SIMCom uses `AT+SLCELL`/`AT+SCELL`-family or `AT+SIMCOMATCMD`. The **entire tower-locking UI + 602-line lib + failover/schedule daemons** rest on this. | **hard** |
| 7 | **APN / PDP** | `CGDCONT` **72**, `CGCONTRDP` **80**, `QICSGP` **38**, `CGACT` 25, `CGAUTH` 3, `CGPADDR` 10 | `apn.sh:1-774`; `apn_apply.sh:443` `AT+CGDCONT=${_cid},"${_pdp}","${_apn}"`; `:481` `AT+CGCONTRDP=${_cid}`; `apn.sh` `AT+QICSGP=…` (17 sites); `parse_at.sh:1078` `parse_cgcontrdp`, `:1141` `parse_wan_ip` | `AT+CGDCONT?`, `AT+CGDCONT=<cid>,"IPV4V6","<apn>"`, `AT+CGCONTRDP`, `AT+QICSGP=<cid>,<ctx>,"<apn>",…`, `AT+CGACT`, `AT+CGAUTH` | `CGDCONT`/`CGCONTRDP`/`CGACT` are **standard and survive**. `AT+QICSGP` (auth, 38 sites) is Quectel-only → SIMCom uses `AT+CGAUTH` (already present at 3 sites, so the pattern exists). **The real break is semantic**: `apn_apply.sh:5-11` documents that only `COPS=2`→`COPS=0` makes the network accept a new APN; SIMCom's attach carriage and MBN interaction differ. Also `CGCONTRDP` response *quoting* differs (repo already has `.claude/agent-memory/modem-investigator/rg501q_cgcontrdp_unquoted_response.md` — same class of bug will reappear). | **medium** |
| 8 | **Cells / neighbours / scan** | `QSCAN` **36**, `QENG="neighbourcell"`, `QNWCFG="nr5g_meas_info"` | `neighbour_scanner:66` `qcmd 'AT+QENG="neighbourcell"'`; `:124` `qcmd 'AT+QNWCFG="nr5g_meas_info",1'`; `:128` read; `cell_scanner:1-280` `AT+QSCAN`; `at_cmd/send_command.sh:50-56` blocks `*QSCAN*` | `AT+QENG="neighbourcell"`, `AT+QNWCFG="nr5g_meas_info",1`, `AT+QSCAN`, `AT+QSCANFREQ` | All three Quectel-only. SIMCom's equivalent is `AT+CPSI?` / `AT+SQNSCFG`-family, with a **completely different row shape** (`+QENG:` vs `+CPSI:`). Cell Scanner page is effectively a new feature. | **hard** |
| 9 | **SIM identity / slot** | `CPIN` 23, `QCCID` 19, `CIMI` 26, `CNUM` 13, `QUIMSLOT` **53**, `QSIMSTAT` 12, `QSIMDET` 17, `QSIMCFG` 6 | `poller:1407` `'AT+CVERSION;+CGMM;+CGSN;+CIMI;+QCCID;+CNUM'`; `:1662` `'AT+CIMI;+QCCID'`; `:2053` compound; `watchcat:352` `AT+QUIMSLOT?`, `:401` `AT+QUIMSLOT=$CFG_BACKUP_SIM_SLOT`, `:381,467` `AT+QCCID`; `slot_verify.sh`; `settings.sh:76,465` | `AT+CPIN?`, `AT+CIMI`, `AT+QCCID`, `AT+CNUM`, `AT+QUIMSLOT?`, `AT+QUIMSLOT=<n>`, `AT+QSIMSTAT?`, `AT+QSIMDET`, `AT+QSIMCFG` | `CPIN`/`CIMI`/`CNUM` standard, survive. **`AT+QCCID`** → SIMCom `AT+ICCID` (different verb, **same payload**). **`AT+QUIMSLOT`** (53 sites!) → SIMCom has no dual-SIM-slot AT on SIM8260E in this form; the **entire SIM-failover / backup-SIM subsystem** (`qmanager_watchcat` Tier 3 + `slot_verify.sh` + `sim_registry.sh`) is at risk. `QSIMSTAT`/`QSIMDET`/`QSIMCFG` → no SIMCom equivalent (SIM hot-swap detection). | **hard** (slot) / **easy** (ICCID) |
| 10 | **SMS** | `CMGF` 4, `CMGS` 16, `CPMS` 35, `CMGL` 8, `CMGD` 9 | `cellular/sms.sh:504,618,753` `sms_locked at 'AT+CPMS="ME","ME","ME"'`; `sms.sh:441-470` `sms_tool send`; `qmanager_sms_forward:76-107`; `native/qmanager_atd/src/{sms.rs,channel.rs,pdu.rs}` | `AT+CPMS="ME","ME","ME"`, `AT+CMGF`, `AT+CMGS`, `AT+CMGL`, `AT+CMGD`, `sms_tool {-j recv, send, delete, status, at}` | **Mostly portable** — CPMS/CMGF/CMGS/CMGL/CMGD are 3GPP. Risk is operational, not syntactic: (a) `sms_tool` is a **statically-linked ARM ELF with no source in the tree** (patch only) — see §5; (b) `AT+CPMS="ME","ME","ME"` assumes exactly three storage slots with ME available; (c) `cmgs` PDU/`CSCA` defaults differ per vendor. | **easy–medium** |
| 11 | **IMEI** | `CGSN` 14, `EGMR` 15 | `cellular/imei.sh:121` `qcmd "AT+EGMR=1,7,\"${NEW_IMEI}\""`; `qmanager_imei_check:116`; `poller:1407` includes `+CGSN` | `AT+CGSN`, `AT+EGMR=0,7` (read), `AT+EGMR=1,7,"<imei>"` (write) | `AT+CGSN` standard, survives. **`AT+EGMR` is Quectel-only** → SIMCom uses `AT+SIMEI=<imei>` (or `AT+EGMR` unsupported). Write path + `reboot_required` flow must be rewritten. | **easy** |
| 12 | **MBN / carrier profiles** | `QMBNCFG` 14 | `cellular/mbn.sh:50` `'AT+QMBNCFG="AutoSel";+QMBNCFG="list"'`; `:181` `="AutoSel",0`; `:189` `="deactivate"`; `:197` `="select","<name>"`; `:224` | `AT+QMBNCFG="AutoSel"`, `="list"`, `="deactivate"`, `="select","<name>"` | Quectel-only. SIMCom equivalent is `AT+CRSM`-based MBN or absent entirely. Whole MBN page is Quectel-shaped. | **medium–hard** |
| 13 | **Temperature** | `QTEMP` 31 | `parse_at.sh:542` `parse_temperature`; `:476-481` documents `QTEMP` falls back to **`/sys/class/thermal`-equivalent sysfs** on RG520N-EB | `AT+QTEMP` | Already has a sysfs fallback (`parse_at.sh:476`). SIMCom often supports `AT+QTEMP` too, but the repo already treats it as optional → **lowest risk item in the table**. | **trivial** |
| 14 | **Version / model** | `CVERSION` 13, `CGMM` 48, `CGMI` 4, `CGMR` 1 | `poller:1407`; `parse_at.sh:661` `parse_version`; `qmanager_health_check:502` `AT+CGMI` | `AT+CVERSION`, `AT+CGMM`, `AT+CGMI`, `AT+CGMR` | `CGMM`/`CGMI`/`CGMR` standard. `AT+CVERSION` = 13 sites, **Quectel-only** → parse fails, no firmware string. | **easy** |
| 15 | **Data-used counter** | `QGDCNT` 14 | `poller:1100-1210` (`update_data_used`) — actually reads **`/proc/net/dev` on `rmnet_ipa0`**, `QGDCNT` only in docs/fixtures | `AT+QGDCNT` (docs), `rmnet_ipa0` (code) | **The counter is not AT at all** — `resolve_network_iface()` at `poller:110-112` **hardcodes `printf '%s\n' "rmnet_ipa0"`**. On SIMCom the WAN netdev is `wwan0`/`usb0`/`eth2`. `poller:96-107` warns the failure is **silent and permanent** (frozen plausible number). | **medium** (small code, big blast radius) |
| 16 | **IP passthrough** | `QMAP` 52 (mostly docs/`parse_at.sh:1224` `parse_ippt_mpdn_rule`) | `ippt.sh:36` `IPPT_QMAP="${IPPT_QMAP:-/usr/bin/ql_qmap}"`; `:108` `timeout -s KILL 20 "$IPPT_QMAP" LAN IPPT set 0 1 "$_mac"`; `:7` "WHY THIS IS NOT AT+QMAP" | `/usr/bin/ql_qmap LAN IPPT set 0 1 <mac>`, `/usr/bin/ql_qmap LAN IPPT adaptive 0 2` | Already moved off AT to a **Quectel vendor CLI binary** (`ql_qmap`) that will not exist on a SIMCom device. No equivalent. Feature must be dropped or rebuilt against the new vendor's QCMAP/`iptables` bridging. | **hard** (or drop) |
| 17 | **FPLMN** | `CRSM` 9 | `cellular/fplmn.sh` (9 sites) | `AT+CRSM=…` | Standard 3GPP SIM file access — **survives**; only the EF IDs read need checking. | **trivial** |
| 18 | **TTL / MTU** | n/a (no AT) | `ttl_state.sh:163-188` `run_iptables -w 5 -t mangle -D POSTROUTING -o rmnet+ -j TTL --ttl-set "$val"`; `:183-188` `-j HL --hl-set`; `tower_lock_mgr.sh:522,568` (`rmnet_data` MTU) | `iptables -t mangle -I POSTROUTING -o rmnet+ -j TTL --ttl-set <n>`, `-j HL --hl-set <n>` | Three separate breaks: (a) **`-o rmnet+`** is Qualcomm netdev naming; (b) the **`TTL`/`HL` iptables targets are `xt_HL`**, present in this Qualcomm kernel — may be absent from a SIMCom/MediaTek (likely) kernel; (c) `config.sh:34` default iface list `"br-lan,eth0,rmnet_data0,rmnet_data1,rmnet_ipa0"`. | **easy** (iface) / **medium** (target availability) |
| 19 | **PHY deep metrics (Tier 3)** | `QNWCFG` subset + `ubus` | `phy_metrics.sh:291` `QM_PHY_AT_LTE='AT+QNWCFG="lte_csi";+QNWCFG="lte_ulMCS";+QNWCFG="lte_dl_tx_mode";+QNWCFG="rrc_state"'`; `:292` `QM_PHY_AT_NR='AT+QNWCFG="nr5g_csi";…"nr5g_ulMCS";…"nr5g_dlMCS";…"nr5g_tx_pwr";…"ssb_beam_id"'`; `:232` `qm_phy_modemd` → `ubus call modemd status` | the two compound strings above + `ubus call modemd status` | **Purely Quectel + OpenWrt-ubus.** `nr5g_csi`, `nr5g_tx_pwr`, `ssb_beam_id` have no SIMCom analogue. `ubus`/`modemd` is an OpenWrt service daemon that does not exist on a stock SIMCom Linux BSP. `phy_metrics.sh:31-32` already records `lte_tx_pwr`/`nr5g_pathloss` as **absent on RG520N-EB** → the file already has a graceful-degradation pattern to copy. | **hard** (mostly drop) |

---

## 2. Transport layer

**Chain:** CGI/daemon → `qcmd` → `atcli_smd11` → `/dev/smd11` (upstream) / `/dev/at_mdm0` (this port).

| Layer | File:line | Contract |
|---|---|---|
| `qcmd` CLI | `scripts/usr/bin/qcmd:1-220` | `qcmd "AT+…"` → raw payload + `OK` on **stdout**; `ERROR: <code>` + `exit 1` on **stderr**. `qcmd -j` → `{"success":bool,"response"|"error","command"}`. `AT_CLI="/usr/bin/atcli_smd11"`, `AT_DEVICE="/dev/smd11"` (`qcmd:70-71`). |
| Lock | `qcmd:39` `LOCK_FILE="/tmp/qmanager_at.lock"`; `flock_wait()` `:116-131` | **Strictly single AT channel.** `LOCK_WAIT_SHORT=20` / `LOCK_WAIT_LONG=45` (`:53-54`); `is_long_command()` `:104-109` matches `*QSCAN*|*QSCANFREQ*|*QFOTADL*`. BusyBox `flock` has no `-w`, so it is a **1 s poll loop of `flock -x -n`** plus a final try. Lock is taken read-only (`9<"$LOCK_FILE"`) to survive `fs.protected_regular=1`. |
| Shim | `deploy/atcli_smd11:1-180` | `#!/bin/sh`, **not a binary**. One AT command in `$1`, raw text to stdout, **always exit 0**. `AT_DEV="${AT_DEV:-/dev/at_mdm0}"` (`:36`). Raw-char-device capture: background `dd if="$AT_DEV" of=…`, write via `printf '%s\r' \| dd of="$AT_DEV" bs=1` (`:104`). Budget `TICKS=240` (~60 s) for `*QSCAN*`/`*QFOTADL*`, else `TICKS=48` (~12 s) (`:44-47`). Participates in the vendor `atlock` at `/tmp/gp-radio.lock` (`:37`, `:52-58`) — **GreenPacket-specific**. |
| Rust broker (opt-in) | `native/qmanager_atd/src/{main.rs,channel.rs,lock.rs,proto.rs}` | `DEFAULT_AT_DEV="/dev/at_mdm0"` (`main.rs:62`), socket `/var/run/qmanager_atd.sock`, lock `/var/lock/qmanager.lock`. `channel.rs:1-2`: *"The AT channel (/dev/smd11). glink_pkt does the framing in the kernel, so this is plain read/write."* — **`glink_pkt` is a Qualcomm IPC-Router transport.** `channel.rs:20-29` terminator array is `+CME ERROR:`, `+CMS ERROR:`, `BUSY`, `ERROR`, `NO ANSWER`, `NO CARRIER`, `NO DIALTONE`, `OK` — **fully portable**. `deploy/qmanager-atd.service` exists but `[Install]` is deliberately disabled ("must NOT be enabled by default", hard rule 9). |

**Single-channel assumption — confirmed and load-bearing.** There is exactly **one** lock file, one device node, and one mutex across `qcmd`, `sms_tool`, and `qmanager_atd` (`at-command-transport.md`: *"wrapped with the same flock on `/tmp/qmanager_at.lock` … AT access is fully serialized across both tools"*). No code path opens two AT channels or selects a channel. Consequences for SIMCom:

- **`/dev/smd11` (464 hits) does not exist** on a SIMCom Linux BSP — the device is typically `/dev/ttyUSB2`, `/dev/ttyUSB3`, or `/dev/ttyHS0`, and those are **real TTYs requiring `termios` setup**. The `deploy/atcli_smd11` shim's core assumption — *"the port is a raw char device, not a tty"* (`:20-21`), `if (!isatty(port)) return;` in `sms_tool.patch` — **inverts**. The shim's `dd`-based capture would need `stty`/`termios` restore, and the "stale bytes" drain rationale (`:59-66`) changes.
- `ctypes` ordering: `qcmd` requires `AT+QSCAN` to block for 60 s inside one lock hold. On SIMCom, `AT+QSCAN`-equivalents may return immediately with a URC-style result → the long-command path becomes wrong.
- The Rust broker is the cheapest upgrade path (single file to port: `channel.rs` open + termios + drain).

---

## 3. Entware `/opt` hardcoding

**136 occurrences.** Distribution: `/opt/bin` 20, `/opt/sbin` 19, `/opt/bin/opkg` 15, `/opt/bin/timeout` 13, `/opt/bin/jq` 6, `/opt/bin/wget` 5, `/opt/share/zoneinfo` 5, `/opt/bin/sudo` 4, `/opt/sbin/dropbear` 4, `/opt/bin/curl` 4, `/opt/etc/sudoers.d` 3, `/opt/etc/sudoers.d/qmanager` 3, `/opt/etc/init.d/rc.unslung` 3, `/opt/bin/msmtp` 3, `/opt/etc/lighttpd/lighttpd.conf` 2, `/opt/etc/opkg.conf` 1.

Notable sites:
- `scripts/install_rm520n.sh:106-107` `OPKG="/opt/bin/opkg"`; `:129` `CONFLICT_PACKAGES="socat socat-at-bridge"`; `:573,786` guard on `opkg not available — skipping (pre-Entware)`; `:1043-1072` a **temporary `wget` shim** because *"Entware's opkg binary shells out to wget, hardcoded at build time"*.
- `scripts/usr/lib/qmanager/platform.sh:22-30`: sudo resolution order `/opt/bin/sudo` → `/usr/bin/sudo`; `:36` `_SYSTEMCTL="/bin/systemctl"`.
- `scripts/etc/sudoers.d/qmanager`, `scripts/etc/profile.d/qmanager-path.sh`, `scripts/etc/systemd/system/lighttpd.service` all pin `/opt`.
- `scripts/www/cgi-bin/quecmanager/monitoring/alerts.sh`, `usr/bin/qmanager_email_send` → `/opt/bin/msmtp`.

**Why it breaks:** `/opt` is Entware, mounted from the same ubi volume as `/usrdata` (`platform-matrix.md`: *"the reset wiped only the userdata volume (`/dev/ubi2_0`) — which backs `/etc`, `/usrdata` **and** `/opt`"*). A SIMCom device with no Entware has no `/opt` at all → `opkg`, `jq`, `timeout`, `sudo`, `curl`, `wget`, `lighttpd`, `dropbear` all vanish. **Difficulty: easy for path edits, medium for re-plumbing the installer's package bootstrap** (`install_rm520n.sh` is ~4,500 lines and its preflight is Entware-shaped).

---

## 4. systemd units

**Shipped:** 28 in `scripts/etc/systemd/system/` (`lighttpd`, `qmanager-*`, `tailscaled`); **6 services + 3 timers** in `deploy/` (the actual GreenPacket deployment set).

| Unit | Kind | Needs |
|---|---|---|
| `deploy/qmanager-atd.service` | service, **disabled by default** | `AT_DEV=/dev/at_mdm0`; `ExecStart=/usrdata/qmanager/bin/qmanager_atd`; `Before=qmanager-poller.service`; `ExecStopPost` rm `/var/run/qmanager_atd.{sock,proto,proto.new}` |
| `deploy/qmanager-poller.service` | service | `ExecStartPre=qm_fixperms.sh` then **`qm_wait_modem.sh 150`** (waits for a real AT answer, not just the node); `PATH=/usrdata/qmanager/bin:…`; `Restart=always`, `StartLimitBurst=20` |
| `deploy/qmanager-httpd.service` | service (forking) | `busybox httpd` on **:8080**; `PIDFile=/run/qmanager-httpd.pid`; `qm_fixperms.sh` pre; `qm_serve.sh start/stop` |
| `deploy/qmanager-ippt.service` | service | `qmanager_ippt_apply --boot`; waits up to 10 min for QCMAP + LAN client. **QCMAP = Qualcomm.** |
| `deploy/qmanager-ping.service` | service | `DNS_LAN_RESOLVER=192.168.0.1`; needs `jq`; writes `/tmp/qmanager_ping.json` |
| `deploy/qmanager-traffic.service` | service | `native/qmanager_traffic` (Rust) reading **`ethtool` ETHTOOL_GSTATS**; docblock says *"Qualcomm IPA forwarding bypasses `/proc/net/dev`"*. **No AT, no modem** → portable. |
| `deploy/qmanager-dns.service` | service | `smartdns` at `/usrdata/qmanager/bin/smartdns`; **boot guarantee via `deploy/qm_boot_hook.sh`** injecting `start_service_async qmanager-dns.service` into `turin_web.sh` (`turin_web.sh` is GreenPacket vendor). |
| `deploy/qmanager-dpi.service` | service | `tpws` binary; `iptables` nat REDIRECT + QUIC REJECT |
| `deploy/qmanager-dpi-ensure.service` | service (resident loop) | `--ensure-loop`, 60 s re-assert after **QCMAP flushes nat** |
| `deploy/qmanager-dns-edge.service` | oneshot | `qmanager_dns_apply apply-edge`, throwaway-port validation of `smartdns.conf` |
| `deploy/qmanager-dns-stats.service` | oneshot | `dnsmasq` SIGUSR1 counters → `/tmp/qmanager_dns_stats_history.json` |
| `deploy/*.timer` (3) | timers | **Monotonic only** (`OnBootSec`/`OnUnitActiveSec`, never `OnCalendar`) — `qmanager-dpi-ensure.timer` docblock: *"This SoC has no battery-backed RTC: it boots at Jan 1970 and the modem's time daemon steps the clock… every armed OnCalendar timer misfires twice."* **That RTC fact is a property of the SIMCom device too, likely — verify.** |

**Breakage classification:** `qmanager-atd`, `qmanager-poller`, `qmanager-httpd`, `qmanager-ping`, `qmanager-traffic`, `qmanager-dns*`(3) are **portable as-is** (path edits only). `qmanager-dpi*` need QCMAP knowledge re-verified. `qmanager-ippt` is **dead** (ql_qmap). All 3 timers survive; the RTC assumption in them must be re-measured on the SIMCom board.

---

## 5. Native binaries in `deploy/`

| Path | What it actually is | ELF | Linkage | Source in tree? |
|---|---|---|---|---|
| `deploy/atcli_smd11` (9,240 B) | **POSIX shell script**, not a binary (`file`: "POSIX shell script text executable") | — | — | **Yes** — the script itself |
| `deploy/sms_tool` (5,356 B) | **POSIX shell wrapper**; expects the real binary at `${SMS_TOOL_BIN:-/usrdata/qmanager/bin/sms_tool.bin}` | — | — | **Yes** — the wrapper |
| `dependencies/atcli_smd11` (661,616 B) | the real AT CLI | **ELF 32-bit LSB, ARM, EABI5, GNU/Linux 3.2.0** | **statically linked**, stripped | **NO.** Upstream = `1alessandro1/atcli_rust` (Rust); `deploy/README.md:16` — *"The binary **does not exist**, and `/dev/smd11` is owned by `modemd`"*. |
| `dependencies/sms_tool` (439,556 B) | SMS/PDU tool | **ELF 32-bit LSB, ARM, EABI5, GNU/Linux 3.2.0** | **statically linked**, stripped | **NO.** Upstream = `obsy/sms_tool`; only `dependencies/sms_tool.patch` (default `/dev/ttyUSB0` → `/dev/smd11`, `if (!isatty(port)) return;` guards) is in-tree. |
| `dependencies/qmi/bin/qmicli` (108,240 B) | libqmi CLI | **ELF 32-bit LSB PIE, ARM, EABI5** | **dynamically linked**, `/lib/ld-linux-armhf.so.3` | **NO.** Plus `libqmi-glib.so.5.10.0` + `libqrtr-glib.so.0.0.0` (LGPL-2.1, see `dependencies/NOTICE`). |
| `dependencies/smartdns/smartdns` | resolver | (not inspected) | — | **NO** |

**Porting consequence:** the only binary needing **replacement** is `atcli_smd11` — and it already has a *script* substitute in `deploy/`, so the cheapest path is to extend that script for a TTY device (termios open/restore) rather than recompile Rust. `sms_tool` needs a **rebuild from upstream + a new patch** (device default + `isatty` guard). `qmicli` is Qualcomm-only and becomes dead weight.

---

## 6. Ranked porting work list

### Tier 0 — trivial config / path edits (hours)
1. `AT+QCCID` → `AT+ICCID` (19 sites; identical payload). `scripts/www/cgi-bin/quecmanager/system/known_sims.sh`, `qmanager_watchcat:381,467`, `poller:1407,1662`, `parse_at.sh`.
2. `AT+QTEMP` → sysfs fallback already written (`parse_at.sh:476-481`); point it at the SIMCom thermal zone.
3. `AT+EGMR=1,7,"<imei>"` → `AT+SIMEI=<imei>` (2 write sites: `cellular/imei.sh:121`, `qmanager_imei_check:116`).
4. `resolve_network_iface()` → `rmnet_ipa0` (`poller:110-112`) → `wwan0`/`eth2`/`usb0`.
5. `ttl_state.sh` `-o rmnet+` (4 sites) → new netdev glob; verify `xt_HL` (`-j TTL`/`-j HL`) exists in the SIMCom kernel.
6. `/opt/*` → new prefix or `/usr/bin` (136 sites, mostly `install_rm520n.sh`, `platform.sh`, `sudoers.d`, `profile.d`).
7. `deploy/atcli_smd11` `AT_DEV` default + `$GP_ATLOCK` (`/tmp/gp-radio.lock`) → drop the GreenPacket lock participation.

### Tier 1 — easy rewrites (1–2 days)
8. `AT+CVERSION` (13) → `AT+CGMR` only; `parse_version` (`parse_at.sh:661`).
9. `AT+QSPN` (8) → parse operator name from `+COPS: <mode>,2,"<name>"` in `parse_carrier` (`parse_at.sh:565`).
10. `AT+QICSGP` (38) → `AT+CGAUTH` — pattern already exists at 3 sites.
11. Drop `ubus call modemd status` (`phy_metrics.sh:232-260`); keep the existing "source unavailable" degradation (`:31-32` precedent).
12. `AT+QNWPREFCFG="mode_pref"` → `AT+CNMP` (numeric enum mapping table).

### Tier 2 — medium (new code, same shape)
13. `AT+QNWPREFCFG="lte_band"/"nr5g_band"/"nsa_nr5g_band"/"policy_band"` (112) → `AT+CNBP` hex bitmap. **Rewrite `bands/lock.sh`, `bands/current.sh`, `constants/at-commands.ts:95-103`, `qmanager_band_failover`, `scenario_mgr.sh`.**
14. `AT+QNWCFG="lte_earfcn_lock"/"nr5g_earfcn_lock"` (frequency lock) → SIMCom equivalent or **feature removal**; `frequency/lock.sh:144,166,273,295` + `frequency/status.sh`.
15. APN attach semantics: re-validate `apn_apply.sh:5-27` (`CGDCONT`→`COPS=2`→`COPS=0`→`CGCONTRDP` timings `:93-101`) and `CGCONTRDP` quoting (`parse_cgcontrdp`, `parse_at.sh:1078`).
16. `AT+QENG="servingcell"` → `AT+CPSI?`/`AT+CESQ`. **Rewrite `parse_serving_cell` (`parse_at.sh:153-438`, ~300 lines of `+QENG:` awk).**
17. `AT+QRSRP;+QRSRQ;+QSINR` (per-antenna, `poller:1762`) → `AT+CSQ`/`AT+CESQ`; the *per-antenna* concept may not exist.
18. `AT+CPMS="ME","ME","ME"` (3 sites) → verify storage set; rebuild `sms_tool` from upstream with a new device/`isatty` patch.

### Tier 3 — hard (new feature, or removal)
19. **`AT+QUIMSLOT` (53) + `QSIMSTAT`/`QSIMDET`/`QSIMCFG`** → dual-SIM failover, `qmanager_watchcat` Tier 3, `slot_verify.sh`, `sim_registry.sh`. No SIM82xx equivalent → likely **remove the backup-SIM subsystem**.
20. **`AT+QNWLOCK="common/4g"/"common/5g"/"save_ctrl"` (103)** → tower locking + `tower_lock_mgr.sh` (602 lines) + `qmanager_tower_failover` + `qmanager_tower_schedule`/`_timer` + `components/cellular/tower-locking/*`. **Largest single subsystem at risk.**
21. **`AT+QCAINFO` (169)** → carrier aggregation. No SIMCom analogue → **remove** or re-source from a QMI-like path that SIMCom does not have.
22. **`AT+QENG="neighbourcell"` + `AT+QNWCFG="nr5g_meas_info"` + `AT+QSCAN` (36)** → cell scanner + neighbour scanner + live AIM. Fully new.
23. **`AT+QNWCFG="lte_csi"/"nr5g_csi"/"*_ulMCS"/"*_dlMCS"/"mimo_layers"/"rrc_state"/"nr5g_tx_pwr"/"ssb_beam_id"`** → Tier-3 detailed metrics. Mostly **remove**.
24. **`AT+QMBNCFG` (14)** → MBN page (`cellular/mbn.sh`, 11 sites). Rebuild or drop.
25. **`/usr/bin/ql_qmap`** (IP passthrough) → no equivalent; **drop** or rebuild on raw `iptables`/bridge.
26. **QMI path** — `qmi_read.sh` (518 lines), `qrtr://3`, `dependencies/qmi/*` → SIMCom has no Qualcomm QRTR. All 5 `qm_qmi_*` consumers lose their source; neighbour live view degrades to AT-only.
27. **Qualcomm sysfs** — `/sys/devices/platform/4080000.qcom,mss/subsys0/{crash_count,state}`, `ramdump_modem` (`poller:202-203,443-446`) → modem crash watcher is dead; needs a new fault signal.
28. **`/etc/quectel-project-version`** (`hw_profile.sh:35`, `poller:125`) → whole hardware-profile tier table `RM|RG|EG|EC` regex (`hw_profile.sh:82-86`) and `qm_hw_soc()` need a SIMCom identity source.

---

## Constraints, risks, open questions

- **`criterion-1` residual:** this inventory is **static** (no device). Every SIMCom-side claim ("SIMCom has no `QENG`", "`AT+CNBL`/`CNBP` is the band command") is from vendor-doc knowledge, **not measured against a SIM8260E unit**. The repo's own rule (`change-workflow.md`, cited in `platform-matrix.md`) is *"device-diff before agents"* — repeat this exercise against live `AT+CLAC` output on a SIM8260E before committing to any tier assignment.
- **`AT+CLAC` is not used anywhere** (0 hits). That is the cheapest possible first step for the new port: dump the supported command set and diff it against this table.
- The **Rust broker (`native/qmanager_atd`)** is the intended transport going forward and is `[Install]`-disabled only because it is untested on-device. Porting `channel.rs` (open + termios + drain) is **one file** versus patching `deploy/atcli_smd11`; strongly prefer it.
- **Open:** does the SIM8260E BSP ship BusyBox `flock` with `-w`? The whole `qcmd:116-131` poll loop exists because this one lacks it.
- **Open:** is `xt_HL` (`-j TTL`/`-j HL`) in the SIMCom kernel? If not, the TTL page is unimplementable without a rebuild.
- **Open:** `deploy/qm_boot_hook.sh` injects into `turin_web.sh`, a GreenPacket vendor boot script. SIMCom's boot script name is unknown — every `deploy/*.service` currently relies on this hook, not on `systemctl enable`.

---
