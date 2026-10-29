# gnss-off — keep `simcom-gnss.service` off

The vendor's GNSS daemon is stopped, masked, and re-stopped at every boot.

## Why

`docs/47` §2 measured the whole chain: the SDK client initialises
(`gnss init success`), registers its indication handler, and the modem **accepts a
session** (`gnss start success!!`) — and then emits nothing, in a 60 s and a 180 s
window. Two reasons, both outside the software:

- `/data/localxtra.bin` did not exist, so the engine had **never been started before**
  — that is a cold start with no assistance data;
- a GNSS receiver needs sky. This is a mast-mounted ODU, and the unit was being driven
  from a lab.

Meanwhile the daemon costs **16 threads and ~3 MB RSS** on a one-core box, and nothing
depends on it (no unit `Requires=`/`Wants=` it; the two location sockets are only used
by its own peer `atfwd_daemon`, which has its own unit and is left untouched).

## What it does

| Step | Why that way |
|---|---|
| `systemctl stop` | also stops resurrections: `Restart=always` does not undo an explicit stop |
| `systemctl mask` | stops `systemctl start` from working. Applied, but **not relied on**: it is a unit file under `/etc/systemd/system`, and this firmware mounts `/etc` at ~10.6 s, i.e. *after* systemd loads units (AGENTS §4) |
| one line in `/etc/initscripts/StartTZApp` | **the guarantee**. Runs from the mounted `/etc` at every boot, after the shebang (that rule cost a deploy once — `docs/43` §2.0), and logs one line to `/data/log/zlt-gnss-off.log` when it actually had to stop something |

`is-enabled` is useless here either way: the enable symlink lives on the read-only
rootfs (`/lib/systemd/system/multi-user.target.wants/`), so it can neither be removed
nor trusted (AGENTS §5.6).

## Verify

```sh
./install.sh --check
#  simcom-gnss : inactive / masked
#  gnss daemon : gone
#  hook        : 1 line1=#!/bin/sh
#  atfwd       : active (its own unit, untouched)
```

After a reboot, `/data/log/zlt-gnss-off.log` should hold one line per boot
(`simcom-gnss.service stopped at boot`). If the unit is up and the log is empty, the
hook is not running — check `head -1 /etc/initscripts/StartTZApp` is `#!/bin/sh`.

## Rollback

```sh
./install.sh --uninstall      # removes the hook, unmasks, starts it again
```

or on the device: `/data/zlt-gnss-off/gnss-off.sh revert`.

## Measured on this unit, 2026-10-29

```
before: simcom-gnss.service active(running) 5 h 04 m, 16 threads, 2964 kB RSS,
        0.009 % CPU, never a fix
after : inactive / masked, daemon gone, hook=1, StartTZApp line1=#!/bin/sh,
        atfwd.service still active (pid 924), WAN rmnet_data0 up, ping OK,
        QManager poller + httpd active
```
