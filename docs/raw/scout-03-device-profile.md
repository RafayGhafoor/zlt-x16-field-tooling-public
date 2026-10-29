# ZLT X16 ODU — Target Device Profile (LOCAL EVIDENCE ONLY)

Router unreachable. Everything below derives from `DIAGNOSIS.md`, `firmware-analysis/*`,
`router-fix/*`, `zlt_x16_diagnose.py`, and the five `zlt-*` capture directories.
Each claim is tagged **[E]** (evidenced — a quoted artifact says so) or **[I]** (inferred —
consistent with evidence but not directly observed). Where nothing local supports a
question, it says **NOT EVIDENCED** rather than guessing.

---

## 1. SoC / platform / OS

**SoC — Qualcomm SDX65 ("SDXLEMUR"). [E]**
Device console banner, identical in every capture (`zlt-diagnostic-20261026-025955/router.jsonl:1`,
`zlt-check-20260901-093950/router.jsonl:1`, repeated 38× in
`zlt-diagnostic-20260901-093727/router.jsonl`):

```
QTI Linux reference nogplv3 distro targeting performance builds. 8e4f3af sdxlemur
/ #
```

Build paths baked into the binaries confirm the same silicon and SDK
(`firmware-analysis/dialer.strings:4051`, `libolinterface.strings:751`):

```
/var/jekins/workspace/8260-AP_1-code/SDX65_LE12_AP/build-qti-distro-nogplv3-perf/tmp-glibc/work/armv7vet2hf-neon-oe-linux-gnueabi/glibc/2.31+gitAUTOINC+d4b7559457-r0/...
/home/zxs/SDX65_LE12/AP_KZ_230313/build-qti-distro-nogplv3-perf/tmp-glibc/work/armv7vet2hf-neon-oe-linux-gnueabi/simcom-sdk/git-r1/...
```

"8260-AP" is the SIM8260 AP-side SDK — i.e. **the router's SoC and the "modem" are the same
SDX65 die**; the SIM8260E is the module part number, not a separate USB/serial modem.

**Distribution — Yocto/OpenEmbedded, not Buildroot. [E]** `build-qti-distro-nogplv3-perf`,
`tmp-glibc/work/.../recipe-sysroot`, `armv7vet2hf-neon-oe-linux-gnueabi` are OE/Yocto
artifacts verbatim. `nogplv3` is Qualcomm's QTI Linux (LE) reference distro.

**libc — glibc 2.31, definitively not musl. [E]** Fortified glibc symbols in
`dialer.nm` (`__libc_start_main@@GLIBC_2.4`, `__memcpy_chk`, `__stack_chk_fail`,
`clock_gettime@@GLIBC_2.17`, `pow@@GLIBC_2.29`), plus the literal recipe version
`glibc/2.31+gitAUTOINC+d4b7559457-r0` in the build path. Toolchain: GCC 9.3.0
(`libolinterface.strings`: `GCC: (GNU) 9.3.0`).

**ABI — 32-bit ARM, armhf/EABI5, VFPv4 + NEON, Thumb-2. [E]** ELF header of
`firmware-analysis/dialer`: class 32-bit LSB, `e_machine = 0x28` (EM_ARM), type `ET_DYN`
(PIE), `e_flags = 0x05000400` (EABI5 | hard-float ABI). Interpreter string is
`/lib/ld-linux-armhf.so.3` (`dialer.strings:1`, `libolinterface.strings:133`).
Tuple `armv7vet2hf-neon` (+NEON, vfpv4, thumb2). `v7ve` implies a Cortex-A7-class core
**[I]** — no `/proc/cpuinfo` was captured.

**Kernel — no version string captured. [NOT EVIDENCED]** Indirect: `SDX65_LE12` in the
build path (QTI Linux Embedded release 1.2) and `rmnet_ipa0`/IPA plus `qcom,gpr` platform
drivers in dmesg. **[I]** kernel 5.4.x. Do not rely on this; `uname -r` must be read live.

**Init system — systemd is present and is the init. [E]** Multiple independent proofs:
- `firmware-analysis/dialer.strings:66` — `libsystemd.so.0` is a DT_NEEDED of `/bin/dialer`.
- `router-fix/zlt-wan-fix.service` — a real unit using `After=TZApp.service`,
  `WantedBy=multi-user.target`; `router-fix/README.md` uses `systemctl disable --now`,
  `systemctl daemon-reload`, and installs to `/etc/systemd/system/`.
- `DIAGNOSIS.md:183` — "`QCMAP_Bootup.service` fails on every boot" (a unit-state
  observation only `systemctl`/journal can give).

**Legacy SysV/shell-init layer also coexists. [E]** The vendor binaries invoke
`/etc/init.d/engpc-init restart` and `/etc/initscripts/ntp.sh` /
`/etc/initscripts/start_radvd` (`dialer.strings:2023`, `:2485`, `:3020`). QTI Yocto images
keep these; systemd runs them via its SysV compat generator **[I]**.

**procd / ubus / uci — NOT EVIDENCED.** No `procd`, `ubus`, `uci`, or OpenWrt strings
anywhere; the prompt and distro banner also argue against OpenWrt. `/etc/config` was never
referenced. Treat OpenWrt tooling as absent.

**Firmware identity strings. [E]** `SYS_CFG_VER=X16-OMN247-4.00`, `SYS_FW_USER_VER=1.09.39.10`,
module rev `V1.0.01`, module FW `2212B01X62M88A-LGA_CUS_TZ`, baseband
`MPSS.DE.2.0-01026-OLYMPIC_GENALL_PACK-1` (`DIAGNOSIS.md` §Active WAN configuration).
`dialer.strings` also carries `SUNSEA_X62/sunsea.c` — Sunsea's X62 AP framework — and the
allowed module SKUs `SIM8260A-A0J4K/J4M`, `SIM8260E-A0J4K/J4M` (`dialer.strings:2915-2921`).

---

## 2. Userspace inventory

Evidence type matters here. Three classes:
(a) shell transcript from the device, (b) command strings the vendor daemons `popen()`,
which prove the binary exists in `PATH`, (c) absence.

**(a) Directly executed in a live shell** — `firmware-analysis/mtu-upload-test.log` is a
verbatim console capture (`/ #` prompt) running:

```
L0=$(wc -l < /tmp/logs/DIALER.log); (dd if=/dev/zero bs=1048576 count=128 2>/dev/null \
 | curl --interface rmnet_data0 --max-time 180 -sS -o /tmp/zlt-upload-response \
 -w 'curl_code=%{http_code} bytes=%{size_upload} speed=%{speed_upload} exit=%{exitcode}\n' \
 -X POST --data-binary @- https://speed.cloudflare.com/__up > /tmp/zlt-upload-result 2>&1) & U=$!;
 i=0; while kill -0 $U 2>/dev/null && [ $i -lt 190 ]; do printf '%s ' "$(date +%H:%M:%S)";
 ip route show default | tr '\n' '  '; printf ' tx='; cat /sys/class/net/rmnet_data0/statistics/tx_bytes;
 i=$((i+1)); sleep 1; done; wait $U; ...
```

**Evidenced present:** `curl` (working, HTTPS, `--interface`, `-w`), `dd`, `wc`, `cat`,
`tail`, `printf`, `date`, `tr`, `sleep`, `kill`, `wait`, `ip`, and shell arithmetic/`[ ]`.
Also `dmesg`, `/proc/*`, `/sys/class/net/*` readable as root.

**(b) Invoked by vendor binaries (so present in `PATH`)** — from
`basic_prv.strings:520-580` and `dialer.strings:2070,2937,2487-2569`:
`iptables`, `ip6tables`, `ebtables`, `ifconfig`, `ethtool`, `brctl`, `ip`, `dnsmasq`
(at `/usr/bin/dnsmasq`), `awk`, `grep`, `cut`, `sed`, `pidof`, `killall`, `chmod`, `sync`.
`ping` and `route` are used by `zlt_x16_diagnose.py` with `2>/dev/null` fallbacks, so
`ping` presence is **not** proven — only `ip route` is.

**Shell — BusyBox `ash` highly likely. [I]** Prompt is `/ #` (busybox's default root
prompt) in both the transcript and the telnet captures; `dd`/`wc`/`tr`/`printf` in the
transcript behave as applets. No `busybox` string appears in binaries (they never call it),
so this rests on prompt shape and image conventions. Don't assume `bash`.

**Telnet sever / dropbear — root login over TCP/23 works. [E]** `zlt_x16_diagnose.py`
hardcodes `--telnet-port 23`, `--username root`, and the captures show a successful root
login followed by arbitrary shell. So a root shell is reachable on port 23 (either telnetd
or inetd). SSH (`dropbear`/`openssh`) is **NOT EVIDENCED**.

**`curl` version is old. [I]** The device printed `curl: unknown --write-out variable:
'exitcode'`; `%{exitcode}` only exists from curl 7.75.0 → the on-device curl is **< 7.75**
(and old enough to lack it). `-w '%{speed_upload}'`, `--data-binary`, `--interface` all work.

**NOT EVIDENCED anywhere in the local artifacts:** `wget`, `jq`, `python`/`python3`,
`lighttpd`, `nginx`, `httpd`, `uhttpd`, `socat`, `microcom`, `sms_tool`, `nc`, `openssl`,
`sqlite3`, `tcpdump`, `qmicli`. Absence here means only "no local artifact mentions it" —
the three extracted binaries are a narrow slice of the rootfs (they are the data-path
daemons, not the web/app layer). **A live `ls /bin /usr/bin /usr/sbin` is required before
concluding any of these are missing.**

One important *positive* exception: `DIAGNOSIS.md:147` records that "A compatible ARM
`qmicli` and its QRTR libraries were staged on the router" and successfully used to drive
Qualcomm PDC. So **QMI-over-QRTR works on this device** and QRTR userspace libs
(`libqrtr.so.1`) are already installed as a dependency of `libolinterface.so.1.0.0`
(`libolinterface.strings:133`).

---

## 3. AT access path to the SIM8260E

**The vendor stack does NOT open a tty for AT. [E]** Two separate paths exist, and neither
uses `/dev/ttyUSB*`, `/dev/ttyACM*`, `/dev/smd*`, or any pty:

1. **Data path (no AT at all):**
   `dialer → libolinterface.so.1.0.0 → libosm_client.so.1 (Sunsea OSM IPC) → basic_prv → libdsi_netctrl → WDS/QMI`.
   `libolinterface` DT_NEEDED: `libosm_client.so.1`, `libqrtr.so.1`, `libqsocket.so.1`,
   `libqmi_*.so.1`; imports `osm_requester_init`, `osm_requester_sync`,
   `qmi_client_init_instance`, `qcmap_msgr_get_service_object_internal_v01`. `basic_prv`
   imports `dsi_start_data_call`, `dsi_get_data_srvc_hndl`, `dsi_set_data_call_param`,
   `dms/nas/wds get_service_object_internal_v01`, `osm_provider_init` (`basic_prv-r2.txt`).
   The only `/dev` node it opens is **`/dev/ipa`** (ioctl for IP-PT SW-path filters,
   `basic_prv.strings:518`). QMI rides QRTR, not a uart.

2. **AT path — Sunsea `sockmsg` message bus to an AT-command daemon. [E]**
   `dialer.nm:6558 T sunsea_send_at_with_format`. Disassembly of that function
   (`firmware-analysis/dialer`, objdump at `0x6558`) shows it fills a
   `tATCMD_Request` structure (magic `0xabcd`, length `0x1014`, random `at_id` from
   `srand(time())`), then:

   ```
   0x6640: movs r0, #0x5
   0x6642: blx  sockmsg_send_common_msg
   ```

   and waits on a `pthread_cond_timedwait` for a matching `tATCMD_Response`, erroring with
   "`get at_respone at_id not same as request!`" and
   "`get at_response from [%s]`"/`ATCMD_DAEMON_FILE_OK`
   (`dialer.strings:1904,1923-1924`). Struct/type names come from
   `atcmd_daemon_msg_define.h` (`dialer.strings:3563`). The bus app IDs are enumerated in
   `dialer.strings:4087-4216`: `APP_ID_ATCMD`, `APP_ID_ATIND`, `APP_ID_ATCMD_TOOL`,
   `APP_ID_ATROUTER`, `APP_ID_DIALER`, `APP_ID_HTTP_CGI`, `APP_ID_TZ_SMS_MGR`, etc.
   `dialer` links `libmdlsockmsg.so` (`init_sockmsg`, `sockmsg_send_common_msg`,
   `sockmsg_send_broadcast_msg`).

   **Consequence: AT is a serialized, IPC-brokered service, not a character device.** A
   third-party app cannot simply `open("/dev/tty…")` — it would have to speak the
   `sockmsg` framing in `atcmd_daemon_msg_define.h` against `APP_ID_ATCMD`, which is
   undocumented and unexported (`libmdlsockmsg.so`/`libcfgapi.so`/`libosm_client.so.1` are
   private vendor libs).

**Is there an unused AT port a third-party app could use? NOT EVIDENCED. [I] no.**
No tty/ptty node string exists in *any* extracted artifact (exhaustive `/dev/...` sweep of
`firmware-analysis/` returns only `/dev/null`, `/dev/zero`, `/dev/ipa`). On SDX65 the
modem is on-die, so there is no USB/serial AT port to begin with; AT is only reachable
through the QTI "atcmd daemon" and via the engineering-port mechanism below.

**Engineering port (diag/AT over USB) — exists but is toggled, not free. [E]**
`dialer.strings:3011-3045`: `/mnt/data/engpc.ini`, `/etc/engpc/engpc.ini`,
`sed -i 's/^ro.start.flag=.*/ro.start.flag=%s/g' %s`, keys `engpcenable`/`engpcdisable`,
`/etc/init.d/engpc-init restart`, function `sunsea_handle_engpc`. That is SIMCom/QTI's
engpc (QXDM/diag) bridge. Using it means stopping/restarting `engpc-init` and fighting the
dialer for it. **[I]** usable for sniffing, not for a coexisting app.

**AT contention risk with `/bin/dialer` — HIGH. [E]**
- `dialer` polls AT on a ~1 s cadence: `sunsea_dialer_1s_event_handler` (`dialer.nm:0x8574`)
  issues `AT+CSQ`, `AT+CEREG?`, `AT+CPSI?`, `AT+COPS?`, `AT+CNWINFO?`, `AT+CGPADDR`,
  `AT+CGACT`, `AT+SPENGMD=...` (`dialer.strings:2046-2291`).
- AT calls are serialized by an internal `pthread_mutex_lock`/`unlock` inside
  `sunsea_send_at_with_format` — the lock is **per-process**, so it does not protect
  against another client on the bus.
- The dialer treats AT loss as fatal: "`Dialer reboot system cause AT send failed more than
  %d times`" / "`Dialer need reboot system cause AT send failed too many times`"
  (`dialer.strings:1875-1882` region). **[I]** Interleaving raw AT on the same channel can
  therefore cause an unwanted **router reboot**, not just a failed command.
- Anything that perturbs the data session is also penalized: the state machine resets on
  "`dialer state machine abnormal detected, reason: %s, try to reset it!`".

**Safer programmatic path for a new app: QMI/QRTR, not AT. [I]** `qmicli` over QRTR already
worked on this device (`DIAGNOSIS.md:147`) and `libqrtr.so.1` is installed. QMI does not
consume the AT channel and does not trip the dialer's AT-failure reboot path. Treat AT as
read-only-for-humans, and prefer `qmicli`/`libqmi` for anything scripted.

---

## 4. Firmware / web / filesystem layout

**Web server, port, document root, CGI mechanism — largely NOT EVIDENCED locally.**
The three extracted binaries never touch the web layer. What *is* evidenced:

- An HTTP/CGI application exists in the vendor framework: `APP_ID_HTTP_CGI`
  (`dialer.strings:4128`), i.e. a CGI handler registered on the same `sockmsg` bus, with
  `APP_ID_TZ_PHONE`, `APP_ID_GUI_MIFI`, `APP_ID_TZ_LISTEN`, `APP_ID_TZUPDATE`,
  `APP_ID_UPGRADE` alongside it — the classic Sunsea "TZ" web/management stack.
- **Something listens on 80 and on 443. [I, strong]** `basic_prv.strings:544-545` installs
  WAN-side blocks precisely because the services exist:
  `iptables -t filter -I INPUT -i rmnet_data0 -p tcp --dport 80 -j DROP` and the same for
  `--dport 443`. A drop rule for a port only makes sense if the port is open on the LAN
  side. So: **HTTP on 80, HTTPS on 443, LAN-only by firewall.**
- Port 8080: **NOT EVIDENCED.** No `8080` string anywhere in the artifacts.

**Document root and CGI binary path — NOT EVIDENCED.** No `/www`, `/htdocs`, `/cgi-bin`,
`goform`, `index.html`, or web-server binary name appears in any local file. A live
`netstat -lntp` + `ls /` is required. Note the vendor's naming convention suggests the web
app is one of the `TZ*` daemons started by `TZApp.service` **[I]**.

**Persistent, writable paths. [E]**

| Path | Evidence | Notes |
|---|---|---|
| `/data` | `dialer.strings:2100,2108-2111,2986,3096` — `/data/total_flow`, `/data/sys_total_{dl,ul}_flow`, `/data/wifi_config`, `/data/ICCID_PIN_file`; `DIAGNOSIS.md` — `/data/zlt-mbn-recovery`, `/data/coredump/core.dialer` (43.7 MB), `/data/zlt-wan-fix/` | **Primary writable persistent store. Survives reboot. Proven by repeated successful writes across sessions.** |
| `/etc/systemd/system` | `router-fix/zlt-wan-fix.service` installed there; `systemctl daemon-reload` then `disable --now` + `rm -f` all succeeded | **Writable. Rootfs `/etc` is NOT read-only (or is on a rw overlay).** |
| `/productinfo` | `dialer.strings:2940-2989` — `sn`, `imei`, `mac`, `wifi_mac`, `generate_sn`, `tzcfg/system_config.use` | Vendor identity/config, mounted config store; not for a new app. |
| `/etc/data` | `basic_prv.strings` — `/etc/data/dnsmasq.conf`, `/etc/data/hosts`, `/etc/data/iproute2/rt_tables` written at runtime (`echo 200 ippastbl >> /etc/data/iproute2/rt_tables`) | **Runtime-writable.** |
| `/var/run/data` | `basic_prv.strings` — `/var/run/data/dnsmasq.conf.bridge0`, `.leases`, `.pid` | tmpfs volatile dir. |
| `/tmp` | `dialer.strings:1744-3008` — many `/tmp/.flag_*`, `/tmp/.tmp_*`, `/tmp/cmdlib/` | tmpfs, volatile. |
| `/mnt/data` | `dialer.strings:3011` — `/mnt/data/engpc.ini` | **[I]** alternate mount of the same data partition as `/data`. |
| `/persist` | `DIAGNOSIS.md` §NVRAM | modem-support state. |
| `/usrdata` | **not present** | That is an OpenWrt convention; this device uses `/data`. |

**Rootfs read-only?** **[E] No — writes to `/etc` succeed.** Strongest evidence:
`zlt-wan-fix.service` was written to `/etc/systemd/system/`, `daemon-reload`ed, enabled,
then `disable --now` + `rm -f` removed it, with no `mount -o remount,rw` step recorded
anywhere in `router-fix/README.md` or `DIAGNOSIS.md`. **[I]** either the ext4/ubifs root is
mounted rw, or `/etc` is a rw overlay over a squashfs/read-only base.

**Other fixed paths worth knowing. [E]**
`/tmp/logs/DIALER.log` (the dialer log; `tail`ed live in the transcript),
`/firmware/image/Ver_Info.txt`, `/etc/data/mobileap_cfg.xml` (QCMAP config),
`/productinfo/tzcfg/main_config` (mdlcfg database), `/etc/engpc/engpc.ini`,
`/etc/init.d/engpc-init`, `/etc/initscripts/{ntp.sh,start_radvd}`,
`/sys/ssdk/port_link` (QCA SSDK switch), `/sys/class/net/eth0/speed`,
`/data/ds_dsd_attach_profile.txt` (DSD attach-profile NV, written via `AT+CNV`),
`/proc/net/dev` (flow accounting).

---

## 5. Resources

**RAM. [E]** `/proc/meminfo` from three independent captures, byte-identical totals:

```
MemTotal:         661264 kB
MemFree:          334464 kB
MemAvailable:     505908 kB
Buffers:               4 kB
Cached:           171312 kB
```

≈ **646 MiB visible RAM** (so a 1 GiB DDR part with modem/IPA carve-outs **[I]**, or a
768 MiB part). ~506 MB available at 12 min uptime → **plenty of headroom for a new
service**; a typical Python/Go daemon would be lost in the noise.

**CPU. [E]** 32-bit ARMv7 (armv7vet2hf-neon), NEON + VFPv4, Thumb-2 (see §1).
Core count **NOT EVIDENCED** — no `/proc/cpuinfo` was captured; `1/414` in `/proc/loadavg`
is runnable/total-threads, not CPUs. **[I]** SDX65 AP is dual or quad Cortex-A7.

**Load / conntrack. [E]** `load average: 2.03, 1.87, 1.36` with `1/414` tasks at 12 min
uptime; `nf_conntrack_count` 126–521 against `nf_conntrack_max` **45056** (~1% used).
Note the dialer burns CPU spinning an AT poll loop every second — baseline load ~2.0 on an
idle-ish box **[I]**.

**Network interfaces. [E]** `/proc/net/dev` lists:
`rmnet_data0`–`rmnet_data5`, `rmnet_ipa0`, `bridge0`, `eth0`, `lo`, plus the kernel's idle
`erspan0 gre0 gretap0 ip6tnl0 ip6gre0 sit0 teql0 tunl0 dummy0`. LAN = `bridge0`
(192.168.3.0/24 in the Oct capture, 192.168.0.0/24 in the Sep captures) with `eth0` as its
member; WAN = `rmnet_data0` over `rmnet_ipa0` (IPA offload active — dmesg:
`ipa-wan ipa3_wwan_ioctl:3153 dev(rmnet_data0) register to IPA`).
`rmnet_data3` exists but is idle → **a spare PDN slot is already provisioned** **[I]**,
relevant if a new app needs its own data context.

**Flash size / partition table / tmpfs sizes — NOT EVIDENCED.** No `df`, `mount`,
`/proc/mounts`, `lsblk`, `cat /proc/partitions`, or `ubi`/`mmcblk`/`mtd` string exists in
any local artifact. The only flash facts are indirect: a **43.7 MB** file
(`/data/coredump/core.dialer`) existed under `/data` (`DIAGNOSIS.md` §Other findings), so
`/data` is comfortably larger than ~50 MB — **[I]** eMMC or large NAND, tens to hundreds of
MB. **A live `df -h` is mandatory before planning an install of any size.**

**Partitions named in `DIAGNOSIS.md` §NVRAM. [E]:** `efs2`, `efs2_bak`, `modem`, `simcom`,
`devinfo`, plus `/productinfo/tzcfg`, `/data`, `/persist`.

---

## 6. systemd + a home for a new app and service

**systemd: present, is PID 1's framework, and unit files are writable. [E]** — see §1.
Confirmed by (i) `libsystemd.so.0` linked into `/bin/dialer`, (ii) a working
`/etc/systemd/system/zlt-wan-fix.service` with `WantedBy=multi-user.target`,
(iii) `systemctl daemon-reload` / `disable --now` used successfully,
(iv) `QCMAP_Bootup.service` and `TZApp.service` named as real units.

**Proven-good recipe already on the box. [E]** `router-fix/zlt-wan-fix.service` +
`/data/zlt-wan-fix/zlt-wan-fix.sh` is a working, removable precedent:
unit body in `/etc/systemd/system/`, `Type=oneshot` + `RemainAfterExit=yes`, payload in
`/data/`, `Requires=`/`After=` on a vendor unit (`TZApp.service`) to sequence after the
data path is up. **Copy this pattern.**

**Recommended placement for a new app. [I, grounded in the above]**
- **Payload/binaries → `/data/<app>/`** — writable, persistent, survives reboot, and
  already used exactly this way (`/data/zlt-wan-fix/`, `/data/zlt-mbn-recovery/`).
- **Unit → `/etc/systemd/system/<app>.service`** — proven writable.
- **Ordering → `After=`/`Wants=` (not `Requires=`) on `TZApp.service`**, or on
  `network-online.target`; `zlt-wan-fix.service` needed `Requires=TZApp.service` only
  because it must clamp rules *after* the dialer installs them. A new service that merely
  reads state should avoid `Requires=` so a `TZApp` restart does not take it down.
- **Runtime scratch → `/var/run/<app>` or `/tmp`** (tmpfs).
- **Avoid `/productinfo`, `/etc/data`, `/firmware`, `/persist`** — vendor-owned.
- **Add `Restart=on-failure` + `RestartSec`** — the box has a history of one vendor unit
  (`QCMAP_Bootup.service`) failing every boot.

**Constraints / risks to design around. [E unless noted]**
1. **Do not fight the dialer for AT.** Its 1 s AT poll is mutex-protected only in-process,
   and repeated AT failures trigger a **system reboot** (`dialer.strings` reboot strings).
   Use QMI/QRTR (`qmicli`, already proven on this device) or read `DIAGNOSIS`-style local
   state files instead.
2. **The WAN is unstable by nature** — PDU deactivations every few minutes under upload
   (`DIAGNOSIS.md`), 6–59 s recovery. Any long-lived app must tolerate `rmnet_data0`
   disappearing and the default route vanishing.
3. **`/etc/resolv.conf` is rewritten by the dialer** (`dialer.strings:2455-2467`) — do not
   manage DNS config in `/etc`.
4. **Memory is fine, flash is unknown.** Verify `df -h /data` before shipping.
5. **glibc 2.31 / armhf only.** Anything statically linked against musl will not run; any
   prebuilt binary must be `armhf` (VFPv4, hard-float) and built against glibc ≤ 2.31.
   Go/Rust cross-compiles must target `GOARM=7 GOARCH=arm` + `CGO` against glibc 2.31.
6. **Root shell is available over telnet:23**, so install/debug is straightforward without
   any vendor tooling — but that also means the box is not security-hardened **[I]**.

---

## Open questions that require the device to be reachable

1. `uname -a`, `/proc/cpuinfo` — kernel version, core count.
2. `df -h` / `mount` / `cat /proc/partitions` — flash size, rootfs ro/rw, overlay, tmpfs.
3. `netstat -lntp` or `ss -lntp` — what actually listens on 80/443/8080, and the docroot.
4. `ls /bin /usr/bin /usr/sbin` — settle wget/jq/python/sms_tool/microcom/lighttpd.
5. `ls -l /dev | grep -i tty` and `ps w` — any spare tty and the full daemon list.
6. `systemctl list-units --type=service` — the real unit names, incl. `TZApp.service`.
7. `ls -l /etc/systemd/system/multi-user.target.wants/` — the vendor's own enablement set.

## Scratch notes
`/tmp/notes-device-profile/raw-quotes.txt` (verbatim strings, byte offsets, dmesg lines).

---

## Files Retrieved
1. `DIAGNOSIS.md` (lines 1-320) — datum for firmware versions, partitions, `/data` usage, systemd units, MTU defect.
2. `zlt-diagnostic-20261026-025955/router.jsonl` (lines 1-2) — banner, meminfo, `/proc/net/dev`, routes, conntrack, dmesg.
3. `zlt-check-20260901-093950/router.jsonl` (line 1) — second independent banner/meminfo capture.
4. `zlt-diagnostic-20260901-093727/router.jsonl` (38 lines) — repeated captures confirming stable MemTotal/banner.
5. `firmware-analysis/mtu-upload-test.log` (whole file) — live root shell transcript proving `curl`, `dd`, `ip`, `/sys` access.
6. `firmware-analysis/dialer.strings` (lines 1-120, 1870-1930, 2415-2570, 2915-2930, 2995-3060, 4051-4216, 5274-5400) — DT_NEEDED list, build paths, AT daemon IPC, `/data`+`/etc` paths, APP_ID table.
7. `firmware-analysis/libolinterface.strings` (lines 60-145, 560-740) — OSM/QMI/QRTR deps, Sunsea_* API surface.
8. `firmware-analysis/basic_prv.strings` (lines 500-600) — `/dev/ipa`, dnsmasq/bridge/iptables/MSS-1460 shell, WAN port-80/443 DROP.
9. `firmware-analysis/dialer.nm` (symbol table) — glibc versioned imports, `sunsea_send_at_with_format` at 0x6558.
10. `firmware-analysis/libolinterface.nm` (symbol table) — `qmi_client_*`, `osm_requester_*`.
11. `firmware-analysis/dialer` (ELF header @0x00-0x28, disassembly 0x6558-0x66f0) — 32-bit ARM hard-float PIE; sockmsg AT request framing.
12. `firmware-analysis/basic_prv-r2.txt` (lines 400-480) — DSI/QMI symbols and `/rodata` shell command table.
13. `router-fix/zlt-wan-fix.service`, `router-fix/zlt-wan-fix.sh`, `router-fix/README.md` — working systemd unit +/data payload pattern.
14. `zlt_x16_diagnose.py` (lines 1-140) — telnet:23 root login, exact read-only command set that works on-device.

## Architecture
SDX65 (SDXLEMUR) single-die AP+modem. Yocto/QTI-LE 1.2 `qti-distro-nogplv3` rootfs, glibc 2.31,
32-bit armhf, systemd init with leftover SysV `/etc/init.d` + `/etc/initscripts`.
Data plane: `dialer` (Sunsea, state machine + 1 s AT poll) → `libolinterface` (OSM IPC client) →
`basic_prv` (OSM provider + `libdsi_netctrl`) → WDS over QRTR → `rmnet_data0` via IPA.
AT plane: `dialer` builds a `tATCMD_Request` and sends it on the Sunsea `sockmsg` bus to
`APP_ID_ATCMD` — there is no tty. Management plane: `TZApp.service` + `APP_ID_HTTP_CGI` on
80/443, firewall-restricted to LAN. Persistence: `/data` (writable, proven), `/etc` writable,
`/productinfo` vendor-owned.

## Start Here
Open `firmware-analysis/dialer.strings` — it is the single densest artifact: the DT_NEEDED
list at lines 1-90 establishes glibc/armhf/systemd/QMI, lines 4051-4080 give the exact
Yocto/SDX65/glibc-2.31 build tuple, and lines 4087-4216 enumerate the entire vendor
application bus (`APP_ID_*`), which is the map of what else runs on this box.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Device profile written to the configured output path with all six requested sections, each claim tagged [E] evidenced (with file:line quotes) or [I] inferred; unanswered items explicitly marked NOT EVIDENCED, plus a list of open questions requiring live access and a residual-risks section."
    }
  ],
  "changedFiles": [
    "/Users/emumba/.pi/agent/sessions/--Users-emumba-Downloads-projects-zlt-x16--/subagent-artifacts/outputs/afe79b7e-26d1-44c7-ba8f-063033cd8dec/context.md",
    "/tmp/notes-device-profile/raw-quotes.txt"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "objdump -d --triple=armv7-linux-gnueabihf --start-address=0x6558 --stop-address=0x6800 firmware-analysis/dialer",
      "result": "passed",
      "summary": "Disassembled sunsea_send_at_with_format; confirmed tATCMD_Request framing and sockmsg_send_common_msg call (no tty)"
    },
    {
      "command": "python3 -c 'read dialer ELF header'",
      "result": "passed",
      "summary": "32-bit LSB, EM_ARM 0x28, ET_DYN, e_flags 0x05000400 (EABI5 + hard-float)"
    },
    {
      "command": "grep -rhoE '/dev/[A-Za-z0-9_./-]+' firmware-analysis/",
      "result": "passed",
      "summary": "Only /dev/null, /dev/zero, /dev/ipa - no tty/smd/ttyUSB nodes anywhere"
    },
    {
      "command": "json parse of zlt-*/router.jsonl",
      "result": "passed",
      "summary": "Banner, MemTotal 661264 kB, interfaces, routes, conntrack 201/45056, dmesg IPA/SSR lines"
    }
  ],
  "validationOutput": [
    "Banner in all 5 captures: 'QTI Linux reference nogplv3 distro targeting performance builds. 8e4f3af sdxlemur' with '/ #' prompt",
    "MemTotal: 661264 kB / MemAvailable: 505908 kB / conntrack max 45056",
    "dialer DT_NEEDED: ld-linux-armhf.so.3, libsystemd.so.0, libolinterface.so.1, libqmi*.so.1, libc.so.6",
    "Build path: SDX65_LE12_AP / build-qti-distro-nogplv3-perf / tmp-glibc / armv7vet2hf-neon-oe-linux-gnueabi / glibc 2.31 / GCC 9.3.0"
  ],
  "residualRisks": [
    "Kernel version, CPU core count, flash size/partition layout, tmpfs sizes and free space on /data are NOT evidenced by any local artifact - no df/mount/proc-partitions capture exists. A live 'uname -a', 'df -h', 'mount' is mandatory before sizing or installing anything.",
    "Web UI specifics (which server binary, exact docroot, CGI path, and whether 8080 is also used) are NOT evidenced. Ports 80/443 open on LAN is inferred only from WAN-side DROP rules in basic_prv.strings:544-545.",
    "Absence of wget/jq/python/sms_tool/microcom/lighttpd/socat is absence-of-evidence only: the three extracted binaries are the data-path daemons, not the full rootfs. Do not treat the tools list as exhaustive.",
    "BusyBox/ash and 'curl < 7.75' are inferences from prompt shape and a runtime error string respectively, not from a version query.",
    "rootfs rw vs rw-overlay is inferred from successful /etc/systemd/system writes; the mount topology itself was never captured.",
    "The /data size conclusion rests on a single historical 43.7 MB coredump existing there - a lower bound, not capacity.",
    "AT contention conclusion assumes libmdlsockmsg's bus is unshared across clients; the AT daemon's own serialization was not inspected (not present in the extracted set)."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added the device-profile report at the configured artifact path plus verbatim scratch quotes under /tmp/notes-device-profile/. No repository source files were modified.",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "Two findings are likely to change the parent's plan: (1) there is NO spare AT port or tty on this device - the SIM8260E is on-die SDX65 and all AT traffic is brokered over Sunsea's private sockmsg IPC bus to APP_ID_ATCMD, serialized only by an in-process mutex; the dialer polls AT every second and reboots the router after repeated AT send failures, so a new app must NOT use AT and should use QMI/QRTR instead (qmicli over QRTR is already proven working on this box per DIAGNOSIS.md:147, and libqrtr.so.1 is installed). (2) /etc is writable and systemd is the init, and router-fix/zlt-wan-fix.service already demonstrates a clean, reversible pattern: unit in /etc/systemd/system, payload in /data/<app>/, sequenced After=TZApp.service. That is the recommended home for a new app and service. Also worth flagging: basic_prv hard-codes 'TCPMSS --set-mss 1460' for bridge0<->rmnet_data0, which independently corroborates the MTU defect in DIAGNOSIS.md."
}
```
