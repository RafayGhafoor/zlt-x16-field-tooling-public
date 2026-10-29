# 06 — Change Log: what was changed on the device

Session date: **2026-10-26** (router clock `+04`, Ooredoo Oman timezone).
Router uptime at end of session: ~1 h 5 min (the box was **not** rebooted).

Everything below is on the persistent volumes `/data` and `/etc` unless noted.

---

## A. SSH enablement

| Path | Action |
|---|---|
| `/data/ssh/dropbear` | **new** — dropbear 2020.80, copied from GreenPacket O5A (`/usr/sbin/dropbear`, md5 `b41123642b356fbddd5043f1989e2a4e`) |
| `/data/ssh/dropbearkey` | **new** — copied from GreenPacket (`/usr/bin/dropbearkey`, md5 `0f52cf72a4edde13a34f611e50af73b0`) |
| `/data/ssh/dropbear_rsa_host_key` | **new** — generated on-device with `dropbearkey -t rsa -s 2048` |
| `/data/ssh/dropbear_ed25519_host_key` | **new** — generated on-device |
| `/data/ssh/shadow.bak` | **new** — copy of `/etc/shadow` before the password change |
| `/etc/initscripts/start_ssh` | **new** — start/stop/restart, mirrors `start_telnet`, gated by `SYS_SSH_SWITCH` |
| `/etc/initscripts/StartTZApp` | **modified** — two lines added after the telnet block |
| `/data/backup-StartTZApp.orig` | **new** — pristine copy of the original `StartTZApp` |
| `/etc/systemd/system/zlt-dropbear.service` | **new** — oneshot wrapper (also `chkconfig`-enabled) |
| `/etc/systemd/system/zlt-ssh-watchdog.service` | **new** — re-asserts SSH |
| `/etc/systemd/system/zlt-ssh-watchdog.timer` | **new** — every 2 min (enabled) |
| `mdlcfg SYS_SSH_SWITCH=1` | **new key** — committed with `mdlcfg -c` |

### The `StartTZApp` patch

```diff
 	### telnet
 	/etc/initscripts/start_telnet start
+	### ssh (added: mirrors telnet wiring, GATED by SYS_SSH_SWITCH)
+	/etc/initscripts/start_ssh start
 
 	### 看门狗
```

### Firewall

Added, re-asserted automatically at boot and every 2 minutes:

```
iptables -I INPUT 1 -i bridge0 -p tcp --dport 22 -j ACCEPT
```

Scoped to `bridge0` (LAN) only. The WAN-side
`input_mdl_chain -i rmnet_data0 --dport 22 -j DROP` is untouched, so SSH is not
exposed on cellular.

---

## B. Accounts and passwords

| Change | Before | After |
|---|---|---|
| `root` password | `$1$b7X30f8f$...` (unknown plaintext) | `<redacted-password>` — `$1$<redacted-password>$jDknnw.sHbOUg2iIvC2s//` |
| `root` home | `/home/root` (read-only, group-writable) | `/data/root` (0700 root:root) |
| `zlt` user | did not exist | **added**, uid 0, home `/data/zlt`, password `<redacted-password>` |

The original root hash is preserved in `/data/ssh/shadow.bak`.

Why the home move: dropbear refuses `~/.ssh/authorized_keys` when the home
directory is group/world-writable. `/home/root` is `drwxrwxr-x` on a **read-only**
filesystem, so it could not be fixed in place.

Side effect: `/etc/profile` adds `/sbin` to `$PATH` only when
`$HOME == /home/root`, so root over SSH previously could not see `ip` or
`iptables`. It can now.

### SSH keys installed

Seven keys are now in `/data/root/.ssh/authorized_keys` (and
`/data/zlt/.ssh/authorized_keys`):

1. `linweiqiang@server` — **the vendor's factory key, preserved from the original
   `/home/root/.ssh/authorized_keys`** (not added by us)
2. `emumba-mac-x28` (ed25519)
3. `rafay@rafay` (rsa)
4. `rafay.awan@emumba.com` (ed25519)
5. `rawan@extremenetworks.com` (ed25519)
6. `shop@M1-2.local` (ed25519, termux)
7. `shop@M1-2.local` (rsa 4096)

Also bind-mounted `/home/root/.ssh` ← `/data/root-ssh` so the legacy path still
resolves. This bind mount is **not persisted** across reboot and is not required
(see doc 10).

---

## C. Files fetched to the router (not persisted)

`/tmp/dropbear.gz`, `/tmp/dropbearkey.gz`, `/tmp/authorized_keys`,
`/tmp/start_ssh`, `/tmp/zlt-dropbear.service`, `/tmp/zlt-ssh-watchdog.*`,
`/tmp/small.bin`, `/tmp/small2.bin` — all on tmpfs, gone after reboot.

---

## D. Documentation and local tooling

| Path (local repo) | Purpose |
|---|---|
| `docs/README.md` | index |
| `docs/10-access-and-ssh.md` | access, SSH, boot wiring |
| `docs/11-device-and-firmware.md` | hardware/firmware/filesystem |
| `docs/12-speedtest-disconnect-diagnosis.md` | the reported fault |
| `docs/13-greenpacket-comparison.md` | config diff vs GreenPacket O5A |
| `docs/14-config-defects-and-fixes.md` | defects + severities + fixes |
| `docs/15-change-log-on-device.md` | this file |
| `router-fix/start_ssh` | source of truth for `/etc/initscripts/start_ssh` |

Local helper scripts used during the session (in `/tmp`, not committed):

- `/tmp/zlt_put.py` — chunked base64 console uploader over telnet (used before
  SSH existed)
- `/tmp/zr.exp` — telnet command runner
- `/tmp/zssh`, `/tmp/zput` — SSH wrappers with retry (the device times out on
  roughly every second command)

Also added locally: `~/.ssh/config` entries

```
Host zlt-x16
	HostName 192.168.3.1
	User root
	IdentityFile ~/.ssh/id_ed25519
	Port 22
	StrictHostKeyChecking no
	UserKnownHostsFile /dev/null

Host zlt-root        # same, explicit
```

---

## E. What was NOT changed

Deliberately left alone, listed so nobody assumes otherwise:

- No firmware/OTA upgrade; no partition was written.
- No APN database patch (defect documented in doc 14 §1, not applied).
- No `iptables` change to `ack-flood` (doc 14 §2).
- No TTL rule added (doc 14 §6).
- No `sysctl` tuning applied (`tcp_mtu_probing`, `tcp_rmem`, `tcp_wmem`).
- `zlt-wan-fix.service` left as-is (enabled but idle; redundant — doc 14 §3).
- The vendor SSH key was **preserved**, not removed.
- Port-23 telnet was **left running** (the customer may still depend on it).
- No `dialer`/`basic_prv` binary patching; MBN untouched (`ROW_Commercial`
  still active from the 2026-09-01 session — **superseded**: see
  [46](46-mbn-switch-attempt.md), the modem now reports no software PDC config).

---

## F. Reverting everything

Fastest full revert of the SSH work:

```sh
# restore the boot hook
cp /data/backup-StartTZApp.orig /etc/initscripts/StartTZApp
chmod 755 /etc/initscripts/StartTZApp

# disable the services
systemctl disable --now zlt-dropbear.service zlt-ssh-watchdog.timer

# stop SSH + remove its firewall rule
/etc/initscripts/start_ssh stop

# turn the gate off
mdlcfg -a SYS_SSH_SWITCH=0 && mdlcfg -c

# optional: remove the binaries
rm -rf /data/ssh /data/root /data/zlt /data/root-ssh
```

Reverting the account changes (only if you want the original state back):

```sh
# restore the original root password hash
sed -i 's|^root:[^:]*:|root:$1$b7X30f8f$au21weqL.9.ExM4N84AtA0:|' /etc/shadow
sed -i 's|^root:x:0:0:root:/data/root:/bin/sh|root:x:0:0:root:/home/root:/bin/sh|' /etc/passwd
sed -i '/^zlt:/d' /etc/passwd /etc/shadow
```

> Leaving root's home at `/data/root` is harmless and is what makes key-based
> login work. Only revert it if something turns out to depend on `/home/root`.

---

## G. Verification checklist (run after any reboot)

```sh
ssh zlt-x16 'export PATH=/usr/sbin:/sbin:$PATH;
  echo "--- svc ---";   systemctl is-active zlt-dropbear.service zlt-ssh-watchdog.timer;
  echo "--- listen ---"; netstat -lnt | grep :22;
  echo "--- fw ---";    iptables -C INPUT -i bridge0 -p tcp --dport 22 -j ACCEPT && echo ACCEPT_OK;
  echo "--- gate ---";  mdlcfg -g SYS_SSH_SWITCH;
  echo "--- home ---";  grep "^root:" /etc/passwd;
  echo "--- keys ---";  grep -c "^ssh-" /data/root/.ssh/authorized_keys'
```

Expected: both services `active`, `:22` listening, `ACCEPT_OK`,
`SYS_SSH_SWITCH=1`, root home `/data/root`, 7 keys.
