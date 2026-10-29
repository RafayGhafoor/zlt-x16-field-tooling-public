# Recon — Cellular Information page: (A) Active MIMO missing, (B) Spectrum in use paused / no SINR

Read-only device recon on `zlt-root` (192.168.3.1), 2026-10-26 ~18:00 device time.
QManager source: `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager`.
X16 payload: `/Users/emumba/Downloads/projects/zlt-x16/deploy-x16`.
Device state at capture: LTE only (`network.type = "LTE"`), carrier Jazz, B3 / EARFCN 1850 /
PCI 227 / 20 MHz, NR leg inactive, `ca_count = 0` (one PCC, no SCC).

---

## TL;DR

| | Symptom | Root cause (one line) |
|---|---|---|
| **A** | Active MIMO tile renders "Unavailable", `device.mimo == ""` | `device.mimo` is fed **only** by `parse_mimo`, which needs Quectel `AT+QNWCFG="lte_mimo_layers"`; the X16 AT shim answers that command with a bare `OK`, and the vendor `MIMO_STATUS` devinfo key is **empty** on this unit. Nothing else was wired. **But** devinfo `lte_rank = 2` *is* present and already parsed into `phy.lte.ri` — the honest source exists, it is just not used for this tile. |
| **B1** | Spectrum in use: every metric on the PCC row says "Not reported" — never a reading | `emit_qcainfo()` in the X16 shim blanks **all three** of RSRP/RSRQ/RSSI because its guard rejects `RSSI > -40 dBm`, and this modem's wideband RSSI is ~-32…-39 dBm. `carrier_components[0].{rsrp,rsrq,rssi,sinr}` are all `null` in the live JSON. |
| **B2** | SINR never appears in Spectrum in use | The same shim **never reads** CCAINFO's 9th field (SINR×10, measured 120–140 = 12.0–14.0 dB) and hardcodes the synthesised `+QCAINFO` SINR column to `-`. LTE SINR therefore arrives as `null`. |
| **B3** | "(Readings paused)" | `radio_info.bands.stale` is rendered only when `isStale` is true, and `isStale` is `browserNow − pollerTimestamp > 10s` — two unsynchronised clocks compared against a threshold the poller on this 1-core box already brushes (measured staleness 1–9 s, one sample at 9 s). Any router/client clock skew >10 s, or any single failed fetch, pins the card to "paused" forever. The data itself is **not** stale. |

---

## Reproduced symptoms (raw)

### Live status JSON (what the page actually consumes)

```
$ ssh zlt-root 'curl -s -b /tmp/Cq http://127.0.0.1:8080/cgi-bin/quecmanager/at_cmd/fetch_data.sh'
HTTP 200, 6076 bytes, 0.22 s; timestamp 1793019828 while `date +%s` = 1793019834
```

Relevant excerpts (verbatim, unmodified):

```json
"network": { "type": "LTE", "carrier": "Jazz", "ca_active": false, "ca_count": 0,
  "total_bandwidth_mhz": 20, "bandwidth_details": "B3: 20 MHz",
  "carrier_components": [
    { "type": "PCC", "technology": "LTE", "band": "B3", "earfcn": 1850,
      "bandwidth_mhz": 20, "pci": 227,
      "rsrp": null, "rsrq": null, "rssi": null, "sinr": null }
  ] },
"lte": { "state": "connected", "band": "B3", "earfcn": 1850, "pci": 227,
         "rsrp": -69, "rsrq": -16, "sinr": 7, "rssi": -32 },
"signal_per_antenna": { "lte_rsrp": [-72,-75,-69,-73], "lte_rsrq": [null,null,null,null],
                        "lte_sinr": [12,11,14,10] },
"device": { ..., "lte_category": "", "mimo": "" },
"phy": { "lte": { "rsrp": -72, "rsrq": -18, "rssi": -34, "sinr": 8,
                  "cqi": 12, "ri": 2, "pmi": null, "mimo_layers": null,
                  "tm_mode": null, "ul_mcs": null },
         "nr": { ...all null... }, "rrc": {"rat": "LTE"}, "registered": true, "beams": [] }
```

So: the **serving cell** has RSRP -69 / RSRQ -16 / SINR 7 / RSSI -32, the **per-antenna**
arrays are populated, `phy.lte.ri = 2` is populated — and the one object the Spectrum card
reads (`carrier_components`) is **empty of every metric**.

### The AT command behind `carrier_components`

```
$ timeout 10 /data/qmanager/bin/qcmd 'AT+CCAINFO?'
+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-73,-13,-39,140      <- 18:00:32
+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-73,-17,-36,122      <- 18:01:1x
+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-73,-20,-32,120
+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-73,-14,-39,137      <- same second as +CSINR below
```

Layout (9 fields): `label, band, earfcn, bw_rb, pci, rsrp, rsrq, rssi, sinr_x10`.
Field 9 decoded against a simultaneous per-antenna read:

```
$ timeout 10 /data/qmanager/bin/qcmd 'AT+CSINR?'
+CSINR: LTE,14,12,15,13        $ timeout 10 /data/qmanager/bin/qcmd 'AT+CRSRP?'
                               +CRSRP: LTE,-73,-256,-69,-256
$ timeout 10 /data/qmanager/bin/qcmd 'AT+CCAINFO?'   ->  ...,-73,-14,-39,137
```

137/10 = **13.7 dB**, inside the 12–15 dB antenna spread → field 9 is SINR in 0.1 dB
(not timing advance: TA would not sit at 120–140 for three samples, and the vendor
`TIMING_ADVANCE`/`ta` path is separate).

### The devinfo store (`/tmp/.devinfo_module_data`)

```
RSRP:-69  RSRQ:-15  SINR:10  RSSI:-34  bandwidth:20  CQI:13
MIMO_STATUS:            <- EMPTY (key present, no value)
SINR_5G:                <- empty (no NR leg, expected)
RSRP_5G:                <- empty
```

`lte_rank` exists in the same store (the X16 `phy_metrics` patch reads it) — proven by
`phy.lte.ri = 2` in live JSON; `deploy-x16/phy_metrics_x16_devinfo.patch:91`:
`{lte: {cqi: num("CQI"; 1; 15), ri: num("lte_rank"; 1; 8), ...}}`.

### Freshness of the poller (23 samples over ~2 min)

```
1793019692 ts=...689 (lag 3)   1793019760 ts=...759 (lag 1)
1793019738 ts=...729 (lag 9)  <- worst observed gap, poll cycle slipped to ~9-10 s
1793019743 ts=...741 (lag 2)
```
`system_health.cpu.load_1m = 3.58`, `core_count = 1`. Poll cycle nominally ~5 s, spread 1–9 s.
`/tmp/qmanager_status.json` is rewritten ~4×/20 s; `last_successful_poll` tracks `timestamp`;
`errors: []`.

---

## Root cause — file:line

### B1 — every carrier metric is null (the "no reading at all" symptom)

`deploy-x16/atcli_smd11:530-591` `emit_qcainfo()` synthesises Quectel `+QCAINFO` lines from
`AT+CCAINFO?` for `parse_ca_info`. Lines 570-582:

```sh
#   RSRP -140..-50 dBm  RSRQ -25..-3 dB  RSSI -120..-40 dBm, RSSI>=RSRP
if [ -n "$_rsrp" ] && [ -n "$_rsrq" ] && [ -n "$_rssi" ]; then
    if [ "$_rsrp" -lt -140 ] || [ "$_rsrp" -gt -50 ] ||
       [ "$_rsrq" -lt -25 ]  || [ "$_rsrq" -gt -3 ]  ||
       [ "$_rssi" -lt -120 ] || [ "$_rssi" -gt -40 ] ||          # <-- line 577
       [ "$_rsrp" -gt "$_rssi" ]; then
        _rsrp="" ; _rsrq="" ; _rssi=""                            # <-- line 579
    fi
fi
```

`_rsrp=-73` ✔, `_rsrq=-14` ✔, `_rssi=-39` → `-39 > -40` → **all three are blanked**, and the
printf at `:583-585` emits `-` for each. `parse_ca_info`'s `sane()` (`parse_at.sh:830-834`)
turns `-` into `null` (`parse_at.sh:856-870` for the LTE field map), and the jq at
`parse_at.sh:952-966` writes them as JSON `null`.

The -40 dBm floor is a Quectel assumption carried over; on this unit wideband RSSI is
-32 … -39 dBm (`lte.rssi = -32`, CCAINFO field 8 = -32/-36/-39 across three samples), i.e.
**above** the floor, so the guard fires on every PCC row, every cycle.

### B2 — SINR is never read

Same function, `:558` PCC branch:

```sh
if [ "$_label" = "PCC" ]; then
    _rsrp=$6 ; _rsrq=$7 ; _rssi=$8         # field 9 (SINR x10) is never assigned
else
    _rsrp=$7 ; _rsrq=$8 ; _rssi=$9
fi
```

and `:583-585` hardcodes the SINR column:

```sh
printf '+QCAINFO: "%s",%s,%s,LTE BAND %s,0,%s,%s,%s,%s,-\n' \
    "${_label:-SCC}" "${_earfcn:-0}" "${_bw:-0}" "${_bn:-0}" \
    "${_pci:-0}" "${_rsrp:--}" "${_rsrq:--}" "${_rssi:--}"
#                                        ^ RSRP  RSRQ   RSSI  <- SINR is the literal "-"
```

`parse_ca_info`'s LTE branch *does* read `f[10]` (`parse_at.sh:866`) and nulls `-`
(`parse_at.sh:897`), so the parser is fine — the shim withholds the value.
Front end then renders "Not reported" per metric: `lib/radio-info.ts:137-171`
(`sinr` metric, `labelKey: "sinr"`) and `components/cellular/radio/active-bands-card.tsx`
(`MetricCell`, `radio_info.bands.metric.not_reported_short`).

### B3 — "(Readings paused)"

Render site — `components/cellular/radio/active-bands-card.tsx:539-560`:

```tsx
<p className={cn("text-[13px]", isStale ? "text-warning-on-surface" : "text-on-surface-variant")}>
  <SwapLabel swapKey={isStale ? "stale" : "live"}>
    {isStale ? t("radio_info.bands.stale")      // "Readings paused", cellular.json:1949
             : t("radio_info.bands.description", { count: summary.carrierCount })}
```

`isStale` comes from `hooks/use-modem-status.ts`:
- `:24` `const STALE_THRESHOLD_SECONDS = 10;`
- `:110-111` `const age = Math.floor(nowMs / 1000) - json.timestamp; setIsStale(age > STALE_THRESHOLD_SECONDS);`
- `:118-124` any fetch failure also sets `setIsStale(true)` and only a later success clears it.

Two independent defects:
1. **Two clocks, one subtraction.** `json.timestamp` is stamped by the router's clock;
   `nowMs` is the browser's. A router clock 10 s+ *behind* the client (this box has **no**
   NTP daemon in `ps`; time comes from `qmanager-timesync`) pins the card to "paused"
   permanently even though every poll is fresh. Verified counter-evidence: at capture the
   served `timestamp` was 4–6 s old while `date +%s` on the box and on the host differed by
   <5 s — so the data is **not** stale.
2. **No margin.** Measured poll lag 1–9 s (one 9 s sample under `load_1m = 3.58` on 1 core).
   With a 10 s threshold a busy box crosses it; the poller cycle is not bounded to 5 s.

`receivedAtMs` (client wall clock at response arrival) already exists in the hook (`:96-101`)
and is the correct basis for freshness — it never mixes clocks.

### A — Active MIMO

Render site — `components/cellular/radio/summary-tiles.tsx:225-247, 345-395`:

```tsx
mimo: string | null;                             // "device.mimo verbatim — LTE 1x2 | NR 2x4"
const rawMimo = (mimo ?? "").trim();
const mimoParts = rawMimo && rawMimo !== "-" ? rawMimo.split("|")… : [];   // [] -> "Unavailable"
```

Fed from `components/cellular/cellular-information.tsx:180`:
`mimo={data?.device?.mimo ?? null}` → type `types/modem-status.ts:309` (`mimo: string`).

Backend — `scripts/usr/bin/qmanager_poller:2792` `--arg mimo "$t2_mimo"` → `:2921`
`device: { …, mimo: $mimo }`. `t2_mimo` is set **only** by `parse_mimo`:

- `scripts/usr/lib/qmanager/parse_at.sh:685-733` — expects
  `+QNWCFG: "lte_mimo_layers",<ul>,<dl>` / `+QNWCFG: "nr5g_mimo_layers",<ul>,<dl>`.
- Poller call sites: `qmanager_poller:1564-1571` (boot) and `:2122-2148` (per-cycle, mode-gated).
- X16 shim: `deploy-x16/atcli_smd11:890`
  `AT+QNWCFG*|AT+QGETCAPABILITY*|AT+QMAP*|AT+QNWINFO*|AT+QCSQ*) printf 'OK\n' ;;`
  → the command answers `OK` with **no** payload, so the grep in `parse_mimo` never matches and
  `t2_mimo` stays `""` (`qmanager_poller:287`). This is why `"mimo": ""` in the live JSON.
- Second, unused source: `scripts/usr/lib/qmanager/phy_metrics.sh:217-218`
  (`lte_mimo_layers: (.lte_rank | num)`) needs `ubus`/`modemd`, which does not exist here
  (`qm_phy_modemd` returns 2). The X16 devinfo patch supplies `ri` from `lte_rank`
  (`deploy-x16/phy_metrics_x16_devinfo.patch:91`), which is why `phy.lte.ri = 2` — but the
  MIMO *tile* reads `device.mimo`, not `phy`.
- Vendor source: `MIMO_STATUS` in `/tmp/.devinfo_module_data` is **empty on this unit**
  (verified twice). So the stock UI, which renders that same key, has nothing to show either.

**Stock UI check (partial):** the stock UI's HTML is server-rendered from vendor binaries —
`/tzwww/js/{dashboard,info}/*.js` contain **no** `MIMO_STATUS` and **no** `CCAINFO` reference
(grep over those two dirs, no matches), so the parsing happens in the CGI binaries, not in
browser JS. `MIMO_STATUS` being empty in the dialer's own store is the strongest available
evidence that the stock UI shows no MIMO value either. Remaining **UNKNOWN**: whether some
other stock page renders a rank/MIMO word from a different key — resolved by opening the
stock UI (`http://192.168.3.1/` → Network / Status page) in a browser and reading the
labels, which I could not do headlessly.

---

## Fix plan

### B1 + B2 — `deploy-x16/atcli_smd11`, `emit_qcainfo()` (lines 530-591)

1. **RSSI floor.** Line 577: `[ "$_rssi" -gt -40 ]` → `[ "$_rssi" -gt -20 ]`
   (this box's wideband RSSI is -32 … -39; -20 still rejects the `-1`/garbage cases the
   guard exists for). Keep `_rsrp -gt _rssi` — it is the real sanity relation.
2. **Read SINR.** In the PCC branch (line 558) add `_sinr=$9`; in the SCC branch (line 560)
   the equivalent offset is `_sinr=$10` **only after** re-measuring a real SCC row — there is
   no CA on this SIM (one PCC), so that offset is currently untested and must not be guessed.
3. **Emit it.** Line 583: replace the trailing literal `-` with a 10th `%s` and pass an
   **integer dB** value derived from the 0.1 dB field:
   ```sh
   case "$_sinr" in ''|*[!0-9]*) _sinr_db="-" ;; *) _sinr_db=$(( (_sinr + 5) / 10 )) ;; esac
   printf '+QCAINFO: "%s",%s,%s,LTE BAND %s,0,%s,%s,%s,%s,%s\n' \
       "${_label:-SCC}" "${_earfcn:-0}" "${_bw:-0}" "${_bn:-0}" \
       "${_pci:-0}" "${_rsrp:--}" "${_rsrq:--}" "${_rssi:--}" "${_sinr_db:--}"
   ```
   Integer, not `13.7`: `parse_ca_info`'s `sane()` (`parse_at.sh:830-834`) rejects any
   character outside `[0-9-]`, so a decimal point would be nulled. `parse_at.sh:866` reads
   `f[10]` and `:897` maps `-` to null, no change needed downstream.
4. Do **not** touch `parse_at.sh` / `parse_ca_info` — its Quectel field map is correct and
   shared with the RG520N; the shim is the right translation layer.
5. Units/tests: `tests/` in this repo holds host-side shim tests; add a case feeding the
   three measured CCAINFO lines above and asserting
   `rsrp=-73, rsrq=-17, rssi=-36, sinr=12` (and that the empty-`+CCAINFO: "PCC"` fallback
   still yields all nulls).

### B3 — staleness (two files, pick one; do both for correctness)

1. `hooks/use-modem-status.ts:110-111` — stop subtracting two clocks. Compute age from the
   client arrival stamp:
   ```ts
   const age = (nowMs - lastArrivalMs) / 1000;      // pure client clock
   ```
   (or simply keep `receivedAtMs` and treat `nowMs - receivedAtMs > STALE_THRESHOLD` as stale);
   and raise `STALE_THRESHOLD_SECONDS` (line 24) to **20** so a 9 s poll cycle under
   `load_1m ≈ 3.6` cannot trip it. Fall back to the `json.timestamp` comparison only if
   `receivedAtMs` were ever null (it cannot be, once a fetch landed).
2. Optionally also surface the box's own poll health (`errors[]`, `last_successful_poll`)
   instead of inferring it, so "paused" means "the poller said so", not "a clock disagreed".

### A — Active MIMO

The modem genuinely does not publish a layer count in the AT surface used here
(`AT+QNWCFG` unsupported → bare `OK`; `MIMO_STATUS` empty; `CCAINFO` has no rank field).
The honest reading available today is the **rank** from the devinfo store:
`phy.lte.ri = 2` / `phy.nr.ri` (`deploy-x16/phy_metrics_x16_devinfo.patch:91`, key
`lte_rank`). Options, in order of preference:

1. **Derive the tile from `phy.*.ri` when `device.mimo` is empty** —
   `components/cellular/cellular-information.tsx:180` + `summary-tiles.tsx:239-247`:
   pass `phy?.lte?.ri` / `phy?.nr?.ri` as a fallback and render `LTE 2x2` (rank 2 ⇒ 2 DL
   layers; label it "rank"/"layers", not UL×DL, unless UL rank is known). `types/modem-status.ts`
   already carries `phy` (see `phy.lte.ri` in the live JSON), so this is a typing + prop change
   plus a copy key, not a backend change.
2. Wire `t2_mimo` from the same devinfo keys in the X16 `phy_metrics` patch →
   `device.mimo` (`qmanager_poller:2792`), so *every* consumer (summary tiles,
   antenna-statistics `context-tiles.tsx:153-205`) gets it from one place. Cleaner long-term,
   touches a `.patch` file and the poller.
3. **If product wants the truth stated instead**: keep the tile but make the unavailable
   caption explicit — `radio_info.tiles.mimo.caption_unavailable` currently reads as a generic
   "not available"; a copy change to "This modem does not report MIMO layers" is the honest
   one-liner. Cheapest, zero risk.

Do **not** invent a layer count from antenna count (4 antennas ≠ 4 layers) — `lte_rank` is
the only measured rank available.

---

## How to verify

B1/B2 (after deploying the shim):
```sh
ssh zlt-root 'timeout 10 /data/qmanager/bin/qcmd "AT+CCAINFO?"'        # raw, unchanged
ssh zlt-root 'timeout 20 sh -c "sleep 12; \
  sed -n \"s/.*carrier_components//p\" /tmp/qmanager_status.json | head -1"'   # expect >0 bytes
ssh zlt-root 'timeout 20 grep -A12 carrier_components /tmp/qmanager_status.json'
# expected (single-carrier LTE): rsrp/rsrq/rssi non-null and sinr a small integer 5..25
```
Then in the UI (`http://192.168.3.1:8080/cellular/`, password `<redacted-password>`): Spectrum in use
must show RSRP/RSRQ/RSSI/SINR bars on the PCC row, description "1 active carrier"
(or "2 active carriers" after CA), and no "(Readings paused)".
Cross-check the numbers against `AT+CRSRP?` / `AT+CSINR?` in the same second (they were
-73 dBm and 12–15 dB at capture).

B3 (without a code change): open the page and watch the description line for 60 s — with
the fix its text must not flip to "Readings paused" while
`/tmp/qmanager_status.json` mtime advances every ≤10 s. To prove the clock theory before the
fix, set the *client* clock forward by ≥15 s; the card pins to "paused" while the file is
provably fresh.

A: after option 1/2, `grep -A3 '"mimo"' /tmp/qmanager_status.json` should read
`"mimo": "LTE 2x2"` (or `phy.lte.ri` non-null and the tile showing it), and the tile must
agree with `phy.lte.ri` in the same snapshot.

---

## Risks / what must not be touched

- **`AT+CCAINFO?` is the only CA source here.** Do not replace it with `AT+QCAINFO` (SIMCom
  has none), and do not add `AT+QNWCFG` probes — the shim deliberately answers those with a
  bare `OK` (`atcli_smd11:890`); sending them upstream to the daemon risks the wedge described
  in RECON-BRIEF (no AT timeouts; `/bin/dialer` loses the WAN).
- **SCC offsets are unmeasured.** There is no carrier aggregation on this SIM
  (`ca_count = 0`), so the SCC branch (`atcli_smd11:560`, `_rsrp=$7 …`) cannot be validated
  now. Leave it exactly as-is unless an SCC row can be captured; a wrong offset here plots a
  bogus measured value.
- `parse_at.sh`'s Quectel field map is shared with the RG520N build — patch the shim, not the
  parser, or the other platform loses fields.
- Raising `STALE_THRESHOLD_SECONDS` weakens the "poller went quiet" signal; the safer change
  is switching to the client-arrival clock (which is exact) and keeping 10 s.
- The 1-core box is already at `load_1m 3.58`; anything added to the poll cycle (extra AT,
  extra `jq`) should be avoided — the SINR fix adds fields, not commands.
- Nothing was installed, restarted or written on the device during this recon; the only
  device writes were `/tmp/Cq`, `/tmp/fd.json`, `/tmp/cel.html` (tmpfs, disposable).
