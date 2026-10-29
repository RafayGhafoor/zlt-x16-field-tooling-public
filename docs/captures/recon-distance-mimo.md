# Recon — cell distance (LTE/NR), MIMO Layers, UL MCS on the X16

Read-only investigation. Nothing installed, edited or restarted. Device probes: 7 ssh
sessions, each under `timeout`, no `grep -r` on the device outside `/tzwww/js|html` (5 MB total).

Sources:
- QManager: `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager`
- deployed payload: `/Users/emumba/Downloads/projects/zlt-x16/deploy-x16/`
- device: `/data/qmanager/lib/phy_metrics.sh` (44 016 B, = upstream + `phy_metrics_x16_devinfo.patch`)

---

## 0. One correction to the premise, up front

**The Detailed Metrics page does not show cell distance.** There is no `distance` anywhere
under `components/cellular/detailed-metrics/`:

```
$ grep -rn "distance" components/cellular/detailed-metrics/
(no output)
```

The two distance figures live on **two other** surfaces, and both read the same two fields:

| Surface | Code |
|---|---|
| Dashboard `MetricsCard` | `components/dashboard/device-metrics.tsx:382-391`, rows at `:672` (LTE) and `:703` (NR), tooltips at `:685`/`:716` |
| Radio info card | `components/cellular/radio/cellular-information-card.tsx:494-500`, row at `:601` |

MIMO Layers and UL MCS **are** on the Detailed Metrics page (`phy-cards.tsx:87,92,146,151`),
and they come from `.phy` as the brief says. Distance does **not** — see §1. If the customer
is looking at distance *on* the Detailed Metrics route, the deployed bundle is not this
source; that would need a look at `/data/qmanager/www/_next/static/chunks/*` (not done — it
is a `grep -r` under `/data`, which the rules forbid).

---

## 1. LTE / NR cell distance

### 1.1 Symptom, reproduced

```
$ ssh zlt-root 'grep -o "\"[a-z_0-9]*\":[^,{}]*" /tmp/qmanager_status.json | grep -iE "ta|mimo|mcs"'
"tac": 55383
"ta": null            <- LTE block
"tac": null
"ta": null            <- NR block
"cqi": 11
"mimo_layers": null
"ul_mcs": null
```

Both distance rows therefore render `ABSENT` (`device-metrics.tsx:382-391` returns the
sentinel for a null km), and `cellular-information-card.tsx:602` takes the "no hint" branch.

### 1.2 Where it is displayed and what it reads

```ts
// components/dashboard/device-metrics.tsx:382
const lteKm = calculateLteDistance(lteData?.ta ?? null);
const nrKm  = calculateNrDistance(nrData?.ta ?? null);
```

`lteData`/`nrData` are `ModemStatus.signal.lte` / `.nr` — i.e. **`/tmp/qmanager_status.json`,
not `.phy`**, fetched by `hooks/use-modem-status.ts:27`:

```ts
const FETCH_ENDPOINT = "/cgi-bin/quecmanager/at_cmd/fetch_data.sh";
```

Formulas (`types/modem-status.ts:1031-1054`): LTE takes a **TA index** (`NTA = 16*ta`,
`distance = c*NTA*Ts/2`, Ts = 1/30720000); NR takes a raw **NTA count** in units of
Tc = 1/(480000·4096). Both return `null` for 0, deliberately.

`.phy` has no `ta` key at all — `QM_PHY_SNAPSHOT_JQ` (`phy_metrics.sh:493-523`) emits
`rsrp/rsrq/rssi/sinr/cqi/ri/pmi/mimo_layers/tm_mode/ul_mcs` for LTE and never a timing
advance. So distance is out of `.phy`'s contract by design; it is a **poller** field.

### 1.3 Root cause

`scripts/usr/bin/qmanager_poller:2120-2146` (Tier 2, two AT groups):

```sh
local nr_cmd='AT+QNWCFG="nr5g_time_advance"'      # :2121
...
local lte_cmd='AT+QNWCFG="lte_time_advance"'      # :2138
result=$(ca_ext_read "$lte_cmd")
if [ -n "$result" ]; then parse_time_advance "$result"; ... fi
```

`parse_time_advance` (`scripts/usr/lib/qmanager/parse_at.sh:975-1010`) only accepts
`+QNWCFG: "lte_time_advance",<en>,<ta>` / `"nr5g_time_advance",<en>,<nta>` — **Quectel
commands**. This module is a SIMCom SIM8260E, and `AT+QNWCFG` is not in the shim allowlist
(`deploy-x16/atcli_smd11:96-104`), so `at_raw()` answers `ERROR` immediately without touching
the daemon (`atcli_smd11:150-153`). `lte_ta`/`nr_ta` therefore stay `""` and the snapshot
builder defaults them to null (`qmanager_poller:2756`, `:2769`) → `ta: $lte_ta`
(`qmanager_poller:2899` and `:2907`).

The line that is wrong is `qmanager_poller:2121`/`:2138`: the read is issued against a command
set this modem does not have. There is **no fallback** on this box, so `ta` is null on every
cycle, forever.

### 1.4 What works on the box — measured

```
$ ssh zlt-root 'export LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib; qmicli -d qrtr://3 --nas-get-cell-location-info'
[qrtr://3] Successfully got cell location info
...
	Serving Cell ID: '227'
	Cell [0]: Physical Cell ID: '227'  RSRQ: '-16.8' dB  RSRP: '-72.3' dBm  RSSI: '-35.6' dBm
LTE Timing Advance: '8' us
```

**LTE TA is available, in microseconds**, ~40 ms, no AT lock. What is *not* available:

```
$ qmicli --nas-get-signal-info
LTE: RSSI -40 / RSRQ -19 / RSRP -74 / SNR 9.2
5G:  RSRP 'n/a'  SNR 'n/a'  RSRQ 'n/a'        <- NR leg down (network_type_str:4G), and:

$ grep -a -o "NR5G[A-Za-z0-9 ]{0,28}" qmicli   ->  NR5G NSA band preference / NR5G SA band preference / NR5G bands
$ grep -a -o "[A-Za-z0-9 ]{0,24}Timing Advance" qmicli -> "LTE Timing Advance", "Timing Advance"
$ qmicli --version -> qmicli 1.34.0
```

The deployed `qmicli` is **1.34.0 and knows only LTE timing advance**. Its
`--nas-get-cell-location-info` prints no NR5G section at all (no NR5G cell-info strings in the
binary, no `NR5G Timing Advance` label). `--nas-get-lte-cphy-ca-info` answers
`QMI protocol error (74): 'InformationUnavailable'` with no CA configured, and carries no
MIMO/TA fields in any case.

> **NR cell distance: the value does not exist on this box with the deployed toolchain.**
> `AT+QNWCFG="nr5g_time_advance"` is refused by the shim; libqmi 1.34.0 has no NR TA. The
> vendor store has no timing advance of any kind. A newer libqmi (NR5G cell info TLVs) is the
> only plausible future source and it is **unverified** — I did not test it and would not
> ship it on this evidence. Recommend the UI state "not reported by this modem" for NR
> distance, exactly as `nr.tx_power`/`nr.pathloss` already do.

**Unit trap for the LTE fix.** `calculateLteDistance` wants a TA **index**; QMI reports
**microseconds**. One LTE TA index = 16·Ts = 16/30720000 s = 0.520833 µs, so
`ta_index = round(us / 0.520833)`. Feeding 8 µs straight in as an index would under-report by
1.92×. Cross-check with index 8/0.520833 = 15.36:
`3e8 · 16·15.36 / 30720000 / 2 = 1.20 km`, and the direct
`c·8µs/2 = 1.20 km` — the two agree, which is the proof that the conversion is the right one.

Two further sources tried and ruled out:

```
$ qcmd "AT+CCAINFO?"  -> +CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-72,-14,-38,128   (one line, no TA)
$ qcmd "AT+CNWINFO?"  -> ERROR   (not in the shim allowlist; the old capture's answer came
                                  from /bin/atcmd directly, docs/captures/at-capture-2026-10-26.txt:116-118)
```

### 1.5 Fix (minimal)

**File A — `scripts/usr/lib/qmanager/qmi_read.sh`** (deployed as
`/data/qmanager/lib/qmi_read.sh`), add one reader next to `qm_qmi_signal`:

```sh
# qm_qmi_timing_advance -> {"us":8,"ta_index":15} | 2 unavailable | 3 call failed | 4 no field
qm_qmi_timing_advance() {
    local out
    out=$(_qm_qmi_raw 'Timing Advance' --nas-get-cell-location-info) || return $?
    printf '%s' "$out" | awk -F"'" '
        /LTE Timing Advance:/ { us = $2 + 0
            printf "{\"us\":%d,\"ta_index\":%d}\n", us, int(us/0.5208333 + 0.5); found=1; exit }
        END { exit (found ? 0 : 4) }'
}
```

Reuse `_qm_qmi_raw`'s existing marker test (it already takes a marker string) and its
exported `LD_LIBRARY_PATH` block — see `deploy-x16/qmi_read_ld_library_path.patch`, which
exists precisely because this firmware's `ash` drops a `VAR=val` prefix on a shell function.
Document it in the header's function list (`qmi_read.sh:26-34`).

**File B — `scripts/usr/bin/qmanager_poller`**, Tier 2, immediately after the LTE group
(`:2142-2146`) and its "NO else-branch" comment:

```sh
# This firmware has no AT+QNWCFG at all (SIMCom). Take the same number from QMI,
# which needs no AT lock, rather than leaving the dashboard's distance row blank.
if [ -z "$lte_ta" ]; then
    _qta=$(qm_qmi_timing_advance 2>/dev/null) || _qta=""
    case "$_qta" in
        *'"ta_index":'*)
            _v=$(printf '%s' "$_qta" | sed -n 's/.*"ta_index":\([0-9][0-9]*\).*/\1/p')
            [ -n "$_v" ] && [ "$_v" -gt 0 ] && [ "$_v" -le 1282 ] && lte_ta="$_v" ;;
    esac
fi
```

Guard rails kept: the range check is `calculateLteDistance`'s own (1..1282, and 0 means "no
data"), nothing is written when the read fails, and the poller's existing "never blank a good
reading" invariant is untouched (this only ever *sets* `lte_ta`).

Do **not** touch `parse_time_advance` (it is correct for the Quectel fleet) and do **not** add
`AT+CNWINFO?`/`AT+QCAINFO` to `atcli_smd11`'s allowlist — `atcmd_daemon` has no timeout and one
unanswered command takes the WAN down (`atcli_smd11:70-80`).

### 1.6 Verify

```sh
ssh zlt-root 'grep -o "\"ta\":[^,]*" /tmp/qmanager_status.json'
#   expect "ta":12  (or whatever this cell's index is) instead of "ta":null, within 1 Tier-2 pass (~75 s)
ssh zlt-root 'export LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib; /data/qmanager/lib/qmi/bin/qmicli -d qrtr://3 --nas-get-cell-location-info | grep "Timing Advance"'
#   cross-check: us*1.92 must equal the published index (8 us -> 15)
```
Then the dashboard's "LTE cell distance" row must show a value ~1.2 km for 8 µs, and the
tooltip (`t("metrics.lte_distance_tooltip", {ta})`) the same index.

---

## 2. MIMO Layers (LTE and NR)

### 2.1 Where it is displayed

```tsx
// components/cellular/detailed-metrics/phy-cards.tsx:87-90
<MetricFigure metric="lte.mimo_layers" label={m("mimo_layers")} value={lte.mimo_layers} />
// :146-149
<MetricFigure metric="nr.mimo_layers"  label={m("mimo_layers")} value={nr.mimo_layers} />
```
Field: `.phy.lte.mimo_layers` / `.phy.nr.mimo_layers`, served by
`fetch_signal_history.sh?range=now`.

### 2.2 Where it is supposed to come from, and why it is null

Join rule, `scripts/usr/lib/qmanager/phy_metrics.sh:506` and `:515`:

```jq
mimo_layers: (($a.lte.mimo_layers | n) // ($m.lte_mimo_layers | n)),
...
mimo_layers: (($a.nr.mimo_layers  | n) // ($m.nr_mimo_layers  | n)),
```

On this box `$a` is produced by the X16 patch's `qm_phy_x16_at`, and `$m` by
`qm_phy_x16_modemd`. **Both sides are hard-coded to null**, in the deployed file
`/data/qmanager/lib/phy_metrics.sh`:

```
/data/qmanager/lib/phy_metrics.sh:307   lte_rank: null, nr_rank: null}          <- $m (qm_phy_x16_modemd)
/data/qmanager/lib/phy_metrics.sh:326   {lte: {cqi: num("CQI";1;15), ri: num("lte_rank";1;8), pmi: null,
                                              mimo_layers: null, tm_mode: null, ul_mcs: num("UL_MCS";0;31)},
/data/qmanager/lib/phy_metrics.sh:329        ul_mcs: num("UL_MCS_5G";0;31), tx_power: null},
```

(`:329` is the tail of the `nr` object, whose `mimo_layers: null` is on `:328`.)

So the `//` in `QM_PHY_SNAPSHOT_JQ` falls through to a null that was null by construction,
twice over. The evidence that the *number* is reachable from the very same store is on the
line above: `:325` reads `ri: num("lte_rank";1;8)` from `/tmp/.devinfo_module_data` and
publishes it. Measured, same file, same instant:

```
$ ssh zlt-root 'grep -E "MIMO_STATUS|lte_rank|nr_rank|UL_MCS" /tmp/.devinfo_module_data'
UL_MCS:
UL_MCS_5G:
nr_rank:
lte_rank:2          <- LIVE, and already used for .phy.lte.ri
MIMO_STATUS:        <- EMPTY
```

**`MIMO_STATUS` is not a source: it is empty on this firmware.** Two samples 20 minutes apart,
both empty, dialer wrote the file ~1 Hz throughout (`-rw-r--r-- 2238 Oct 26 18:01`).

### 2.3 What exists

- **LTE layers: `lte_rank` (the devinfo store).** `lte_rank` is the rank indication, and 3GPP
  RI *is* the number of transmission layers — so `mimo_layers = lte_rank` is the honest
  reading, not a fabrication. It is live (2, and 4 earlier in the same session).
- **NR layers: `nr_rank`**, same argument; empty today because there is no NR leg
  (`network_type_str:4G`). It fills when NR comes up.
- **`AT+CCAINFO?` gives no layer count.** Measured now:
  `+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-72,-14,-38,128` — one PCC line, no trailing
  fields, and with CA active (2026-10-26 capture) the SCC rows carry `<rsrp,rsrq,rssi,sinr>`
  plus 1–3 undecoded trailing integers (`...,134,2,2,8` / `...,131,0`) whose meaning is not
  documented anywhere in the tree. **Do not decode them.** There is no verified per-CC MIMO
  field in `AT+CCAINFO?`.
- **The stock UI never shows MIMO at all** — see §4.

### 2.4 Fix (minimal, 2 tokens)

Edit the patch `deploy-x16/phy_metrics_x16_devinfo.patch` (the `qm_phy_x16_at` hunk), which
lands as `/data/qmanager/lib/phy_metrics.sh:326` and `:328`:

```diff
-      {lte: {cqi: num("CQI"; 1; 15), ri: num("lte_rank"; 1; 8), pmi: null,
-             mimo_layers: null, tm_mode: null, ul_mcs: num("UL_MCS"; 0; 31)},
-       nr:  {cqi: num("CQI_5G"; 1; 15), ri: num("nr_rank"; 1; 8), pmi: null,
-             mimo_layers: null, dl_mcs: num("DL_MCS_5G"; 0; 31),
+      {lte: {cqi: num("CQI"; 1; 15), ri: num("lte_rank"; 1; 8), pmi: null,
+             # RI is the layer count on 3GPP; the store's separate MIMO_STATUS is
+             # never populated on this firmware (measured twice, 2026-10-26).
+             mimo_layers: num("lte_rank"; 1; 8), tm_mode: num("lte_tm"; 1; 8),
+             ul_mcs: num("UL_MCS"; 0; 31)},
+       nr:  {cqi: num("CQI_5G"; 1; 15), ri: num("nr_rank"; 1; 8), pmi: null,
+             mimo_layers: num("nr_rank"; 1; 8), dl_mcs: num("DL_MCS_5G"; 0; 31),
```

(Leave `$m`'s `lte_rank: null` at `:307` alone — `$a.lte.mimo_layers` is now non-null, so the
`//` never reaches it. Changing both would just be two places to keep in sync.)

**Bonus, same line, free:** the store also has `lte_tm:4` (live) and `lte_txpower:-15`, so
`lte.tm_mode` can be filled from the same edit and `lte.tx_power` from a one-line change to
the `$a` object. Out of scope here; note it for whoever takes this.

### 2.5 Verify

```sh
ssh zlt-root 'curl -s "http://127.0.0.1:8080/cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh?range=now" | jq ".phy.lte.mimo_layers, .phy.nr.mimo_layers"'
#   expect: 2   and   null   (NR leg down); must equal `grep '^lte_rank:' /tmp/.devinfo_module_data`
```
Only the `phy_metrics.sh` payload needs re-pushing (`deploy-x16/install.sh`); no service
restart is required beyond the CGI reading the new file per request — but the archive CSV adds
no column, so nothing downstream shifts.

---

## 3. UL MCS (LTE and NR)

### 3.1 Where it is displayed

```tsx
// phy-cards.tsx:92
<MetricFigure metric="lte.ul_mcs" label={m("ul_mcs")} value={lte.ul_mcs} />
// phy-cards.tsx:151
<MetricFigure metric="nr.ul_mcs"  label={m("ul_mcs")} value={nr.ul_mcs} />
```
Fields `.phy.lte.ul_mcs` / `.phy.nr.ul_mcs`.

### 3.2 Where it comes from

`phy_metrics.sh:508` — AT-only, no modemd fallback, by design:

```jq
ul_mcs: ($a.lte.ul_mcs | n),
```
and the AT side is `AT+QNWCFG="lte_ulMCS"` (`QM_PHY_AT_LTE`, `phy_metrics.sh:296`), parsed at
`QM_PHY_AT_AWK:340-345`. `AT+QNWCFG` is Quectel → shim answers `ERROR` → the parse yields
nothing → the X16 patch substitutes `qm_phy_x16_at`, which reads the vendor store
(`/data/qmanager/lib/phy_metrics.sh:326`, `:329`):

```jq
ul_mcs: num("UL_MCS"; 0; 31)      # LTE
ul_mcs: num("UL_MCS_5G"; 0; 31)   # NR
```

### 3.3 Why it is null — the store key is empty, not missing

```
$ ssh zlt-root 'grep -E "^(UL_MCS|DL_MCS|UL_MCS_5G|DL_MCS_5G|UL_GRANT_4G|DL_GRANT_4G|DL_BLER|mac_lte_ul)" /tmp/.devinfo_module_data'
UL_MCS:
DL_MCS:3            <- DL fills
UL_MCS_5G:
DL_MCS_5G:
UL_GRANT_4G:
DL_GRANT_4G:
DL_BLER:
mac_lte_ul:0
```

`UL_MCS:` is present but empty (`num()` correctly returns null — empty is not 0), in two
samples 20 minutes apart, while `DL_MCS`, `CQI` and `lte_rank` fill from the same file. The
whole grant/BLER block (`UL_GRANT_4G`, `DL_GRANT_4G`, `DL_BLER`, `UL_BLER`) is empty too, so
this is **not** "no uplink grant this second" but "the dialer's 0,0,6 dump does not populate
the uplink block on this firmware". The patch is doing the right thing with the data it has.

**UNKNOWN:** whether `UL_MCS:` ever fills. What would resolve it: sample the store for ~15 s
while saturating the uplink (e.g. `dd if=/dev/zero bs=8k count=512 | timeout 10 curl -s -o /dev/null
--data-binary @- http://cloudflare.com/cdn-cgi/trace`, sampling `grep '^UL_MCS:'` every 2 s).
I did not run it — it is traffic on a fragile WAN and outside this phase's budget.

**No independent source exists.** `AT+CNWINFO?` carries `64QAM,16QAM` (max UL *modulation*
order, `docs/captures/at-capture-2026-10-26.txt:118`), not an MCS index, and it is not in the
shim allowlist anyway. QMI has no MCS verb (`--nas-get-signal-info` is level only;
`--nas-get-lte-cphy-ca-info` is CA-only and `InformationUnavailable` here). Inventing an MCS
from a modulation order would be a fabricated number.

### 3.4 Fix

**None that produces a value.** Recommended change is presentational and honest: when
`.phy.lte.ul_mcs` has been null for a whole session, the row should read "Not reported by this
modem" like `lte.tx_power` does (`UnavailableMetricRow`, `phy-cards.tsx:91`), instead of an
empty `MetricFigure` that reads like a bug. That is a one-line swap at `phy-cards.tsx:92`,
plus the same at `:151` **only if** NR UL MCS proves unreachable too — but `UL_MCS_5G:19` was
observed in the 2026-10-26 capture (`docs/captures/recon-detail-metrics.md:222`), so the NR row
must keep its live path and is simply null while the NR leg is down.

Verify: after the §3 U1 experiment, either `grep '^UL_MCS:'` returns a number under load (then
everything already works and no code changes) or it does not (then take the presentational fix
and write the measurement into the README).

---

## 4. How the stock UI compares

Vendor web app: `mini_httpd`, `-C /tmp/mini_httpd.conf`, `dir=/tzwww` (`/proc/1237/cwd ->
/tzwww`). Its data is the same `/tmp/.devinfo_module_data` the dialer writes.

```
$ ssh zlt-root 'grep -ril mimo /tzwww/js /tzwww/html'      # 4.0 MB js + 1.0 MB html, 40 s cap
(no output)
$ ssh zlt-root 'grep -ril distance /tzwww/js /tzwww/html'
/tzwww/js/echarts.min.js  /tzwww/js/element.js  /tzwww/js/language/en.js
/tzwww/js/manage/meshAdvSetting.js  /tzwww/js/vis.js      # all incidental (chart axes, mesh config)
```

- **MIMO Layers — the stock UI has no such field.** Not in the JS, not in the HTML, and its
  only plausible backing key `MIMO_STATUS:` is empty. The customer's expectation is wrong on
  this one; the honest deliverable is RI (= layers) with a glossary note, or a "not reported"
  row.
- **UL MCS — the stock UI shows it only for NR** (`UL_MCS_5G`), and that key fills on this box
  when NR is up. It shows nothing for LTE either, because `UL_MCS:` is empty for both UIs.
- **Distance — the stock UI shows no distance at all.** It is a QManager-derived figure
  (`calculateLteDistance` / `calculateNrDistance`). So the reference here is the *physics*, not
  the vendor: QMI's LTE TA is the correct input and the vendor has nothing to copy.

---

## 5. Risks / do not touch

1. **Do not add AT commands to the shim allowlist** to reach `AT+CNWINFO?`/`AT+QCAINFO`.
   `atcmd_daemon` serves one request with no timeout; that has already taken the WAN down
   (`atcli_smd11:70-80`, `AGENTS.md` §5.4).
2. **Do not restart the poller or any qmanager unit to test.** The CGI re-reads
   `phy_metrics.sh` per request, so §2 needs no restart. §1's poller edit is picked up on the
   poller's next start; schedule it with the normal deploy, not by hand on a live data call.
3. **QMI is read-only and lock-free** (`qmi_read.sh:9-16`) but it shares the QRTR NAS node with
   whatever else uses `qrtr://3`. One `--nas-get-cell-location-info` is ~40 ms and is measured
   safe; do not put it in a tight loop.
4. **Unit convention is the trap in §1.** Publishing QMI's microseconds into a field the UI
   treats as an index under-reports distance by 1.92×. The `ta_index` conversion (÷0.520833)
   is verified arithmetically against `c·t/2`; keep the 1..1282 range guard so a 0 still means
   "no data".
5. **NR distance has no source.** Do not synthesise it, and do not reuse LTE TA for it — the
   NR formula divides by Tc, not Ts.
6. `lte_rank` is live and *varies* (2, and 4 earlier). Reading it into `mimo_layers` is fine;
   caching it anywhere would not be.

---

## 6. Summary table

| # | Figure | Display | Field | Null because | Source that works | Change |
|---|---|---|---|---|---|---|
| 1 | LTE cell distance | `device-metrics.tsx:382`; `cellular-information-card.tsx:494` | `signal.lte.ta` (status.json — **not** `.phy`) | `qmanager_poller:2138` sends Quectel `AT+QNWCFG="lte_time_advance"`; shim `ERROR`s it | QMI `--nas-get-cell-location-info` → `LTE Timing Advance: '8' us` | `qmi_read.sh` + poller fallback, µs→index ÷0.520833 |
| 2 | NR cell distance | `device-metrics.tsx:383`; `cellular-information-card.tsx:495` | `signal.nr.ta` | `qmanager_poller:2121` sends `"nr5g_time_advance"`; refused | **none** — libqmi 1.34.0 has no NR TA; no vendor TA key | mark "not reported"; do not invent |
| 3 | MIMO Layers (LTE) | `phy-cards.tsx:87` | `.phy.lte.mimo_layers` | `phy_metrics.sh:326` `mimo_layers: null` **and** `:307` `lte_rank: null` | devinfo `lte_rank:` (live, 2) — `MIMO_STATUS:` is empty | `mimo_layers: num("lte_rank";1;8)` |
| 4 | MIMO Layers (NR) | `phy-cards.tsx:146` | `.phy.nr.mimo_layers` | `phy_metrics.sh:328` `mimo_layers: null` | devinfo `nr_rank:` (empty only while NR is down) | `mimo_layers: num("nr_rank";1;8)` |
| 5 | UL MCS (LTE) | `phy-cards.tsx:92` | `.phy.lte.ul_mcs` | devinfo `UL_MCS:` **empty**; whole UL grant block empty | **none** — no MCS via QMI/CNWINFO | U1 measurement, then "not reported" row |
| 6 | UL MCS (NR) | `phy-cards.tsx:151` | `.phy.nr.ul_mcs` | `UL_MCS_5G:` empty because NR leg is down; it did read 19 on 2026-10-26 | devinfo `UL_MCS_5G:` | none — already correct |
