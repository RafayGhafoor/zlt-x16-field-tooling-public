# IPACM supervisor (IPA hardware offload)

Keeps the vendor `/usr/bin/ipacm` alive so IPA can carry LAN `<->` WAN flows
instead of leaving the NPU idle behind software NAT.

Background, evidence and activation state:
[`docs/18-ipacm-enablement.md`](../../docs/18-ipacm-enablement.md).

## Files

| File | Installed to | Purpose |
|---|---|---|
| `ipacm-starter.sh` | `/etc/initscripts/ipacm-starter.sh` | supervisor: waits for IPA nodes, foreground exec, retries with backoff, filtered logging to `/data/log/ipacm.log`, persistent WAN-event marker at `/data/log/ipacm-wan-learned` |
| `zlt-ipacm.sh` | `/etc/initscripts/zlt-ipacm.sh` | `boot\|start\|reassert\|status\|stop` controller, spawns the supervisor detached (`setsid`) with `/var/run/zlt-ipacm.pid` |
| `boot-hook.txt` | inserted at the top of `/etc/initscripts/start_cfgd` | starts the supervisor at ~12 s and schedules a +90 s re-assert |
| `install.sh` | — | host-side installer / verifier / uninstaller |

## Deploy on a fresh router

```sh
./install.sh              # install + start + verify
./install.sh --check      # verify only
./install.sh --uninstall  # revert to vendor behaviour
```

`ZLT_HOST` overrides the ssh target (default `zlt-root`, i.e. `root@192.168.3.1`).
The installer is idempotent, backs up replaced files to
`/data/zlt-backups/<date>/ipacm/`, streams files with `ssh 'cat > path'` (`scp`
is broken: no `sftp-server`) and retries every ssh call.

## Why it is not a systemd unit

1. `/` is a read-only ubifs and the writable `/etc` volume is mounted at
   **~10.6 s**, *after* systemd has loaded its units -- so a unit or drop-in
   under `/etc/systemd/system` is invisible for that boot. (This is also why
   `qmanager-*.service` and `zlt-wan-fix.service` do not come back after a
   reboot.)
2. `userdata-ubi-mount.sh` (the script that mounts `/etc`) is already executing
   from the read-only rootfs copy, so patching its `/etc` copy never runs.
3. `systemd-run` is rejected until ~36 s into the boot
   (`Transaction ... is destructive (shutdown.target has 'start' job queued)`).

Hence: a plain detached supervisor, started from the first hookable script.

## Why the boot hook is at the top of `start_cfgd`

ipacm learns the WAN address **only** from an rtnetlink `RTM_NEWADDR` event; it
never enumerates addresses at startup. It must therefore be running before the
dialer assigns the address (~27 s). Started from the top of `start_cfgd` it is
up at **~23 s** and catches the event. Restarting it by hand loses offload
until the next data-call reconnect or reboot.

## Verify

```sh
/etc/initscripts/zlt-ipacm.sh status
test -e /data/log/ipacm-wan-learned && echo 'WAN address event observed'
grep -a "Received wan ipv4-addr" /data/log/ipacm.log | tail -1
grep -a "AddORDeleteNatEntry"    /data/log/ipacm.log | tail -3
cat /sys/kernel/debug/ipa/stats
dmesg | grep "rule_idx" | tail -3
```

`ip4_rt` / `ip4_nat` / `ip4_flt` / `hw_stats` under `/sys/kernel/debug/ipa/`
read **empty on this build even with rules installed** -- they are not a
pass/fail signal. `/sys/kernel/debug/ipa/stats` is useful: on the verified boot
it reported `hw_tx=22159`, `sw_tx=0`.

## Caveat once offload is live

Offloaded flows bypass netfilter: `iptables -t nat -L -v` counters freeze for
them, which affects the `FORWARD` MSS clamp installed by
`router-fix/zlt-wan-fix.sh` and any QoS/accounting.

## Kill switches (verified on device)

```sh
/etc/initscripts/zlt-ipacm.sh stop     # instant revert to software NAT
kill -USR1 $(pidof ipacm)              # SW_ROUTING_ENABLE
kill -USR2 $(pidof ipacm)              # SW_ROUTING_DISABLE
```
