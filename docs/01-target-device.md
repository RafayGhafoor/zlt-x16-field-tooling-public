# 01 — Target device: ZLT X16 ODU (SIMCom SIM8260E)

Evidence tags: **[E]** evidenced from captured artifacts or live probe · **[I]** inferred.

## Hardware / SoC

| Item | Value | Evidence |
|---|---|---|
| SoC | Qualcomm **SDX65** (`sdxlemur`), single die = AP **and** modem | [E] console banner `QTI Linux reference nogplv3 distro ... sdxlemur` |
| Module | SIMCom **SIM8260E** (`SIM8260A-A0J4K/J4M`, `SIM8260E-A0J4K/J4M`) | [E] `dialer.strings` SKU list |
| Module FW | `2212B01X62M88A-LGA_CUS_TZ`, rev `V1.0.01`, baseband `MPSS.DE.2.0-01026-OLYMPIC_GENALL_PACK-1` | [E] `DIAGNOSIS.md` |
| Vendor FW | `X16-OMN247-4.00`, `SYS_FW_USER_VER=1.09.39.10` (Ooredoo Oman product config) | [E] `mdlcfg` reads |
| RAM | **646 MiB** visible (`MemTotal: 661264 kB`), ~506 MB available at idle | [E] three independent `/proc/meminfo` captures |
| CPU | 32-bit ARMv7 `armv7vet2hf-neon`, VFPv4+NEON, Thumb-2 (Cortex-A7 class) | [E] ELF flags `0x05000400` + build tuple |
| Cores | not captured — **`nproc` needed live** | — |

**The modem is on-die.** There is no USB/serial modem. This is the single most important
fact for the port (see [05-the-at-problem.md](05-the-at-problem.md)).

## Software

| Item | Value | Evidence |
|---|---|---|
| Distro | Qualcomm Yocto / OpenEmbedded `qti-distro-nogplv3-perf`, QTI-LE 1.2 | [E] build paths in binaries |
| libc | **glibc 2.31** (not musl) | [E] `glibc/2.31+gitAUTOINC+d4b7559457-r0` + versioned symbols |
| Toolchain | GCC 9.3.0 | [E] `.comment` |
| Init | **systemd** (units + `daemon-reload` proven) with leftover SysV `/etc/init.d` | [E] `libsystemd.so.0` in `dialer`; working `zlt-wan-fix.service` |
| openwrt/procd/ubus/uci | **absent** | [E] zero strings |
| Shell | busybox `ash` (prompt `/ #`) | [I] prompt shape |
| Root shell | telnet:23 root **was** available in earlier sessions; **closed from our current network position** | [E] `zlt_x16_diagnose.py`, live probe |

## Data path (vendor)

```
dialer (Sunsea state machine, 1 Hz AT poll)
  └─ libolinterface.so.1.0.0  (OSM IPC client)
       └─ libosm_client.so.1 ─ basic_prv ─ libdsi_netctrl
            └─ WDS/QMI over QRTR ─ rmnet_data0 ─ rment_ipa0 (IPA offload) ─ LAN bridge0
```

Interfaces seen: `rmnet_data0..5`, `rmnet_ipa0`, `bridge0`, `eth0`, `lo`.
**WAN = `rmnet_data0`** — the same name QManager already expects from Qualcomm devices.

## AT path (vendor) — see 05

```
dialer ── tATCMD_Request (magic 0xabcd, len 0x1014) ── sockmsg bus ──> APP_ID_ATCMD daemon
```
No `/dev/smd*`, no tty, no pty anywhere in the extracted binaries **[E]**.

## Filesystem

| Path | Writable | Use |
|---|---|---|
| `/data` | **yes, persistent** | Primary store. Already holds `/data/zlt-wan-fix/`, `/data/zlt-mbn-recovery/`, `/data/coredump/` |
| `/etc/systemd/system` | **yes** | Vendor unit installed/removed there successfully |
| `/etc/data` | yes, runtime | vendor runtime config (`dnsmasq.conf`, `rt_tables`) |
| `/tmp`, `/var/run/data` | tmpfs | volatile |
| `/productinfo`, `/firmware`, `/persist` | vendor-owned | **do not touch** |
| `/usrdata` | **does not exist** | That is a GreenPacket/Suncomm convention — the `deploy/` layer must be re-pointed to `/data` |

Rootfs is **not** read-only (writes to `/etc` succeed without a remount).

## Web / management plane

| Item | Value | Evidence |
|---|---|---|
| Port 80 | **open** — vendor UI | [E] live probe (HTTP 200) |
| Port 443 | **open** — vendor UI TLS | [E] live probe |
| Port 8080 | **closed** — free for QManager | [E] live probe |
| Port 22 / 23 | closed from our network position | [E] live probe |
| Vendor UI stack | jQuery 1.7.2 + Vue 2 + Element UI, SPA loading `html/*` fragments | [E] captured `index.html`, `main.js` |
| Vendor API | single CGI: **`/cgi-bin/http.cgi`** (`cmd=RequestCmd`) | [E] `main.js` |
| Vendor app bus | `APP_ID_HTTP_CGI`, `APP_ID_ATCMD`, `APP_ID_ATCMD_TOOL`, `APP_ID_ATROUTER`, `APP_ID_WAN_MGR`, `APP_ID_FIREWALLTOOL`, … (54 app ids) | [E] `dialer.strings` |
| Document root | **unknown** — needs `ps`/`netstat` on device | — |

Notable vendor-UI menu ids found in `main.js`: `AT_CMD:{index:55,hideFlag:"0"}` — an **AT
command page is enabled in this firmware** — plus `LTE_PHYCELL_INFO`, `LTE_AREA_INFO`,
`LTE_LOCK_FREQUENCY` (`html/config/lteLockFrequencyConfig*.html`), `SYS_LOG`, `FLOW_INFO`,
`IP_PASS`, `SLICE`, `TR069`, `DDOS`. Several of these overlap QManager features.

## Confirmed working on this unit

- `curl` (< 7.75), `dd`, `ip`, `iptables`, `ip6tables`, `ebtables`, `dnsmasq`, `ethtool`,
  `brctl`, `awk/sed/grep/cut/pidof` **[E]** (invoked by shipped binaries or in a live transcript).
- **QMI over QRTR**: `qmicli` was staged on the device and used successfully to drive Qualcomm
  PDC (activated/rolled back MBN profiles) **[E]** per `DIAGNOSIS.md`.
- `systemctl` enable/disable/daemon-reload **[E]** (`router-fix/README.md`).

## Not evidenced (must be checked live)

`jq`, `python`, `wget`, `lighttpd/httpd/uhttpd`, `sms_tool`, `microcom/socat`, `flock -w`,
`openssl`, `ss/netstat`, `df`/flash size, exact docroot, kernel version, CPU count.
