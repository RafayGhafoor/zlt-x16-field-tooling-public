# 29 — WAN drops and the "band switch costs a minute" report

Measured 2026-10-26. Supersedes the MTU-first reading in
[12](12-speedtest-disconnect-diagnosis.md); the fault is unchanged, what changed
is that the **recovery delay is now explained and quantified** instead of
inferred.

The customer reports: *"the internet disappears for about a minute, and I see
continuous cell handoffs."* Those are two different things, and only one of them
is the outage.

---

## 1. The one-minute outage is a polling delay in the vendor dialer

The bearer is deactivated by the network. The dialer **learns about it almost
instantly and then does nothing for up to a minute.**

| Stage | Observed | Evidence |
|---|---|---|
| `PDP` deactivated by network | t+0 | `data_call_evt_cb state[0] err[1]` |
| dialer callback runs | **t+0.1 s** | `Datacall Disconnected!` (20:54:33.145) |
| nothing happens | … | `data_call_evt_cb` **only logs**; it requests no teardown or re-dial |
| `sunsea_check_if_pdp_deactive_handler` | t+23…60 s | fires only on its ~50–60 s tick |
| *or* `sunsea_check_if_wanip_changed_handler` | t+23…53 s | second independent tick, whichever lands first |
| re-dial → new IP → NAT/DNS | +1–3 s | `create_data_connection`, then `config_lan_wan: dial successful` |

Recovery times measured across the day's six real events:
**2.3 s, 7 s, 23 s, 26 s, 41 s, 44 s, 49 s, 53 s, 59 s, 60 s.**

That scatter is not variance in the fix — it is *where in the 60 s cycle the
teardown happened to land*. Land just before a tick and it looks instant; land
just after one and it costs a full minute. That is exactly the "sometimes a
minute" the customer describes.

There are **two** such watchdogs (`…_pdp_deactive` and `…_wanip_changed`), both
driven from the one-second handler in `/bin/dialer` and both gated on a long
counter (`auto_query_interval`). Either can perform the recovery; the fast case
is whichever tick arrives first. This is the mechanism `DIAGNOSIS.md` predicted
from reverse engineering — it is now measured end to end.

### What does NOT help (each measured, each reverted)

| Attempt | Result |
|---|---|
| `AT+CGEREP=1` — enable `+CGEV` unsolicited PDN events | **No effect.** Events already arrived in 0.1 s; the dialer had `sunsea_cgev_handler` all along. Reverted to the vendor `0,0`. |
| `AT+CGACT=1,6` — re-activate the context externally | **Hangs** (`Terminated` at the 20 s timeout). The dialer owns the context; an outside AT client cannot force it back. |
| `/etc/initscripts/start_dialer restart` | **No-op** — the `restart)` case in the vendor script is empty. Only `killall -9 dialer` + `dialer &` work. |

So there is **no cheap, reversible external lever to shorten the delay.**
The remaining option is killing the dialer process, which AGENTS.md §5 rule 4
argues against (the data call is fragile, and that process also carries
IMS/SMS/VoLTE). Not adopted.

---

## 2. Band switching is a *symptom*, not the cause

Churn is real — 397 poller samples over 07:45→20:44 show **12 serving-cell
changes**, with 7 of them inside 77 minutes (07:56–09:13):

```
07:56  B3/1312/PCI256  -> ...            (CA changes: B3+B1+B5, B3+B1+B8)
08:59  B3/1312/PCI256  -> B1/250/PCI104
09:08  B1/250/PCI104   -> B3/1850/PCI227
09:10  B3/1850/PCI227  -> B3/1850/PCI480
09:13  B3/1850/PCI480  -> B1/250/PCI104
15:47  B1/250/PCI104   -> B1/250/PCI104 + N41   (5G NSA, 131 min)
17:58  back to B3/1850/PCI227 (LTE), N41 gone
```

**But that churn caused zero data-call drops.** 07:56–09:13 and the whole
NSA episode produced no `Datacall Disconnected` in the dialer log at all.

Conversely, both times a bearer was deliberately torn down while a monitor was
running, the serving cell moved **within ~16 s**:

```
20:54:38  bearer down (B3/1850/PCI227)
20:54:54  -> B1/250/PCI162
21:03:33  bearer down (B1/250/PCI162)
21:03:49  -> B3/1850/PCI227
```

So the causal arrow runs the other way: **bearer teardown → modem re-selects a
cell during recovery → handoff.** The customer sees the handoff and the outage
together and (reasonably) attributes the outage to the handoff.

Consequence: **pinning a band or a PCI would hide the visible churn and leave
the 60 s recovery completely untouched.** Radio surgery is not the fix here.

### A red herring worth recording

A single poller sample at 18:06:33 shows a blank serving cell for 81 s. It is
**not** an outage: that same row has `registered=true` with `dl_bps=285594` and
`ul_bps=952921`, i.e. traffic was flowing. It is a CPSI read failing inside the
poller. The hand-written monitor reproduced it (20:47:40, blank cell with
`route=1 reachable=1`). **Do not count blank samples as downtime** — require
`route=0` or `reachable=0`.

---

## 3. What was changed as a result

**`router-fix/ttl-normalise/`** — WAN egress TTL is now normalised to 65, the
same value the working GreenPacket O5A ships (`docs/13`). The X16 left tethered
traffic at TTL 63, a hotspot signature; if the carrier is enforcing
anti-tethering, that is a mechanism by which it would deactivate bearers and
therefore affects the **frequency** of the events in §1, which is the only lever
that touches the root cause. Verified live and across a reboot
(`router-fix/ttl-normalise/README.md`).

This is a hypothesis under measurement, not a proven cure.

---

## 4. Tower locking — current state

The UI toast *"Couldn't apply the LTE tower lock"* is explained by the **cell
count the UI let the operator enter**, not by a broken write path:

| Candidate | Verdict |
|---|---|
| Stale `atcli_smd11` | **Ruled out** — deployed sha256 `9de2aaf5…` is byte-identical to the repo |
| Read path / translation | **Works** — `AT+QNWLOCK="common/4g"` → `+QNWLOCK: "common/4g",0`, rc=0 |
| QManager arg order | **Correct** — `250,104` → `AT+CCELLCFG=1,104,250` (PCI then EARFCN) |
| Modem rejects the native write | **Unlikely** — a one-cell lock evidently succeeded, because the config is only written on success and it holds one cell |
| **Multi-cell request** | **Leading candidate** — the UI offers 3 slots and this shim refuses >1 cell by design; 2- and 3-cell forms return `ERROR` without contacting the modem. A saved config with a single cell records a *successful* attempt, so it does not rule this out — it is the other kind of attempt. |

The earlier "multi-cell ruled out — saved config has exactly one cell" was a
misreading: that config is the residue of a one-cell lock that worked, not the
record of the attempt that failed.

A real defect was found on the way: `/etc/qmanager/tower_lock.json` claimed

```json
"lte": { "enabled": true, "cells": [ { "earfcn": 250, "pci": 104 }, null, null ] }
```

while the modem reported `+CCELLCFG: 0,0` — **unlocked** — and was camped on
B3/1850/PCI227. The UI therefore displayed a lock that did not exist.

**Cleared 2026-10-26 21:58.** The saved entry was set to `enabled: false` with
all three cells `null` — no modem write, because the LTE cell it named is not the
one the radio is on and no tower timer was armed, so nothing re-applied it.
Backup: `/data/zlt-backups/20261026/tower-lock/tower_lock.json.orig`.

Afterwards the API the page reads reports both sides consistently:

```
modem_state: lte_locked=false, lte_cells=[], lte_read_ok=true
config:      lte.enabled=false, cells=[null,null,null]
```

### Correction — the config is *not* written before the modem command

An earlier revision of this page (and commit `c2240dc`) claimed `lock.sh` calls
`tower_write_begin` before `tower_lock_lte`, so a rejected lock would still
persist `enabled: true`. **That was wrong**, and it is worth recording why:

```
lock.sh:123  tower_write_begin                # self-expiring in-flight marker only, no config write
lock.sh:126  result=$(tower_lock_lte ...)
lock.sh:131  cgi_error "modem_error" ... exit  # rc != 0 or empty
lock.sh:138  cgi_error "at_error"    ... exit  # response contains ERROR
lock.sh:150  tower_config_update_lte "true" ...  # ONLY reached on success
```

The claim was inferred from a subagent's summary without diffing the deployed
file. The deployed `/data/qmanager/www/cgi-bin/quecmanager/tower/lock.sh` differs
from the `/tmp/qm` source **only** by the documented
`/usr/lib/qmanager` → `/data/qmanager/lib` path rewrite (`qm_pathfix_x16.sh`),
and both write the config strictly after a successful modem command.

What that means instead: a persisted `enabled: true` with one cell is evidence
that a **single-cell lock succeeded at some point**, and the lock was later lost
— `persist` is `false`, so nothing re-applies it after a reboot or modem reset,
and nothing reconciles the config back to `enabled: false` either. The stale
state is a *persistence/reconciliation* bug, not an ordering bug.

This also revises §4's ranking: the native `AT+CCELLCFG=1,<pci>,<earfcn>` write is
**not** the likely culprit (a one-cell lock evidently went through). The live
multi-cell path is the better explanation for the toast, and it is observable
without touching the modem:

```
$ atcli_smd11 'AT+QNWLOCK="common/4g",2,250,104,1850,227'   -> ERROR   (modem never contacted)
$ atcli_smd11 'AT+QNWLOCK="common/4g",3,...'               -> ERROR   (modem never contacted)
$ atcli_smd11 'AT+QNWLOCK="common/5g",104,250,15,1'        -> ERROR   (NR-SA refused by design)
$ atcmd 'AT+CCELLCFG?'                                      -> +CCELLCFG: 0,0  (unchanged)
```

`lte-tower-card.tsx:119` hardcodes `SLOT_COUNT = 3` and consults no capability,
so the UI happily lets an operator fill 2–3 slots that this shim refuses by
design (`tests/unit_tower_schedule.sh` pins that refusal). Filling more than one
slot therefore produces exactly "Couldn't apply the LTE tower lock" with no
usable explanation. **Confirmed with the operator on 2026-10-26: the failed
attempt had more than one slot filled.**

### Both defects fixed 2026-10-26

**1. The refusal now explains itself.** The shim keeps `ERROR` on line 1 — the
machine contract other consumers match — and puts the reason on line 2, which
`lock.sh` maps to a specific error instead of the generic one:

```
$ atcli_smd11 'AT+QNWLOCK="common/4g",2,250,104,1850,227'
ERROR
multi-cell lock unsupported: this device supports one LTE cell

-> cgi_error "unsupported_cells" "This device supports one LTE cell — clear the extra slots"
```

**2. A stale saved lock is reconciled.** `tower_reconcile_lte_config()` in
`tower_lock_mgr.sh`, called from `status.sh`, clears a saved `enabled: true` when
— and only when — every one of these is *observed*: the modem read succeeded
(an unreadable modem is not "unlocked"), the modem reports unlocked,
`persist` is not `true`, and no tower write is in flight (the self-expiring
`TOWER_WRITE_INFLIGHT` marker). Verified on the device by seeding the exact
post-reboot state:

```
seed:   config {lte_enabled:true, cells:[{earfcn:250,pci:104},…]}   modem +CCELLCFG: 0,0
result: config {lte_enabled:false, cells:[null,null,null]}          log "Cleared stale LTE tower lock…"
```

Note `cgi_tower_status` logs `ERROR ... (lte_rc=0 nr_rc=1 persist_rc=1)` on every
poll. That is expected here, not a fault: this modem exposes no `AT+C5GCELLCFG`
lock state and no `save_ctrl`, so the handler reports `nr_read_ok=false` and
`persist_read_ok=false` rather than inventing a value (see
[23](23-cell-locking-on-sim8260e.md)). The log level is noisy; the behaviour is
correct.

---

---

## 4b. The `rmnet_data0 DOWN` lines ARE the drops (and polling is not the cause)

The kernel log's `rmnet_data0 UNKNOWN` / `rmnet_data0 DOWN` pairs are the same
event as the dialer's disconnect, not a separate NIC fault. Converted to wall
clock (boot = 22:52:42, from `/proc/uptime`), 14 of them line up with
`Datacall Disconnected` **within one second**:

| rmnet `DOWN` | dialer disconnect |
|---|---|
| 23:34:37, 23:59:57, 00:01:12, 00:02:26, 00:03:46, 00:04:42, 00:06:34, 00:08:10, 00:08:42, 00:09:06, 00:11:32, 00:40:10, 00:41:56 | same, ±1 s |

Five more `DOWN` events (23:07:30, 23:08:00, 23:31:27, 23:32:52, 23:33:47) had
**no** dialer event — brief interface bounces that did not cost the bearer.

Rate on 2026-10-27 was far worse than the 2026-10-26 baseline: **20 disconnects
in ~2 h**, clustered — 9 of them between 23:59:57 and 00:11:32.

### Suspect disproved: the poller's CA toggle

Every cycle sends `AT+QENG="servingcell";+QCAINFO=1;+QCAINFO;+QCAINFO=0`, which
looked like it was switching carrier aggregation twice per cycle. It is not: the
shim answers `AT+QCAINFO=0|1` with a bare `OK` and never forwards them
(*"reports are always on-demand here"*, `atcli_smd11:46`). Verified on device.

### Controlled test: stop the poller

The poller and its guard timer were stopped for 12 minutes (self-restoring
script, so a lost SSH could not leave the box without a poller):

```
00:55:08  baseline: disconnects=20  rmnetDOWN=19
01:07:15  after 12min stopped: disconnects=20 (+0)  rmnetDOWN=19 (+0)
          restored: poller=active guard=active
```

**Zero drops in the window — but the 13 minutes immediately before it, with the
poller running, were also zero.** The burst had already ended at 00:41:57.
So the test cannot attribute the drops to the poller, and it does establish the
useful negative: **the poller's normal AT cadence (2–3 calls per ~13 s cycle)
does not by itself drop the bearer.**

What the burst *does* correlate with is this session's own benchmarking — 10–30
back-to-back `qcmd` calls per second-scale burst, which is one to two orders of
magnitude more AT traffic than the poller ever generates. That is an artifact of
testing, not of normal operation, and it is worth remembering before hammering
AT on this box again.

### Still missing: the modem's own reason

[§5](#5-measurement-plan) item 5 (`AT+CEER` at teardown) had never been run. A
watcher is now armed that fires `AT+CEER`, `AT+CGACT?`, `AT+CEREG?`, `AT+CPSI?`
and `AT+CCELLCFG?` the moment the default route disappears, logging to
`/data/log/wan-teardown.log`. It ran through the whole 12-minute test window and
through the quiet period before it, so **it has no captures yet** — no teardown
occurred while it was armed. Until one lands, the teardown reason remains the
`err=1` collapse from `DIAGNOSIS.md`.

### Also unexplained

The unit **rebooted at 22:52:42** and nobody asked it to (the previous deliberate
reboot was 21:25). An unexpected reset is itself a plausible cause of a burst of
drops around that time, and it is not explained.

---

## 4c. Breakthrough: the teardown is a REGISTRATION loss, not a bearer handback

[§5](#5-measurement-plan) item 5 (`AT+CEER` at teardown) is now **captured** —
`docs/captures/2026-10-27-teardown-ceer/`. Two teardowns 70 s apart:

```
=== TEARDOWN 01:09:18 ===
CEER:     +CEER: No cause information available
CGACT:    1,0  2,0  3,0  6,0          <- EVERY PDP context inactive, incl. IMS
CEREG:    0,2                         <- registered=false, SEARCHING
CPSI:     NO SERVICE,Online

=== TEARDOWN 01:10:28 ===
CEER:     +CEER: EMM attach failed    <- a real cause, for the first time
CGACT:    1,0  2,1  3,0  6,1          <- cid 2 (IMS) and 6 (internet) back up
CEREG:    0,1                         <- registered, home
CPSI:     LTE,Online,410-01,...BAND3,1850,...227,...-689,...  (RSRP -68.9, SINR 13)
```

**Read the labels carefully.** In teardown 01 the `AT+CEREG?` read FAILED, so every
subsequent response is shifted up one label in the log: the line labelled `CPSI:`
holds the CEREG answer and the line labelled `CCELLCFG:` holds the CPSI answer.

What this says, together:

1. the modem **lost service entirely** (`NO SERVICE`, `CEREG 0,2` searching, all
   contexts deactivated), then
2. its attempt to get back on failed once — **`EMM attach failed`** — and
3. only the following attempt succeeded, minutes later.

So the 37–60 s outage is not a carrier gracefully handing back a bearer (the model
in `DIAGNOSIS.md` and §1). It is **registration instability**: lose service,
fail to re-attach, retry. That is a different fault with a different fix, and it
explains why the recovery always looked like "wait for the watchdogs".

### Five teardowns, and the causes are all EMM/RRC

With the watcher left running, five teardowns were captured
(`docs/captures/2026-10-27-teardown-ceer/`):

| Time | `AT+CEER` |
|---|---|
| 01:09:18 | `No cause information available` (contexts all down, `CPSI: NO SERVICE`) |
| 01:10:28 | **`EMM attach failed`** |
| 01:18:00 | **`EMM detached`** |
| 01:19:02 | **`Released AT RRC`** |
| 01:23:36 | **`EMM detached`** |

`EMM detached` is a **network-initiated detach at the mobility-management
layer**, not a bearer handback, and not anything the router asked for. `Released
AT RRC` is the radio connection being released. Together with the failed
re-attach, the sequence is: the network detaches us → RRC released → re-attach
attempt fails → the dialer's watchdogs eventually recover.

That makes three of five causes unambiguously network-side. It also means the
"carrier tears down the bearer while we are connected" story in `DIAGNOSIS.md` and
§1 was directionally right but at the wrong layer: this is NAS/EMM detach, not a
PDU deactivation.

What would cause an operator to detach a UE at EMM, repeatedly: subscription or
policy state on their side, anti-tethering enforcement, or a duplicate/blocked
IMEI. The TTL normalisation in `router-fix/ttl-normalise/` was aimed at the
anti-tethering hypothesis and is deployed but not yet measured against a
drop-rate baseline — that measurement is now the cheapest open question.

### What churned just before it

The poller logged EN-DC flapping earlier in the same session
(`docs/captures/2026-10-27-teardown-ceer/nr-endc-transitions.log`):

```
00:11:36  5G-NSA -> LTE      NR5G anchor lost (was N41)
00:12:02  LTE -> 5G-NSA      NR5G anchor acquired (N41, PCI 47)
00:13:34  5G-NSA -> LTE      NR5G anchor lost (was N41)
```

Current policy: `mode_pref AUTO`, `nr5g_disable_mode 0`, `lte_band 1:3:41`,
`nsa_nr5g_band 1:8:40:41:78`. So EN-DC is enabled and the NR leg is coming and
going on N41.

### The obvious next experiment (NOT yet run)

`AT+QNWPREFCFG="nr5g_disable_mode",1` pins the modem to LTE, removing EN-DC
attach/detach entirely. It is one reversible command (`...,0` restores) and it
directly tests whether the NR leg is what destabilises registration.

Cost: loses 5G-NSA throughput. That makes it a product decision, not an
engineering one — which is why it has not been applied unilaterally.

Unrelated observation from the same session, recorded and not explained: the band
policy read back as `lte_band 1:3:41`, having been `1:3:5:41` earlier in the day
(B5 dropped). Nobody in this session wrote it.

## 5. Measurement plan

Because §1 bounds the *duration* and §3 can only move the *frequency*, the
useful question is: **does the drop rate change with TTL normalisation in
place?**

Baseline before the change, from `/data/logs_backup/DIALER.log`:

| Day | Data-call drops |
|---|---|
| 2026-09-01 | 8 |
| 2026-10-26 | 6 (3 natural + 3 induced by this investigation) |

Next: recount drops per 24 h with TTL active. The dialer log is the record of
record (`Datacall Disconnected!`), and it rotates into
`/data/logs_backup/DIALER.log`, so a day-over-day count is cheap.

Evidence for this page: `docs/captures/2026-10-26-wan-drops/`
(`dialer-session.log`, `metrics-2026-10-26.csv`, `wanwatch-2046-2116.log`).
