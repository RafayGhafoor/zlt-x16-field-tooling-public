# atcmd-guard — supervise the AT channel's indication thread

**Module 6 of the "self-contained device fix" shape.** Payload, installer, verify,
rollback. Installs a 1-minute systemd timer that repairs `atcmd_daemon` when its
indication stream dies or the daemon itself is gone.

## The failure it repairs

`atcmd_daemon` owns the only AT channel (`/dev/smd8`) and reads *indications* from
`/dev/smd9` in `read_tty_thread`. On a read error that thread does this
(decompiled, `docs/38` §1):

```c
close(fd);
do { usleep(100000); fd = open("/dev/smd3", O_RDWR); } while (fd < 0);
```

`/dev/smd3` **does not exist on this firmware** — the node list is
`smd7 smd8 smd9 smd10 smd11 smd21 smd22 smd38 smdcntl0 smdcntl1 smdcntl8`. So one
bad read parks that thread at 10 Hz for the rest of the boot, and it logs nothing
while looping.

What makes it dangerous is what still works:

| Still works | Silently dead |
|---|---|
| `AT` commands and replies (`smd8`) | call state indications (`RING`, `+CLCC` events) |
| every UI panel that polls AT | SMS delivery notices (`+CMTI`) |
| the QManager poller | USSD (`+CUSD` → the daemon's `/tmp/.ussd_*` handshake) |

Nothing supervises it: the daemon is started from
`/etc/initscripts/start_atcmd_daemon`, not from a unit, so there is no `Restart=`
and no supervisor to notice. The visible symptom is "calls and SMS stopped working
but the dashboard is fine", with no log line anywhere.

## What it installs

| Path | Role |
|---|---|
| `/data/zlt-atcmd-guard/guard.sh` | the guard (payload — replaceable without touching `/etc`) |
| `/etc/systemd/system/zlt-atcmd-guard.service` | `Type=oneshot`, `KillMode=process` |
| `/etc/systemd/system/zlt-atcmd-guard.timer` | 1-minute cadence |
| top of `/etc/initscripts/StartTZApp` | one line that starts the timer (units under `/etc/systemd/system` get no boot job — the `/etc` volume mounts at ~10.6 s, after systemd has loaded units) |

Backups of anything replaced: `/data/zlt-backups/<YYYYMMDD>/atcmd-guard/`.

## What it checks, and what it deliberately does not

Two structural signals, no AT traffic in the steady state (an `AT` probe every
minute would be the cost `docs/34` argues against):

1. **the process exists** — else restart;
2. **it still holds `/dev/smd9` open**, once it has been seen holding it. The first
   healthy run writes `smd9.expected` in the state dir, so a unit with VoLTE off —
   where no such reader ever exists — is never mistaken for a broken one. When
   there is no marker and the fd is missing, the daemon's own log decides: the
   vendor writes `try to reopen pty devices` *before* entering the silent loop, and
   that line is enough to restart. Without it, VoLTE-off is assumed and the guard
   stays silent.

Recovery is the documented recipe (`docs/05`, `docs/33`) — the daemon owns no PDP
context, so the dialer and the WAN are untouched:

```sh
kill -9 $(pgrep -f '^atcmd_daemon$'); setsid /etc/initscripts/start_atcmd_daemon start
```

**Rate limited**: one restart per 15 min, at most 3 per hour, then it logs
`SUPPRESSED` instead. A guard that restarts in a loop is worse than the bug it
chases, especially on a 1-core box.

Not done on purpose: restarting on an AT *timeout*. A single slow command is not
evidence of a wedge, the shim already blacklists a timed-out command for the boot
(`docs/38` §3), and a false restart costs a second of AT for every client.

## The log survives reboots

`/data/log` is on the persistent ubifs volume, so `/data/log/zlt-atcmd-guard.log` keeps
its history across a reboot — measured 2026-10-30 (a guard line written on 2026-10-29 was
still there afterwards). Read it accordingly: a boot that shows **no new lines** is a
boot where the guard found nothing to do, and a line dated in a previous boot is a real
restart, not noise. (What does *not* survive is `/tmp/logs`, the vendor's own tmpfs
logs.) AGENTS §6's older "`/data/log` is wiped at boot" note was corrected from the same
measurement.

## Cost when healthy

One `pgrep`, one read of `/proc/<pid>/fd`, one `/proc/uptime` read. No forks, no
writes, **no log line** — like the SmartDNS and QManager guards, silence is the
healthy state.

## Verify

```sh
cd router-fix/atcmd-guard
./install.sh --check        # files, timer, hook, guard dry run, live fd table
./install.sh                # deploy + start + verify

# it is healthy if the log does not grow:
ssh zlt-root 'ls -l /data/log/zlt-atcmd-guard.log; wc -l /data/log/zlt-atcmd-guard.log'

# prove it acts (the only safe way to test a supervisor): kill the daemon
ssh zlt-root 'kill -9 $(pgrep -f "^atcmd_daemon$")'
sleep 70
ssh zlt-root 'tail -3 /data/log/zlt-atcmd-guard.log; /bin/atcmd AT'
#   -> RESTART (reason=daemon-absent, pid=...): kill -9 + start_atcmd_daemon
#   -> OK pid=... holds /dev/smd9 again (after Ns)
#   -> OK
```

Measured on this unit, 2026-10-29: see the commit body — the guard restored the
daemon with `/dev/smd9` re-opened, and `/proc/net/route` + an internet ping were
unchanged across the restart (the daemon holds no bearer).

## Rollback

```sh
./install.sh --uninstall
```

Stops and disables the timer, removes both units, the payload directory and the
hook line, and `daemon-reload`s. `/data/log/zlt-atcmd-guard.log` is left in place —
it is the record of what was restarted.

## Why a guard at all

The same reason the SmartDNS and QManager modules ship one: **a process that is up
is not a process that stays up**, and nothing on this firmware supervises either
`dnsmasq`, the QManager units, or this daemon. Each of those guards was justified
by a measurement rather than a hunch — here it is `docs/38` §1: a `/dev/smd3` that
cannot be opened, in a loop that does not log.
