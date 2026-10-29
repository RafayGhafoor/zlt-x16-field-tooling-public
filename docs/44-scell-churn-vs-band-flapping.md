# 37 — "It keeps switching bands": what the churn actually is

Measured 2026-10-29 on the X16, 1 h 45 m of 1 Hz sampling, after
`scripts/flap-meter` learned to separate the two kinds of CA event.

## 1. An SCell has three states, and they are signalled differently

This is the distinction that makes the customer report readable. From 3GPP TS
36.300 §7.5 and the MAC-CE literature:

| State | Changed by | Trigger | Is it a fault? |
|---|---|---|---|
| not configured → configured | **RRC** `sCellToAddModList` | A4 (neighbour better, load) or same-coverage add; A6 to re-point an SCell | often — this is the churn to chase |
| configured + deactivated → activated | **MAC CE** | data arrives; the eNB decides | no — normal, and it is how CA saves power |
| activated → deactivated | **MAC CE** | `sCellDeactivationTimer` expiry / no traffic | no — same |

A UE cannot refuse an SCell: the network configures and activates it. So
"flapping" at the *state* level is the network doing power management, while
flapping at the *membership* level is the network re-deciding which carriers you
get. Only the second one is worth chasing, and before this change our log counted
both as the same `scc` event.

Sources: [TS 36.300 §7.5](https://itecspec.com/3gpp/36.300/s/7.5),
[ShareTechnote MAC CE SCell activation](https://www.sharetechnote.com/html/5G/5G_MAC_CE_Activation_Deactivation.html),
[howltestuffworks: activation/deactivation of SCells](http://howltestuffworks.blogspot.com/2014/10/carrier-aggregation-activation-and.html),
[3G4G: how the A6 event triggers an SCell change](https://blog.3g4g.co.uk/2020/05/how-a6-measurement-event-triggers.html).

## 2. What this unit is actually doing

`scripts/flap-meter/analyze.sh` now classifies from the STATE lines (so it also
re-reads logs written before the split):

```
== window
  2026-10-29 18:56:48 -> 20:41:50  (1h45m02s)
  state samples: 143   changes: 139   errors: 0
  mean time between changes: 0h00m45s

== changes by type
  serving cell / band (RRC reselection): 0
  SCell added or released   (RRC reconfig): 57   <- the churn worth chasing
  SCell activated/deactivated (MAC CE)   : 82   <- normal: tracks data activity
  EN-DC available: 0    NR anchor: 0
```

Three things follow, and they matter more than the totals:

1. **The serving cell never changed.** 0 PCC changes in 143 samples — B3 /
   EARFCN 1312 / PCI 256 throughout. There is **no band flapping** in the
   reselection sense, which is what "it keeps switching bands" sounds like.
2. **57 real SCell reconfigurations** in 105 min (one per ~1.8 min): B5 being
   added and released, its PCI alternating `469 ↔ 477`, and occasionally no SCell
   at all. That is network RRM (A4/A6 + load), not the modem.
3. **82 MAC-level toggles** are the benign kind. Separately, a 95 s watch with
   zero changes shows the churn is *episodic*, not continuous — it comes in
   bursts, so a short look will often see nothing.


## 2a. Is it power saving? No — and there is nothing to switch off

Asked directly, because "power saving" is the obvious suspect for a carrier
dropping out. Every layer was checked on 2026-10-29:

| Layer | Query | Result |
|---|---|---|
| PSM (LTE power-save mode) | `AT+CPSMS?` | **ERROR** — not implemented by this firmware |
| eDRX | `AT+CEDRXS?` | **ERROR** — not implemented |
| Modem UART sleep | `AT+CSCLK?` | **ERROR** — not implemented |
| C-DRX | `qmicli --nas-get-drx` | `unknown` — the modem exposes nothing |
| QMI power state | `DMS 0x0026` | `external-source` — mains powered, so no battery policy is in play |
| CPU governor | `scaling_governor` | `ondemand`, measured running at **max 1.8 GHz** under this load |
| CPU governor A/B | fixed 4000-iteration loop | ondemand **28.67 s** vs performance **27.54 s** (~4 %), both at 1.8 GHz |

So the deactivation is **not** the module saving power: it is the network's MAC
CE and its `sCellDeactivationTimer`. A UE cannot disable that, and there is no
vendor switch for it. The host side is already at full frequency; setting
`performance` would buy ~4 % and needs a boot hook, so it is not worth a module
unless latency consistency matters more than heat.

## 2b. The toggle tracks traffic — proven, not assumed

With the typed watch running:

```
20:53:08  CHANGE scc-state d -> a      <- first traffic attempt
20:53:33  CHANGE scc-state a -> d
20:53:36  CHANGE scc-state d -> a
(no scc-set events at all)
```

Then, under sustained load (Ookla), the state stayed `cc=2` with B1 active for the
whole 70 s window — **zero events**. The pattern is: activated when data flows,
deactivated ~20–30 s after it stops. That is textbook MAC-CE behaviour, and it is
what the customer sees as "flapping" when their traffic is bursty.

## 2c. The weak B1 is not a bad antenna

`AT+CRSRP?` → `LTE,-73,-73,-75,-76` and `AT+CSINR?` → `LTE,12,11,11,10`: all four
chains within 3 dB of each other. So B1 at ≈ −90 dBm is propagation on that band
at this location, not a broken chain or pigtail — there is no hardware fix to make.
(`AT+CFUN?` **hangs** on this firmware, 20 s then killed — do not send it.)


## 2d. Correction: there are THREE SCell states, and I was collapsing two of them

`QMI_NAS_SCELL_STATE_*` in libqmi's `qmi-enums-nas.h`:

```
DECONFIGURED = 0     <- a RELEASE (RRC signalling)
DEACTIVATED  = 1     <- MAC CE, power saving
ACTIVATED    = 2
```

The first version of the sampler printed `act` for 2 and `deact` for **everything
else**, so a release (0) was indistinguishable from a deactivation (1) — exactly
the distinction this whole page is about, lost in my own tooling. The probe now
prints `act` / `deact` / `decfg` and emits a third event type, `scc-cfg`, for a
carrier that is configured or released without leaving the list. Historical lines
in the log cannot be re-typed: the information was destroyed at capture time.

## 2e. How much of it is really the deactivation timer

`docs/29` and the first version of this page said "the network's MAC CE plus its
`sCellDeactivationTimer`". The data asks for a sharper statement.

Activated-episode lengths from 196 state samples (1 Hz):

```
min 1 s · median 25 s · max 558 s · 68 episodes
reactivation gaps: 1-8 s, all common
```

The standard `sCellDeactivationTimer` values are **20–2560 ms**. Episodes of 25 s
(median) cannot be explained by that timer expiring after the last grant; they
mean the SCell kept being scheduled, or the network sent an explicit deactivation
MAC CE later. So:

- **certain:** every one of these transitions is network-signalled. A UE cannot
  activate, deactivate, configure or release an SCell by itself.
- **certain:** the toggle is not modem power saving (see §2a).
- **not knowable from the UE side:** the configured timer value — QMI exposes no
  such field, and `--nas-get-drx` answers `unknown`.
- **not resolvable at 1 Hz:** episodes of 1–7 s sit at our sampling floor, so a
  sub-2.5 s timer signature would be aliased. Sampling at 200–500 ms during a
  traffic burst is the experiment that would settle it, and the probe accepts any
  interval ≥ 1 s today.

Practical consequence: there is nothing to "fix" about the timer. What can be
changed from this side is which carriers the network is *offered* to aggregate
(band policy), which is the experiment in §4.

## 2f. There is no external re-dial trigger (checked, for the recovery work)

Looking for a sanctioned way to shorten the 23–60 s outage: `ubus list` is empty;
`/tmp/.flag_internet_has_been_disconned` sits in the dialer's **modem assert/block**
path (string neighbours: "Modem assert detected", "Modem block detected"), not the
PDP watchdog, and no vendor CGI references it; the dialer accepts no user-service
command. So a supervisor cannot ask it to re-dial — only restart it, which
`AGENTS.md` §5.4 warns against. The deployable half is the outage *record*
(`router-fix/wan-recovery/`), which is what makes the `USR_NW_AUTO_QUERY_INTERVAL`
experiment judgeable at all.

## 3. What other people report

Secondary sources, but consistent with each other and with what we measure:

- **Peplink forum** — CA falls from 5 carriers to 2 after roughly an hour, on
  three different operators, with no change in signal. Network policy/load.
- **MikroTik forum** — "cell lock LTE link flapping with CA": flapping when a
  distant cell is the PCell and the SCells are far away; locking bands or
  disabling CA was the workaround.
- **Quectel forum (EG12)** — operators apply session timers that drop CA after
  some minutes; users ask for a way to reset the session to keep CA.
- **Chinese sources** — the three-state model above, the same-coverage
  ("同覆盖") direct-add path, and the practical note that SCell activation takes
  long enough that short bursts never see CA at all
  ([CSDN](https://blog.csdn.net/dreamxf2/article/details/132830182),
  [达希物联 CA overview](https://www.simtolink.com/support/communication/carrier-aggregation.html),
  [patent CN102938902A](https://patents.google.com/patent/CN102938902A/zh)).
  Nothing SIMCom-specific: the SIM8260E/SIM8262E pages and the
  `SIM82XX_SIM83XX` AT manual document CA state queries, not CA-flapping
  behaviour, and no public SIMCom erratum for it turned up.

**No published SIMCom-specific defect matches this.** The behaviour looks like
ordinary network-side SCell management on a link whose secondary carriers are
marginal — which is also what the numbers say: B1 is held as an active SCell at
≈ −90 dBm while B5 sits at ≈ −71 dBm, so the network is aggregating the weaker
carrier and cycling the stronger one.

## 4. What can actually be done about it

The UE-side knobs are indirect:

| Lever | Effect | Cost / risk |
|---|---|---|
| Remove a band from `lte_band` (policy) | that band cannot be configured as an SCell → its churn stops | loses that carrier's capacity; reversible via `AT+CSYSSEL`/SSP |
| Pin LTE-only (`nr5g_disable`) | removes EN-DC add/drop | no 5G NSA; not needed today (`endc_available: 0`) |
| Cell lock (`AT+CCELLCFG`) | pins the PCell only — SCells still get managed | reboot on apply; hides churn, does not stop it |
| Nothing | churn is cosmetic today: **0 WAN drops in this window**, 0 PCC changes | throughput swings as 3CC↔2CC |
| CPU governor `performance` | measured ~4 % on a fixed loop, both at 1.8 GHz | heat; needs a boot hook, not worth a module |

That last row is the honest headline: **this churn is not what takes the
internet down.** `docs/29` measured the same thing and the direction was drops →
re-selection; today's recording has 0 drops and 0 reselections, with the SCell
churn running independently.

## 5. How to watch it

```sh
# live, typed: scc-set = real churn, scc-state = normal MAC toggling
ssh zlt-root '/data/qmanager/bin/qmi-probe watch 1 60'

# recorded (the sampler writes /data/zlt-flapmeter/transitions.log at 1 Hz)
scripts/flap-meter/start.sh            # if not already running
scripts/flap-meter/pull.sh
scripts/flap-meter/analyze.sh scripts/flap-meter/capture/transitions-*.log
```

The sampler prints a line only on change plus a heartbeat, so a day is a few
hundred KB. A `CHANGE scc-set` is the event to chase; `CHANGE scc-state` is the
one to ignore unless it is faster than the MAC deactivation timer (320–2560 ms in
LTE), in which case it is worth reporting to the operator.
