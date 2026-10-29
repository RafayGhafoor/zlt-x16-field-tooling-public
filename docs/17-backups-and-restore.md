# 17 — Backups and Restore

Rule for this device: **back up before you touch, and write down where the
backup is.** Every change made by this tooling has a pristine copy that can be
put back without a factory reset.

---

## Where the backups live

### On the device (authoritative)

```
/data/zlt-backups/2026-10-26/
├── restore.sh                     <- executable restore script
├── etc/initscripts/               <- ALL 82 vendor boot scripts (pristine)
│   ├── StartTZApp.orig            <- POSITIVELY pristine (no start_ssh/zlt-fwtune)
│   ├── StartTZApp.before-reorder  <- mid-session snapshot (has start_ssh, wrong order)
│   └── ...                        <- every other vendor script, unmodified
├── etc/passwd.orig                <- reconstructed pre-change /etc/passwd
├── etc/shadow.orig                <- original root password hash
├── etc/group.orig
├── apns-conf_8.xml.orig           <- vendor APN database (contains the Jazz typo)
├── mobileap_cfg.xml.orig
├── rc.local.orig
└── mdlcfg/
    ├── mdlcfg-full-now.txt        <- full `mdlcfg -e` dump
    └── keys-we-added.txt          <- the two switches we introduced
```

Total size: ~652 KB. `/data` is on `ubi2_0` and **persists across reboot**.

Vendor originals also preserved separately at:

| Path | What |
|---|---|
| `/data/backup-StartTZApp.orig` | first pristine copy taken before the first patch |
| `/data/ssh/shadow.bak` | `/etc/shadow` before the password change |

### In the repo (mirror, for reference and diffing)

```
device-etc/backup-2026-10-26/      <- byte-identical mirror (90 files, ~656 KB)
device-etc/initscripts/            <- all 82 initscripts as plain text, for easy grepping
```

These were pulled with a base64 loop over SSH and verified by re-decoding; see
`/tmp/backup.dump` for the raw transfer if it is still present.

---

## What is backed up, and what is NOT

| Backed up | Not backed up (and why) |
|---|---|
| `/etc/initscripts/*` (all) | Modem firmware / MBN partitions — never modified |
| `/etc/passwd`, `/etc/shadow`, `/etc/group` | `/firmware` (read-only, untouched) |
| `/etc/rc.local` | The full `/etc` tree — too large, and untouched elsewhere |
| `apns-conf_8.xml`, `mobileap_cfg.xml` | `/data/qmanager` (deployed separately, ~16.7 MB) |
| Full `mdlcfg` dump | Raw EFS / SIM / identity / RF calibration — deliberately not dumped |

> **Not captured:** there is no full NVRAM/EFS image. If the modem itself is
> corrupted, this backup will not restore it. That requires the vendor tool.

---

## Restore procedures

### Full revert of everything this tooling changed

```sh
ssh zlt-x16 'sh /data/zlt-backups/2026-10-26/restore.sh all'
ssh zlt-x16 'reboot'
```

`all` performs, in order:

1. `StartTZApp` → pristine (removes `start_ssh` + `zlt-fwtune` hooks)
2. removes the `iptables … --dport 22 ACCEPT` rule
3. sets `SYS_ACKFLOOD_SWITCH=0` (vendor `ack-flood` returns on next boot)
4. stops + disables `zlt-dropbear.service` and `zlt-ssh-watchdog.timer`
5. sets `SYS_SSH_SWITCH=0`
6. restores `/etc/passwd` (root home back to `/home/root`, `zlt` user removed)
7. restores `/etc/shadow` (original root password hash)

### Partial restore

```sh
sh /data/zlt-backups/2026-10-26/restore.sh starttzapp   # boot hook only
sh /data/zlt-backups/2026-10-26/restore.sh passwd       # users/homes only
sh /data/zlt-backups/2026-10-26/restore.sh shadow       # passwords only
sh /data/zlt-backups/2026-10-26/restore.sh firewall     # firewall tuning only
sh /data/zlt-backups/2026-10-26/restore.sh ssh          # SSH service only
sh /data/zlt-backups/2026-10-26/restore.sh apns         # remove APN bind-mount (never applied)
```

### Reverting the APN typo patch (if it is ever applied)

`/system` is read-only, so the patch is a bind-mount. Undo it with:

```sh
umount /system/cusetc/apns-conf_8.xml
```

and remove the corresponding `mount --bind` line from `/etc/rc.local`.

---

## Caveats

- **`restore.sh` does not reboot.** The vendor firewall and TZApp rules only go
  back to their original shape on the next boot (TZApp rebuilds them).
- **`iptables` state is not restored**, only removed — because TZApp rebuilds it
  from scratch every boot anyway.
- `restore.sh firewall` only *deletes* our rule and flips the switch. It does not
  re-add the flush behaviour.
- `etc/passwd.orig` was **reconstructed** (last-write times on the device made a
  byte-exact original unavailable). It differs from the on-device file in exactly
  two places, both of which we made:
  - `root` home `→ /home/root`
  - the `zlt:` line removed
  Everything else is the live file verbatim.
- If the other track in this repo (QManager deployment) adds its own
  `/etc/initscripts` hooks, **re-take this backup** — this snapshot predates
  those changes.

---

## Re-taking a backup (do this before any new change)

```sh
B=/data/zlt-backups/$(date +%Y-%m-%d-%H%M)
mkdir -p "$B/etc/initscripts" "$B/etc" "$B/mdlcfg"
cp -p /etc/initscripts/*        "$B/etc/initscripts/"
cp -p /etc/passwd /etc/shadow /etc/group /etc/rc.local "$B/etc/"
cp -p /system/cusetc/apns-conf_8.xml /etc/data/mobileap_cfg.xml "$B/"
mdlcfg -e > "$B/mdlcfg/mdlcfg-full.txt"
du -sh "$B"
```

Then mirror it into the repo the same way it was done here (base64 over SSH), so
the backup survives even if the router is reflashed:

```bash
ssh zlt-x16 "cd $B && tar czf - ." > device-etc/backup-$(date +%Y-%m-%d).tar.gz
```
