# flap-meter — which comes first, the radio change or the WAN drop?

A **read-only** sampler that types every radio transition with a timestamp, and a
host-side analyzer that joins it with the vendor dialer's log. It exists to settle
one question with evidence instead of argument:

> The customer sees the cell/band change constantly *and* the internet drop.
> Which one causes the other?

`docs/29` answered it once, for 2026-10-26: 12 serving-cell changes over 13 h,
**zero** drops, and both deliberate teardowns moved the cell within ~16 s —
i.e. **drops lead the churn**. That is one window on one day. This measures it
again, on whatever day you run it, and per *type* of transition, because the four
types have different causes and only one of them touches registration:

| Transition | `AT+CPSI?`/`AT+CCAINFO?` | this meter | what it means |
|---|---|---|---|
| serving cell / band (`pcc=`) | ✅ 5 s granularity | ✅ **1 s** | RRC reselection — mobility, or a symptom of teardown |
| CA set / **SCC activation state** | ❌ state invisible | ✅ | capacity flicker on the SCells |
| EN-DC available (`endc=`) | ❌ | ✅ | **the one that touches registration** |
| NR anchor | ❌ (poller only) | ✅ | NSA leg coming and going |

## Why not just use `modem-profile/profile.sh`

`profile.sh` already counts serving-cell/PCC/CA-set changes — over a 5-minute
window, sampling with two AT commands every 5 s, i.e. holding the shared AT lock
for up to ~60 % of that window (`docs/34`). It cannot go finer without starving
the QManager poller, and it cannot see SCC state or EN-DC at all.

This uses `scripts/qmi-probe` instead: **one process, one NAS socket, two GETs per
tick**, measured 12.5 ms per sample end-to-end on a box at load ~3.5 (20-call
benchmark, `docs/36`), so 1 Hz is ~1 % of one core and it never touches the AT
channel or its lock.
Read-only start to finish; nothing here writes a modem setting.

## Use

```sh
./start.sh                       # push + start, 1 Hz, heartbeat every 60 s
./start.sh                       # idempotent: restarts against the same log
FLAP_INTERVAL=2 ./start.sh       # gentler
ZLT_HOST=root@10.0.0.1 ./start.sh

./stop.sh                        # stop, print the sampler's own SUMMARY
./pull.sh                        # -> capture/{transitions,dialer}-<host>-<stamp>
./analyze.sh capture/transitions-<host>-<stamp>.log
```

Log: `/data/zlt-flapmeter/transitions.log` — on `/data`, because `/data/log` is
wiped at boot and this unit reboots unasked; rotated to `.1` past 4 MB. Sampler
pid in `/data/zlt-flapmeter/sampler.pid` (stopping by `pkill -f` is unsafe: the
ssh command line carries the pattern too, and `pkill` then kills its own
session — rc 255 with no output).

Two push traps, both hit on 2026-10-29: `cat > <path>` to the **running** binary
fails `ETXTBSY` and, with stderr dropped, fails *silently* — the file keeps its old
size and mtime and the new subcommand answers `unknown command`. `start.sh` pushes
to `qmi-probe.new` and `mv`s it into place (atomic, works on a busy executable).

A day at 1 Hz is a few hundred KB, not 10 MB: the sampler prints a line only when
something **changes**, plus one heartbeat a minute so a dead monitor is visible.

## What the analyzer reports

```
== window          how long, how many samples, heartbeats, errors
                   mean time between changes, largest sampler gap
== changes by type serving cell / CA set / EN-DC / NR anchor
== WAN drops       disconnects, re-dials, mean drop -> re-dial
                   per drop: recovery time, change in the 60 s BEFORE, in the 60 s AFTER
== verdict         which direction the counts support, or "no clear direction"
```

Three rules it obeys, each learned from getting it wrong first:

1. **Absent data is not negative evidence.** A drop that happened outside the
   sampled window is printed as `no data (outside window)` and excluded from the
   counts. The first capture had 32 historical drops and a 60-second transition
   window; every row printed "no/no" and the verdict looked like a finding. It
   also refuses to conclude when no drop landed inside the window.
2. **A sampler gap is reported, not averaged away.** 39 minutes of missing
   samples is a monitor problem, not a quiet link.
3. **The direction verdict needs ≥3 drops** on one side; below that it says so
   rather than naming a cause from one event.

Fixtures for all of that are in `tests/unit_flap_meter.sh` (host-only, no device).

## Reading the output

- Mostly `pcc=` changes, no drops → mobility. Nothing to fix (`docs/29` §2).
- `scc=` flapping with a weak carrier held active → RF/policy, not an outage.
  Observed 2026-10-29: B1 held as SCC at −90 dBm while B5 (−71 dBm) cycled, and
  B5's PCI itself flickered `469 → 477 → 469` inside one second.
- `endc=` cycling → the NR leg is destabilising registration; that is what
  pinning LTE-only would test (a product decision, not an engineering one).
- Drops with **no** nearby change → the network side (EMM detach, `docs/29` §4);
  the fix is the recovery path, not the radio.

## Related

- `scripts/qmi-probe/` — the transport this rides on (`watch` subcommand), plus
  the QRTR ABI trap and the QMI/TLV reference.
- `docs/29-wan-drops-and-band-switching.md` — the first measurement of this
  question, and the 23–60 s vendor-dialer recovery delay.
- `docs/36-qmi-direct-probe.md` — band capability vs policy vs EFS, and why cell
  lock has no QMI path on this firmware.
