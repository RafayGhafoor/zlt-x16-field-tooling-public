# wan-recovery — record how long each WAN outage actually lasts

**This module measures; it does not fix.** It never dials, never touches the
dialer, never sends AT or QMI. It reads the vendor dialer's own log and writes one
line per outage to `/data/zlt-wan-recovery.log`.

## Why not just fix the 60 s

`docs/29` established the mechanism: the dialer notices a dropped bearer in ~0.1 s
(`data_call_evt_cb` → `Datacall Disconnected!`), then does nothing until one of two
watchdogs fires on a long counter, giving a 2–60 s scatter. Shortening it needs a
change, and the only documented lever is `USR_NW_AUTO_QUERY_INTERVAL` (currently
**10**, units unverified — a ~60 s cycle fits ~6 s/count, nothing else does).

Two things block a blind change:

1. **No external re-dial entry point exists.** Checked 2026-10-29: `ubus list` is
   empty; `/tmp/.flag_internet_has_been_disconned` is used only in the modem
   **assert/block** path (its string neighbours are "Modem assert detected" /
   "Modem block detected"), not by the PDP watchdog; no vendor CGI references it;
   the dialer listens on nothing user-serviceable. So a supervisor cannot ask the
   dialer to re-dial — it could only restart the dialer, which `AGENTS.md` §5.4
   explicitly warns against.
2. **Drops are episodic.** 0 in this session's 4 h, 32 in an 8 h window on
   26–27 Oct. A change cannot be validated in a quiet window.

So: measure first, with a record that survives the boot that wipes `/data/log`.

## What it writes

```
/data/zlt-wan-recovery.log    2026-10-29 10:00:07 OUTAGE recovered_at=... drop_at=2026-10-29 10:00:00 recovery_s=7 drops_today=1
                              2026-10-29 22:03:13 zlt-wan-recovery: watching /tmp/logs/DIALER.log (interval 5s)
/data/zlt-wan-recovery.state  off=<byte offset> drops_today=<n> day=<date>
/data/zlt-wan-recovery.pid    its own pid
```

Durations come from the **timestamps in the dialer's lines**, not from when the
5 s poll noticed them: a first version timed from wall clock and reported
`recovery_s=0` whenever a drop and its recovery landed in the same 5 s chunk.
Caught by running the parser against a fixture, which is why the output paths are
overridable (`DL`, `LOG`, `ST`, `PIDF`) — and why the fixture test no longer writes
into the real record.

## Use

```sh
./install.sh              # deploy, hook at top of StartTZApp, start now
./install.sh --check
./install.sh --uninstall  # stop and unhook; keeps the evidence in /data
```

Then, once it has captured a baseline, the interval experiment is one command each
way:

```sh
mdlcfg -a USR_NW_AUTO_QUERY_INTERVAL=2 && mdlcfg -c     # worst case ~12 s
mdlcfg -a USR_NW_AUTO_QUERY_INTERVAL=10 && mdlcfg -c    # rollback (current)
```

Compare `recovery_s` distributions before and after — that is the only honest way
to judge it, and this module is what makes the comparison possible.

## Trap found while installing this

`pkill -f zlt-wan-recovery` kills the session that issued it: the ssh command line
contains the script path, so the pattern matches its own shell. Twice now (sampler,
then here) — use a pidfile, and write the pid from the script itself.
