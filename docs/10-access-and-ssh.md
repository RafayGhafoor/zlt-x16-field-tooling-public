# 01 — Access and SSH

## Summary

| Item | Value |
|---|---|
| Router LAN IP | `192.168.3.1` |
| Telnet | port 23, **no login prompt** — drops straight to `/ #` root shell |
| Telnet alternative | port 9876 via `/etc/initscripts/start_telnet` when `SYS_TELNET_SWITCH=1` |
| SSH (added) | port 22, dropbear 2020.80 |
| SSH user | `root` (uid 0). An alias account `zlt` (also uid 0) also exists |
| SSH password | `<redacted-password>` (set on both `root` and `zlt`) |
| SSH keys | Your 6 public keys installed for `root` and `zlt` |
| SSH autostart | `/etc/initscripts/start_ssh`, called from `/etc/initscripts/StartTZApp` |
| SSH firewall | `iptables -I INPUT 1 -i bridge0 -p tcp --dport 22 -j ACCEPT` |

On this machine, `~/.ssh/config` has a matching `Host zlt-x16` entry, so simply:

```bash
ssh zlt-x16
# or
sshpass -p <redacted-password> ssh -o PreferredAuthentications=password root@192.168.3.1
```

## How access used to work

The box ships `busybox telnetd` but the vendor gates it behind two mdlcfg
switches, **both of which are `0` on this unit**:

```
SYS_TELNET_SWITCH       = 0
USR_IDU_TELNET_SWITCH   = 0
```

The telnet you reach on port 23 is **not** the vendor path — it is a debug
toggle fired from the web UI, which is stored as a saved CGI call in:

```
/productinfo/tzcfg/iptables/iptables_dmz_function
  {"enabled":"1","ip":"127.0.0.1;busybox telnetd -l /bin/sh","cmd":172,"subcmd":6,...}
```

Consequences worth knowing:

- Port 23 telnet is a **root shell with no authentication**. It is reachable
  from anywhere on the LAN. Treat it as a standing security hole; turn it off
  once SSH is confirmed working (see "Disabling telnet" below).
- Because it is a runtime toggle, it disappears if the TZ app re-runs it as part
  of a config write. It *did* survive the boot we observed, so something in the
  boot path re-issues it — but do not rely on it.

## How SSH was enabled

The firmware has **no SSH server at all**. `find / -name '*dropbear*'` returns
nothing and there is no opkg feed. So dropbear was transplanted from the
GreenPacket O5A in this estate, which runs the *same* SoC and userspace:

| | ZLT X16 | GreenPacket O5A |
|---|---|---|
| Kernel | `5.4.210-perf armv7l` | `5.4.210-perf armv7l` |
| C library | glibc 2.31, `ld-linux-armhf.so.3` | glibc 2.31, `ld-linux-armhf.so.3` |
| ABI | ARM EABI5 hard-float, 32-bit | ARM EABI5 hard-float, 32-bit |

Because the two are ABI-identical the binary runs unmodified.

### Transfer method

`scp` is not available on either side (`/usr/libexec/sftp-server` missing), and
the router's `base64` is BusyBox so `-w0` is unsupported. The working recipe:

```bash
# pull from greenpacket as base64, decode locally
ssh greenpacket 'base64 /usr/sbin/dropbear' | base64 -d > /tmp/dropbear

# push to the ZLT. SSH did not exist yet, so this went over the telnet console
# using chunked `cat >> file << 'ZEOF'` heredocs at ~11 KB/s.
python3 /tmp/zlt_put.py /tmp/dropbear.gz /tmp/dropbear.gz
```

`/tmp/zlt_put.py` is the console uploader used. Once SSH is up, plain
`ssh zlt-x16 'cat > /dest' < localfile` is far simpler.

### Host keys

Do **not** hand dropbear an OpenSSH PEM key — it fails with
`Early exit: String too long`. Use `dropbearkey`:

```bash
dropbearkey -t rsa     -f /data/ssh/dropbear_rsa_host_key -s 2048
dropbearkey -t ed25519 -f /data/ssh/dropbear_ed25519_host_key
chmod 600 /data/ssh/dropbear_*_host_key
```

Current fingerprints live in `/data/ssh/`. `dropbearkey` is on the box at
`/data/ssh/dropbearkey` in case keys need rotating.

### Why root key auth initially failed

dropbear refuses `~/.ssh/authorized_keys` when the home directory is
group/world-writable. `/home/root` is `drwxrwxr-x` and is on the **read-only**
rootfs, so it can neither be `chmod`-ed nor written to. That is why keys placed
in `/home/root/.ssh` had no effect.

Fix applied — root's home moved to the writable volume:

```
/etc/passwd:  root:x:0:0:root:/home/root:/bin/sh
           -> root:x:0:0:root:/data/root:/bin/sh
```

`/data/root` is `0700 root:root`, so dropbear accepts the keys. A useful side
effect: `/etc/profile` only appends `/sbin` to `$PATH` when `$HOME == /home/root`,
so root over SSH previously could not see `ip` or `iptables`. It can now.

`/home/root/.ssh/authorized_keys` was also bind-mounted over from
`/data/root-ssh` so the vendor path keeps working; this is optional and not
persisted.

## Boot wiring (the important part)

The vendor's own pattern is a shell script under `/etc/initscripts/`, invoked by
`TZApp.service`. Telnet shows the template:

```
TZApp.service
  └─ ExecStart=/etc/initscripts/StartTZApp start
       └─ line 14-15:  ### telnet
                       /etc/initscripts/start_telnet start
            └─ reads mdlcfg SYS_TELNET_SWITCH; if 1 -> telnetd -p 9876
```

SSH is wired identically:

```
TZApp.service
  └─ /etc/initscripts/StartTZApp
       ├─ line 14-15:  /etc/initscripts/start_telnet start
       └─ line 16-17:  ### ssh (added)
                       /etc/initscripts/start_ssh start     <-- new
            └─ reads mdlcfg SYS_SSH_SWITCH; if 1 -> firewall allow + dropbear -p 22
```

Files involved (source of truth is [`../router-fix/start_ssh`](../router-fix/start_ssh)):

| Path | Purpose |
|---|---|
| `/etc/initscripts/start_ssh` | start/stop/restart logic, idempotent |
| `/etc/initscripts/StartTZApp` | patched; original kept at `/data/backup-StartTZApp.orig` |
| `/etc/systemd/system/zlt-dropbear.service` | `Type=oneshot` wrapper calling `start_ssh start` |
| `/etc/systemd/system/zlt-ssh-watchdog.{service,timer}` | re-asserts SSH every 2 min |
| `mdlcfg SYS_SSH_SWITCH` | `1` = enabled (new key, added by us) |

### Why the firewall rule is needed

TZApp builds an `nmap_scan` chain that unconditionally drops SYNs to port 22 on
**every** interface:

```
-A INPUT -j nmap_scan
-A nmap_scan -p tcp --dport 22 --tcp-flags ALL SYN -j DROP
```

That is why port 22 was unreachable even after dropbear was listening. Because
TZApp *rebuilds* iptables during boot, the allow rule must be inserted **after**
TZApp has run — which is exactly where `start_ssh` sits:

```
iptables -C INPUT -i bridge0 -p tcp --dport 22 -j ACCEPT \
  || iptables -I INPUT 1 -i bridge0 -p tcp --dport 22 -j ACCEPT
```

It is scoped to `-i bridge0` on purpose, so SSH is **not** exposed on the
cellular WAN. `input_mdl_chain` also has an explicit
`-i rmnet_data0 -p tcp --dport 22 -j DROP`, which still applies.

The 2-minute watchdog timer exists because this device intermittently drops its
listeners/network stack for tens of seconds (see doc 12). `start_ssh` is
idempotent, so the timer firing while SSH is healthy is a no-op.

## Operating it

```bash
# status
ssh zlt-x16 'export PATH=/usr/sbin:/sbin:$PATH;
             systemctl is-active zlt-dropbear.service zlt-ssh-watchdog.timer;
             netstat -lnt | grep :22'

# restart
ssh zlt-x16 '/etc/initscripts/start_ssh restart'

# disable SSH entirely (same idiom as telnet)
ssh zlt-x16 'export PATH=/usr/sbin:/sbin:$PATH;
             mdlcfg -a SYS_SSH_SWITCH=0 && mdlcfg -c;
             systemctl disable --now zlt-dropbear.service zlt-ssh-watchdog.timer;
             /etc/initscripts/start_ssh stop'
```

### Disabling telnet (recommended once SSH is trusted)

Telnet is an unauthenticated root shell. There is no mdlcfg switch for the
port-23 instance — kill it directly:

```bash
killall telnetd
```

and remove the saved web-UI debug toggle so it does not come back:

```bash
mv /productinfo/tzcfg/iptables/iptables_dmz_function \
   /productinfo/tzcfg/iptables/iptables_dmz_function.disabled
```

## Gotchas

- **No `python`/`python3` on the device.** Use `sh`/`awk`/`sed` only.
- **`/` and `/firmware` are read-only ubifs.** Persistent writable space is
  `/data` and `/etc` (both on `ubi2_0`). `/tmp` is tmpfs and vanishes on reboot.
- **Never run `grep -r` across `/system`, `/usr`, `/tzwww`.** Doing so stalls the
  whole device for minutes (observed twice). Use targeted paths.
- The device flaps: expect `Operation timed out` on roughly every second or third
  command. The retry helpers used here are:
  - `/tmp/zssh '<command>'` — retries an SSH command up to 40 times
  - `/tmp/zput <local> <remote>` — retries an upload
