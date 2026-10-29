# IPACM enablement (IPA hardware offload)

Status: **working and verified across reboots**.
Date: 2026-10-26. Device firmware `1.0.39.11`, SDXLEMUR-LITE (SDX65-class,
ARMv7, 1 core), kernel 5.4.210, systemd 244.

Module: [`router-fix/ipacm/`](../router-fix/ipacm/README.md) (`./install.sh`,
`--check`, `--uninstall`).

## Symptom

`ipacm.service` failed on every boot, so nothing ever programmed IPA:

```
ipacm.service  loaded failed failed   (status=255/EXCEPTION)
/sys/kernel/debug/ipa/ip4_rt   0 rules
/sys/kernel/debug/ipa/ip4_nat  0 rules
/sys/kernel/debug/ipa/ip4_flt  0 rules
```

All LAN `<->` WAN forwarding ran as software NAT on the single CPU core.

## What is actually wrong (four separate traps)

1. **The daemon dies at boot.** `/usr/bin/ipacm` is exec'd while IPA/modem
   bring-up is in flight, returns `-1` (exit code 255), and the unit ends the
   boot failed. Ordering in the shipped units was already correct
   (`After=start_cfgd.service start_stop_ipa_fws.service`,
   `Before=QCMAP_ConnectionManagerd.service`), so ordering drop-ins are useless.

2. **`/etc` systemd content is invisible at boot.** `/` (rootfs) is a read-only
   ubifs; the writable `/etc` + `/data` volume (`/dev/ubi2_0`, "usrfs") is
   mounted by `userdata-ubi-mount.sh` at **~10.6 s**, *after* systemd has loaded
   its units. Any unit file or drop-in under `/etc/systemd/system` is therefore
   never seen during that boot -- which is also why `qmanager-*.service` and
   `zlt-wan-fix.service` do **not** run after a reboot.

3. **The mount script cannot be patched.** `userdata-ubi-mount.sh` is already
   executing from the read-only rootfs copy when the writable volume is mounted
   over `/etc`, so edits to its `/etc` copy never run (and it ends with
   `exit 0`, so appended hooks are dead anyway).

4. **`systemd-run` is refused until ~36 s** into boot:
   `Transaction for X/start is destructive (shutdown.target has 'start' job
   queued, but 'stop' is included in transaction)`.

## What was deployed

`/etc/initscripts/ipacm-starter.sh` -- supervisor: waits for `/dev/ipa` +
`/dev/ipaNatTable`, runs ipacm in the foreground (meaningful exit code),
retries boot-race exits with exponential backoff, honours SIGTERM, kills any
foreign `ipacm` every 10 s, logs to `/data/log/ipacm.log` through a FIFO/awk
filter (ipacm emits ~570 lines/10 s under connection churn -- real flash wear
on the volume that holds `/etc`), and trims the log to its newest half past
256 KiB. When it sees `Received wan ipv4-addr`, it creates the persistent
`/data/log/ipacm-wan-learned` marker, so check status survives log rotation.

`/etc/initscripts/zlt-ipacm.sh` -- `boot|start|reassert|status|stop`
controller. Spawns the supervisor **detached with `setsid`** (not as a systemd
unit, see traps 2 and 4) and tracks it in `/var/run/zlt-ipacm.pid`.

`/etc/initscripts/start_cfgd` -- hook inserted directly after the shebang. It
is the first script that runs from the writable `/etc` volume (~12 s) and it
finishes long before the dialer assigns the WAN address. It calls
`zlt-ipacm.sh boot` and schedules `zlt-ipacm.sh reassert` at +90 s (as a
transient `systemd-run` timer, which works once boot has settled).

## Why the timing matters (the crux)

ipacm learns the WAN address **only** from an rtnetlink `RTM_NEWADDR` event for
an interface declared `<Category>WAN</Category>` in `/etc/data/ipa/IPACM_cfg.xml`.
It does not enumerate existing addresses at startup -- its conntrack listener
shows it plainly when it missed the event:

```
IPACM_ConntrackListener.cpp:2584 ... equal to wan ip:0x0
```

Restarting ipacm or QCMAP after the data call is up does not help, and
re-applying the identical address with `ifconfig` produces no netlink event.
So ipacm must be running **before** the dialer assigns the address (~27 s).
With the boot hook it is up at **~23 s** and does catch it:

```
IPACM_Wan.cpp:887 handle_addr_evt() Received wan ipv4-addr:0xaedf435
```

Consequence: restarting the supervisor by hand loses offload until the next
data-call reconnect or reboot.

## Verified state after reboot

```
supervisor   running (pid 478)
ipacm        541                       <- up at 22.96 s
vendor unit  inactive                  <- its own ipacm is cleared at boot
WAN          10.237.244.53/32, default route present
internet     ping 1.1.1.1 OK; LAN client 192.168.3.126 reachable
/sys/kernel/debug/ipa/stats: `hw_tx` increasing, `sw_tx=0` (latest live check)
```

The persistent `/data/log/ipacm-wan-learned` marker records that the WAN
address event was received even when the bounded log rotates.

Earlier boot, when a LAN flow started, the IPA driver programmed hardware
rules:

```
[  163.7] ep_idx:8 rule_idx:0 act:3 rt_tbl_idx:0
[  163.8] ep_idx:8 rule_idx:1 act:1 rt_tbl_idx:4
[  163.9] ep_idx:8 rule_idx:2 act:1 rt_tbl_idx:2
```

Note: `ip4_rt`, `ip4_nat`, `ip4_flt` and `hw_stats` under
`/sys/kernel/debug/ipa/` read **empty on this build even with rules installed**,
so do not use them as the pass/fail signal. Prefer the persistent marker
`/data/log/ipacm-wan-learned`, `AddORDeleteNatEntry` activity and
`/sys/kernel/debug/ipa/stats` (`hw_tx` vs `sw_tx`). `dmesg | grep rule_idx`
showed hardware rule programming during the earlier verified run, but is a
volatile ring buffer and may not retain those entries later in the boot.

## Operations

```sh
/etc/initscripts/zlt-ipacm.sh status     # supervisor / ipacm / vendor unit
/etc/initscripts/zlt-ipacm.sh stop       # back to software NAT immediately
/etc/initscripts/zlt-ipacm.sh start      # restart (offload arms at next WAN event)
kill -USR1 $(pidof ipacm)                # SW_ROUTING_ENABLE  (force software path)
kill -USR2 $(pidof ipacm)                # SW_ROUTING_DISABLE (allow hardware path)
```

Rollback: `router-fix/ipacm/install.sh --uninstall` (removes the hook, the two
scripts and the legacy drop-in, stops the supervisor).

## Should it stay enabled?

Measured on this unit: `eth0` links at **100 Mb/s** (single LAN bridge port),
one CPU core online, ~2-3 % CPU on normal traffic. The wire, not the CPU, is
the bottleneck today, so the gain is thermal/power headroom and headroom for
1G/2.5G (the `r8125_ioss` driver already votes IPA bandwidth).

The cost to watch: offloaded flows bypass netfilter, so `iptables -t nat -L -v`
counters stop moving for them -- that affects the `FORWARD` MSS clamp from
`router-fix/zlt-wan-fix.sh` and any QoS/accounting. Re-check forwarded TCP
after enabling offload on a link whose MSS matters.
