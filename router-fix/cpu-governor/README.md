# cpu-governor — pin the CPU frequency governor to `performance`

The vendor ships `ondemand`. On a 1-core SoC that also runs IPACM, the dialer and
the WebRTC bridge, `ondemand` adds ramp-up latency on every burst; a router does
not need a phone's power policy.

**Measured on the X16 (2026-10-29):** the win is small, because this box is busy
enough that `ondemand` already sits at max frequency — a fixed 4000-iteration
loop took **28.67 s** under `ondemand` vs **27.54 s** under `performance` (~4 %),
both at 1.8 GHz. What it buys is consistency during bursts, not throughput.

`/sys` does not survive a reboot, so `zlt-cpufreq` is hooked at the top of
`/etc/initscripts/StartTZApp` (below the shebang — see the trap below).

```sh
./install.sh              # deploy, hook, apply now, verify
./install.sh --check      # verify only
./install.sh --uninstall  # restore the vendor governor (ondemand) and unhook
```

Evidence: `/data/log/zlt-cpufreq.log` (one line per change, and an explicit
FAILED line if a write did not take — a silently unapplied governor is worse than
none, because the next reader assumes it worked).

Rollback: `--uninstall` restores `ondemand` immediately and removes the hook; the
original `StartTZApp` is backed up to
`/data/zlt-backups/<date>/cpu-governor/`.

## Trap found while installing this

Hooking "at the top" means **below the shebang**. The first install put the two
hook lines above `#!/bin/sh`; `sh -n` still passed, but anything that `execve`s
the file would no longer see an interpreter line. `install.sh` now inserts after
line 1 and runs `sh -n` on the result.
