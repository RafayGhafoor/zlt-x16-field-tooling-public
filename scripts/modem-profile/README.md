# modem-profile — read-only cellular/CA/band profiler

`profile.sh` captures what a ZLT X16-class ODU's modem **can** do versus what it
is **allowed** and **actually** doing, and measures how stable the primary
component carrier (PCC) and the carrier-aggregation set are over time.

It is written to be run unchanged against a **new router**: it discovers paths
and command support at runtime instead of assuming a firmware revision.

```sh
./profile.sh                                  # 5-minute window against $ZLT_HOST
./profile.sh --host root@10.0.0.1            # another unit
./profile.sh --minutes 15 --gap 5            # longer churn window
./profile.sh --out /tmp/capture              # capture directory
```

Default host is `zlt-root` (ssh alias), retries `ZLT_TRIES` times (default 6)
with `ZLT_SLEEP` seconds between attempts (default 4).

## What it produces

| File | Contents |
|---|---|
| `01-identity.txt` | module revision, baseband, IMEI/IMSI presence, product-config keys, host load |
| `02-radio.txt` | band policy, mode preference, NR disable, band **capability**, serving cell, per-chain RSRP/SINR, registration, bearer state, CA composition |
| `03-churn-raw.txt` | the raw sampler rows (timestamp, uptime, CPSI, CCAINFO) |
| `04-inventory.txt` | MCFG package count, region dirs, `common/` packages with hashes and whether they carry band/CA/RRC items, EFS partitions |
| `05-churn-analysis.txt` | serving-cell changes, PCC changes, CA-set changes, mean interval, max CC count |
| `06-run-integrity.txt` | uptime before/after — **if this says REBOOTED, discard the window** |

It is **read-only**: no writes, no resets, no unlocks, no MBN/PDC changes.

## Why the script looks paranoid

Each rule below was learned by breaking a live unit.

**The AT channel is shared and has no timeout.** `atcmd` will wait forever for a
command the modem does not answer, and that blocks the QManager poller and the
calls bridge with it until `atcmd_daemon` respawns. Commands **confirmed to
hang**, and therefore never sent:

```
AT+CLAC        (docs/26 recorded this; it still hangs)
AT+CNBP?       (hang)
AT+CSYSSEL=?   (hang — this is the capability probe!)
```

`at_cmd()` in the script applies both an allowlist and `timeout 12`. Widening
the allowlist is a deliberate act, not a convenience.

**Band capability cannot be read over AT.** The only query (`AT+CSYSSEL=?`)
hangs, so capability is taken from the QManager status JSON
(`supported_lte_bands`), which the poller fills from a successful read. The
script never invents a capability list.

**Band-policy reads can be truncated.** `AT+QNWPREFCFG="lte_band"` is a shim
rename of `AT+CSYSSEL="lte_band"`. Under contention a read can come back short
(`1:3` instead of `1:3:5:28:38:41`). A short value is a **measurement artefact,
not a policy change** — docs/29 was misled by exactly this and recorded a
"mystery writer" that did not exist. Re-read before concluding anything.

**The CA source is `AT+CCAINFO?`, not `AT+QCAINFO`.** `QCAINFO` is Quectel and
ERRORs natively on this SIMCom part.

**CPSI field order.** Fields 11–14 are RSRQ, RSRP, RSSI, SIL/SNR, scaled ×10 —
`-731` is **−73.1 dBm RSRP**, not −731. Reading field 11 as RSRP makes a healthy
link look like a dead one.

**`/data/log` is wiped at boot**, and these units reboot on their own. Captures
therefore live on the host, and the run records uptime at both ends: if uptime
goes backwards, the window is void.

**A failed read is not an event.** A blank CPSI sample is excluded from the
change count rather than counted as a cell change — the error docs/29 warns
about.

## Interpreting the output

- `carriers: max 3CC` means the modem did aggregate; a `0CC`/`1CC` with a full
  band policy points at the network or the SIM, not at the router.
- `PCC changes` and `CA-set changes` are the "it keeps switching" number. Divide
  by the window to get a rate; a healthy idle link should be near zero.
- Compare `policy` against `capability`: every band in the capability list that
  is missing from the policy is a band the modem can never use. On Ufone (410-03)
  that matters — B8/900 MHz is deployed and Ufone's own CA settles on B3+B8.
- `06-run-integrity.txt` gates everything else. Check it first.
