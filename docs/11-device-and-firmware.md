# 02 — Device, Firmware and Filesystem

## Identity

| Property | Value |
|---|---|
| Product | ZLT X16 (Ooredoo Oman variant) |
| SoC | Qualcomm SDX65 (`sdxlemur` platform) |
| Modem | SIMCom SIM8260E |
| Modem baseband | `MPSS.DE.2.0-01026-OLYMPIC_GENALL_PACK-1` |
| Kernel | `Linux 5.4.210-perf #7 PREEMPT Fri Jan 5 14:02:11 CST 2024 armv7l` |
| Web/admin firmware version | **`1.09.39.10`** |
| Config version | `X16-OMN247-4.00` |
| Update config version | `X16-OMN247-4.00UP` |
| Area / product config | `OMN247` (**Ooredoo Oman**) |
| LAN IP / subnet | `192.168.3.1/24` |

## Version strings — and the "firmware 1.5" claim

The customer asked for an upgrade **"from 1.5 to 2.x"**. The device is not on
1.5:

```
SYS_FW_USER_VER = 1.09.39.10
SYS_CFG_VER     = X16-OMN247-4.00
```

**A 2.0.x build does exist for this exact product.** A public report for a
ZLT X16 with the same `OMN247` configuration lists:

```
Software Version: 2.0.0.5
Configuration:    X16-OMN247_4.0.04 + X16-OMN247-UP_4.0.06
Modem:            SIMCOM SIM8260E (Qualcomm SDX65)
Source: https://github.com/mattfaraday/vn007/issues/8
```

So the *shape* of the customer's request is legitimate — there is a newer
generation — but the version numbers they quoted are wrong, and the reason given
(NAT table) is not supported by this device's evidence. See doc 12.

## Build components

From `/firmware/image/Ver_Info.txt`:

```
aop        AOP.HO.3.3-00046-OLYMPICAAAAANAZO-1
apps       LE.UM.6.2.3.r1-06200-SDX65.0-1
boot       BOOT.MXF.1.1.1-00175-Olympic-1
modem      MPSS.DE.2.0-01026-OLYMPIC_GENALL_PACK-1
tz         TZ.FU.5.15-00070-OLYMPICAAAAANAZT-1
tz_apps    TZ.APPS.1.15-00036-OLYMPICAAAAANAZT-1
wlan_hsp   WLAN.HSP.1.1.3-00545-QCAHSPSWPL_V1_V2_SILICONZ_LITE-1
Time_Stamp 2023-02-15 17:44:35
```

The applciation/OS build is from **Feb 2023**; the kernel image is dated
**Jan 2024**. The ODU modem package is `ZLT_X16_ODU_user_20240105_1.0.39.11`.

## Filesystem layout

```
ubi0:rootfs  ->  /              ro, ubifs      ~ all vendor binaries, /usr, /bin
ubi0:systemrw->  /systemrw      rw, ubifs      WLAN binaries
ubi1_0       ->  /firmware      ro, ubifs      modem/MBN/model images (amss20.bin, mcfg_sw, ...)
ubi2_0       ->  /etc           rw, ubifs      persistent config
ubi2_0       ->  /data          rw, ubifs      persistent data, logs, our SSH install
              ->  /tmp          tmpfs          volatile
              ->  /var/volatile tmpfs          volatile
```

Practical consequences:

- **You cannot write to `/`, `/usr`, `/bin`, `/system`, `/firmware`.**
- **`/data` and `/etc` are the only persistent writable locations.**
- Anything placed in `/tmp` is gone after reboot.
- `/etc/initscripts/` **is** writable and persistent, which is why the SSH
  boot-wiring lives there.

## Memory and CPU headroom

```
MemTotal:     661264 kB (~645 MiB)
MemAvailable: ~499 MB
load average: ~1.0 - 1.3 on 4 cores
```

Memory is not a constraint. Refer to doc 12 for why the device nevertheless
stalls.

## Users and accounts

`/etc/passwd` has the usual Android/QTI set plus a uid-0 account added during
this work:

```
root:x:0:0:root:/data/root:/bin/sh        <- home moved off read-only rootfs
zlt:x:0:0:ssh admin:/data/zlt:/bin/sh     <- added; uid 0; convenience account
```

`/etc/shadow` — the original root hash was backed up to `/data/ssh/shadow.bak`
and root's password is now `<redacted-password>`:

```
root:$1$<redacted-password>$jDknnw.sHbOUg2iIvC2s//:...
```

## Vendor-installed SSH key (security finding)

`/home/root/.ssh/authorized_keys` shipped from the factory containing a single
key, **not** belonging to the customer:

```
ssh-rsa AAAA... linweiqiang@server
```

That is a vendor/SDK engineer key baked into the image. It is preserved (it was
copied into `/data/root/.ssh/authorized_keys` as well) so nothing was silently
destroyed, but it should be removed from the router's trust if the customer does
not have a vendor support relationship that requires it.

## Services of interest

| Unit | State | Note |
|---|---|---|
| `TZApp.service` | active (exited) | the whole vendor app; runs `StartTZApp` once |
| `QCMAP_ConnectionManagerd.service` | running | QCMAP present but **not** the WAN owner |
| `QCMAP_Web_CLIENT.service` | running | |
| `zlt-dropbear.service` | active | added by us (doc 10) |
| `zlt-ssh-watchdog.timer` | **inactive (dead)** — `enabled`, but has **never** triggered (see doc 14 §10) | added by us (doc 10) |
| `zlt-wan-fix.service` | **inactive (dead)** but `enabled` | pre-existing MTU workaround that never actually ran — see doc 14 |

`/etc/rc.local` (the vendor boot hook) only applies `fq_codel` shaping on the
WAN interface:

```sh
tc qdisc replace dev rmnet_data0 root fq_codel limit 20480p flows 4096 \
   quantum 1514 target 20ms interval 400ms memory_limit 64Mb ecn
tc qdisc change  dev rmnet_data0 root fq_codel quantum 1600 target 15ms interval 200ms
```

## Manual `mdlcfg` reference

`mdlcfg` is the vendor's config database tool. It is **not** `key=value` on the
command line for reads:

```bash
mdlcfg -g KEY      # get
mdlcfg -a KEY=VAL  # assign (in memory)
mdlcfg -c          # commit to flash  <-- easy to forget
mdlcfg -e          # export everything
```

`mdlcfg get ...` silently does nothing. This tripped us up early on.

Key values relevant to this investigation:

```
SYS_FW_USER_VER         1.09.39.10
SYS_CFG_VER             X16-OMN247-4.00
USR_APN_NAME            Ufone.internet
USR_APN_MTU             1400
USR_DHCP_MTU            1500
USR_DHCP_MSS            0
USR_APN_PDP_TYPE        IP
SYS_INTERNET_LIMIT_SWITCH   0
SYS_TELNET_SWITCH       0
USR_IDU_TELNET_SWITCH   0
SYS_SSH_SWITCH          1     <- added by us
```
