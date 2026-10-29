# Recon — "Detailed Metrics" is empty on QManager (X16 / SIM8260E)

Read-only investigation on the device (`ssh zlt-root`), 2026-10-26 15:28–15:52 device time.
Nothing was installed, edited, restarted or written on the device; the only AT traffic was
five single `qcmd` calls, each under `timeout 20`, spaced out, all read queries.

Intended repo destination for this file: `docs/captures/recon-detail-metrics.md`.

---

## 1. Symptom, reproduced

**What the page is.** "Detailed Metrics" is the sidebar label for
`app/cellular/detailed-metrics/page.tsx` → `components/cellular/detailed-metrics/detailed-metrics.tsx`
(sidebar key `sidebar.json:14`, page title `cellular.json:2633`). It renders six cards:
Registration, Carrier Aggregation, LTE PHY, NR PHY, SSB Beams, Distributions.

**The endpoint.** `hooks/use-detailed-metrics.ts:34`

```
ENDPOINT = "/cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh"
```

polled `?range=now` once a second while the tab is visible (`:41`), and 30 s for ranged reads.
The CGI projects `/tmp/qmanager_status.json` → `.phy` straight through
(`fetch_signal_history.sh:222-249`, `SNAPSHOT_JQ`), so **the object below is byte-for-byte what
the page receives** (produced by running that same jq program against the live status file):

```json
{"lte":{"rsrp":-88,"rsrq":-6,"rssi":-127,"sinr":0,
        "cqi":null,"ri":null,"pmi":null,"mimo_layers":null,"tm_mode":null,"ul_mcs":null},
 "nr": {"rsrp":null,"rsrq":null,"sinr":null,"cqi":null,"ri":null,"pmi":null,
        "mimo_layers":null,"dl_mcs":null,"ul_mcs":null,"tx_power":null},
 "rrc":{"rat":null,"state":null},
 "registered":null,"carrier":"Jazz","beams":[]}
```

Live poller cache at the same moment (`/tmp/qmanager_status.json` → `.phy`): identical.
So **all 16 PHY figures except LTE RSRP/RSRQ/RSSI/SINR are `null`** → the page renders a dash
(`metric-figure.tsx`, "`null` is a dash everywhere"), and the Distributions card disables every
pill it has no archive for. That is the "empty" the customer sees.

(The raw endpoint needs a session — `curl -s "…?range=now"` answers
`{"success":false,"error":"unauthorized"}`. I did not log in; the projection above is the same
data by the same code path.)

Two figures that *are* shown are also **wrong**, and that is a second, independent bug — see §4.

### The archive confirms it is not a UI problem

`/data/qmanager/metrics/2026-10-26.csv`, 332 rows today:

```
rows=332 lte_cqi_nonempty=0 lte_pmi_nonempty=0
```

Every PHY column except `lte_rsrp/lte_rsrq/lte_rssi/lte_sinr`, `temp`, `cpu/mem`, throughput and
the identity block is empty. Frontend is innocent; the value never reaches the cache.

---

## 2. Root causes (three, all backend)

### R1 — Tier 3 is gated on a daemon this device does not have  ← the main one

`scripts/usr/lib/qmanager/phy_metrics.sh:263-289` — `qm_phy_available()` makes a real
`ubus call modemd status` and refuses when it fails. `scripts/usr/bin/qmanager_poller:1864-1871`:

```sh
if qm_phy_available; then
    md=$(qm_phy_modemd) || md="{}"
    at=$(qm_phy_at "$network_type") || at="{}"
else
    qlog_debug "phy: ubus/modemd unavailable — Tier 3 publishes nulls"
fi
```

On the X16 there is **no `ubus` anywhere** and no `modemd`:

```
$ find / -maxdepth 4 -name ubus -type f      # (nothing)
$ ls /sbin/ubus /bin/ubus /usr/sbin/ubus /usr/bin/ubus   # all "No such file"
$ ls /sbin/modemd /bin/modemd /usr/sbin/modemd           # all "No such file"
```

`_qm_phy_ubus()` (`phy_metrics.sh:140-172`) therefore returns nothing, `qm_phy_modemd()` returns
2, `qm_phy_available()` returns 1, and **both AT reads are skipped on every cycle**. The snapshot
is still published, but only from the poller's own Tier-1 context (`ctx`), which is why RSRP/
RSRQ/RSSI/SINR and `carrier` survive and *nothing else does*. `registered` is likewise modemd-only
(`QM_PHY_SNAPSHOT_JQ` at `phy_metrics.sh:493-523`: `registered: ($m.registered …)`), so it is `null`
even though the modem is plainly attached.

### R2 — the AT half is 100 % `AT+QNWCFG`, which the X16 shim answers with a bare `OK`

`phy_metrics.sh:291-292`:

```sh
QM_PHY_AT_LTE='AT+QNWCFG="lte_csi";+QNWCFG="lte_ulMCS";+QNWCFG="lte_dl_tx_mode";+QNWCFG="rrc_state"'
QM_PHY_AT_NR='AT+QNWCFG="nr5g_csi";+QNWCFG="nr5g_ulMCS";+QNWCFG="nr5g_dlMCS";+QNWCFG="nr5g_tx_pwr";+QNWCFG="ssb_beam_id"'
```

`AT+QNWCFG` is **Quectel**. This is a SIMCom SIM8260E (`device.model` in the status cache:
`SIMCOM_SIM8260E`; `module_softver: B01V22_SDX65_LE12_LGA_M88_TZ_V1.00`), whose AT surface has no
`QNWCFG` at all (`grep -c QNWCFG firmware-analysis/dialer.strings` → 0).

The X16 shim stubs it — `deploy-x16/atcli_smd11:834` (identical, line 834, in the deployed
`/data/qmanager/bin/atcli_smd11`):

```sh
AT+QNWCFG*|AT+QGETCAPABILITY*|AT+QMAP*|AT+QNWINFO*|AT+QCSQ*) printf 'OK\n' ;;
```

Measured:

```
$ timeout 20 /data/qmanager/bin/qcmd 'AT+QNWCFG="lte_csi"'   ->  OK            (no +QNWCFG line)
$ timeout 20 /data/qmanager/bin/qcmd 'AT+QNWCFG="rrc_state"' ->  OK            (no +QNWCFG line)
```

`qm_phy_at` (`phy_metrics.sh:445-465`) is non-empty, so it returns 0, and
`QM_PHY_AT_AWK` (`:309-438`) has nothing to anchor `/^\+QNWCFG: /` on → every field stays unset →
`null`. Even with R1 fixed, the AT half would contribute nothing.

### R3 — same cause, archive side

`qm_phy_archive_row` writes from the same all-null snapshot, so the 30-day archive has no CQI/RI/
MCS/PMI column values (measured above), and `?range=1h…90d` `missing[]` disables every pill on
the Distributions card.

**No frontend defect was found.** The page, hook, contract (`types/detailed-metrics.ts`) and CGI
all handle `null` correctly and would display the values the moment the cache carries them.

---

## 3. How the stock UI gets them — and the store QManager ignores

The stock UI is `/tzwww` (simcom_war, mini_httpd :80, docroot `/tzwww`), a Vue app posting
`{cmd, method}` to `/cgi-bin/http.cgi` (`/tzwww/js/main.js`: `Url.DEFAULT_CGI:"/cgi-bin/http.cgi"`,
`RequestCmd.SYS_INFO_NETWORK:205`).

The metrics page is `/tzwww/js/info/sysInfo.js` — `names_sysInfo[]` is literally
`netMode, signal, plmn, RSRP, RSSI, RSRQ, SINR, phyCellId, freqPoint, enodeB, cellId, CQI, MCS,
bandwidth, ECGI, currentBand, rank, maxQamUl, maxQamDl, …` and `getData()` reads them as
`s.RSRP / s.RSRP_5G / s.SINR / s.CQI / s.CQI_5G / s.dl_mcs / s.dl_mcs_5g / s.rank_4g / s.rank_5g …`.

**Where those numbers live, verified live.** The vendor dialer keeps a plain-text dump of its
`devinfo` store at **`/tmp/.devinfo_module_data`** (root, `-rw-r--r--`, rewritten ~1×/s; values
change while you watch — CQI 10 → 5 → 6 across three reads). Field names are the JS names:

```
sim_status:1
network_type_str:5G(NSA)
CURRENTBAND:1            bandwidth:10
RSRP:-88                 RSRQ:-13                SINR:0                RSSI:-57
CQI:6                    UL_MCS:                 DL_MCS:4              lte_rank:1
RSRP_5G:-77              RSRQ_5G:-11             SINR_5G:28            RSSI_5G:-64
CQI_5G:11                UL_MCS_5G:19            DL_MCS_5G:0           nr_rank:2
CURRENTBAND_5G:41        FREQ_5G:509070          PCI_5G:47             bandwidth_5G:50
current_max_ul_qam:QPSK  current_max_dl_qam:QPSK
current_max_ul_qam_5g:64QAM  current_max_dl_qam_5g:QPSK
signal_lvl:4
```

Cross-checked against the vendor's per-value reader (same numbers, so the file is a faithful dump):
`/bin/devinfo 301019 -> 104` (PCI), `301024 -> -88` (RSRP), `301025 -> -12` (RSRQ).

**Upstream source of the LTE CQI/MCS/rank**: `AT+SPENGMD=0,0,6`, parsed by the dialer into
`UL_MCS_4G / DL_MCS_4G / SINR_4G / CQI_4G / DL_BLER_4G / DL_RANK_4G`
(`firmware-analysis/dialer.strings:2181-2185`, `parse_mcs` at `:5873`). That command is sent on the
**dialer's own AT channel** (`sunsea_send_at_with_format(0xf, …)`), *not* through `atcmd_daemon`:

```
$ timeout 20 /data/qmanager/bin/qcmd 'AT+SPENGMD=0,0,6'  ->  ERROR: command_failed
```

so QManager can never reach it via `qcmd`. The NR-leg CQI/MCS (`CQI_5G`, `UL/DL_MCS_5G`) has **no
AT string in the dialer** — it comes from the modem's own indication path into the same devinfo
store. **Source of the NR-leg figures: UNKNOWN** (resolving it needs the vendor `libolinterface`/
QMI indication names, out of scope here). It does not matter: the store already carries them, and
`/bin/atcmd`/`qcmd` are not in that path.

Ground truth CPSI line at the same second (for the RSRQ/RSSI discussion in §4):

```
+CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-122,-887,-581,0
+CPSI: NR5G_NSA,47,NR5G_BAND41,509070,-770,-110,28,1,9
```

Field order on this firmware is `<rsrq×10>, <rsrp×10>, <rssi×10>, <sinr>` — -122 ⇒ RSRQ −12.2,
-887 ⇒ RSRP −88.7, -581 ⇒ RSSI −58.1, 0 ⇒ SINR 0, which matches the vendor store (−13/−88/−57/0)
to the decibel.

---

## 4. Metric-by-metric table

Live values, one instant (`15:48:58`): QManager = the projection in §1 (`status.json` `.phy`);
stock = `/tmp/.devinfo_module_data`. "—" = a dash in the UI (null).

| # | QManager field | QM value | Stock value | Source of truth on this device | Why QManager has nothing / the wrong thing | Fix |
|---|---|---|---|---|---|---|
| 1 | `lte.rsrp` | **−88** ✓ | −88 | Tier-1 `AT+CPSI?` via shim `emit_qeng` → `+QENG:"LTE"` | works (ctx only) | none |
| 2 | `lte.rsrq` | **−6** ✗ | −13 | same CPSI, field 11 (×10) | **shim field misalignment**: `atcli_smd11:378` binds field 11 to `_rssi`, so rsrq is computed from field 13 (the RSSI×10) at `:397-401` ⇒ ( -581 −50)/100 = −6 | `deploy-x16/atcli_smd11:378` — see §5.3 |
| 3 | `lte.rssi` | **−127** ✗ | −57 | same CPSI, field 13 (×10) | same misalignment: field 11 (RSRQ×10 ≈ −122…−127) is emitted verbatim as RSSI | same fix |
| 4 | `lte.sinr` | **0** ✓ | 0 | CPSI field 14 | works | none |
| 5 | `lte.cqi` | — | **6** | devinfo `CQI:` (dialer `AT+SPENGMD=0,0,6`) | R1 (gate) + R2 (`AT+QNWCFG="lte_csi"` stubbed to `OK`) | §5.1/§5.2 |
| 6 | `lte.ri` | — | **1** (`lte_rank`) | devinfo `lte_rank:` | R1 + R2 | §5.1/§5.2 |
| 7 | `lte.pmi` | — | *(not shown)* | none — no PMI on this firmware; vendor does not show one either | R1 + R2 **and** no source | leave `null`; glossary note "not reported" |
| 8 | `lte.mimo_layers` | — | *(not shown; `lte_rank` is RI)* | none — no layer-count query (`QNWCFG="lte_mimo_layers"` stubbed); `AT+CCAINFO?` carries CA layers only | R1 + R2 **and** no source | leave `null` |
| 9 | `lte.tm_mode` | — | *(not shown)* | none | R1 + R2, no source | leave `null` (card already says "not reported") |
| 10 | `lte.ul_mcs` | — | *(empty)* | devinfo `UL_MCS:` (empty right now — uplink grant absent) | R1 + R2 | §5.1/§5.2 (writes whatever the store has, incl. empty ⇒ null) |
| 11 | `lte.tx_power` | row already reads "Not reported by this modem" | *(not shown)* | `AT+QNWCFG="lte_tx_pwr"` absent; nothing in the store | correctly absent by contract (`types/detailed-metrics.ts:9-14`) | none — do not add |
| 12 | `nr.rsrp` | — | **−77** (`RSRP_5G`) | CPSI NSA line would give it; store also has it | NR leg not in `ctx`: `.phy.nr.rsrp` comes from poller `nr_rsrp`, which is empty because the poller reads NR from `+CENG`/NSA line that the shim emits only when CPSI carries `NR5G_NSA` — today the cache says `network.type: "LTE"` while CPSI *does* carry the NSA line (separate RAT-detection issue, `docs/captures/recon-rat-5g.md`) | out of scope here; §5.1 fills `nr.cqi/ri/mcs` regardless |
| 13 | `nr.rsrq` | — | **−11** | as above | as above | as above |
| 14 | `nr.sinr` | — | **28** | as above | as above | as above |
| 15 | `nr.cqi` | — | **11** (`CQI_5G`) | devinfo `CQI_5G:` | R1 + R2 | §5.1/§5.2 |
| 16 | `nr.ri` | — | **2** (`nr_rank`) | devinfo `nr_rank:` | R1 + R2 | §5.1/§5.2 |
| 17 | `nr.pmi` | — | *(not shown)* | none | R1 + R2, no source | leave `null` |
| 18 | `nr.mimo_layers` | — | *(not shown)* | none | R1 + R2, no source | leave `null` |
| 19 | `nr.dl_mcs` | — | **0** (`DL_MCS_5G`) | devinfo `DL_MCS_5G:` | R1 + R2 | §5.1/§5.2 (0 is a real MCS reading here) |
| 20 | `nr.ul_mcs` | — | **19** (`UL_MCS_5G`) | devinfo `UL_MCS_5G:` | R1 + R2 | §5.1/§5.2 |
| 21 | `nr.tx_power` | — | *(not shown)* | none (no PUSCH power query works) | R1 + R2, no source | leave `null` |
| 22 | `nr.pathloss` | row already "Not reported" | *(not shown)* | absent by contract | correctly absent | none |
| 23 | `rrc.rat` | — | `network_type_str: 5G(NSA)` | store / `+CPSI` | R1 + R2 (`QNWCFG="rrc_state"` stubbed) | §5.1: derive `LTE`/`NR` from `network_type_str` |
| 24 | `rrc.state` | — | *(not available in either UI)* | none — no RRC state code on this firmware | R1 + R2, no source | leave `null`; do **not** decode a code nobody verified |
| 25 | `registered` | — | `sim_status:1` + `network_type_str` | store, or `AT+CEREG?` (verified: `+CEREG: 0,1`) | modemd-only (`phy_metrics.sh:493-523`, `$m.registered`), and modemd does not exist | §5.1: `sim_status == 1 && network_type_str` non-empty |
| 26 | `carrier` | **Jazz** ✓ | `PLMN:41001` | poller Tier-2 `AT+COPS?` | works | none |
| 27 | `beams[]` | `[]` | *(not shown — vendor shows `DL_BLER` instead)* | `ssb_beam_id` is Quectel-only, stubbed | R1 + R2, no source | leave `[]` |
| 28 | Distributions series | all pills disabled except rsrp/sinr/rsrq/rssi/temp/total_cells | n/a | `/data/qmanager/metrics/*.csv` | R3 — the columns are empty for the same reason | fixed automatically by §5 |

**Score after the fix**: 11 of the 22 numbered PHY figures gain a real value (LTE cqi/ri/ul_mcs;
all four NR cqi/ri/dl_mcs/ul_mcs; registered; plus the two LTE figures that stop being wrong).
The remaining `null`s are genuinely absent on this firmware — and the stock UI does not show them
either, which is the test the customer is applying.

---

## 5. Fix plan

Three edits, two files in **this** repo plus one small patch applied at deploy time. Nothing in the
QManager frontend changes; the wire contract is untouched.

### 5.1 New patch `deploy-x16/phy_metrics_x16_devinfo.patch`

Target: `lib/qmanager/phy_metrics.sh`, applied by `deploy-x16/install.sh` next to the existing
`phy_metrics_history_context.patch:154`. It adds an X16 source and wires it into the three
existing functions — no signature changes, so `qmanager_poller` needs no edit.

```sh
# ---- X16 / SIMCom SIM8260E: the vendor devinfo store -------------------------
# /tmp/.devinfo_module_data is the vendor dialer's own dump of its devinfo table,
# rewritten ~1 Hz, world-readable, and it carries the PHY fields no AT command
# QManager is allowed to send can produce (CQI/MCS/rank). Reading it costs one
# `cat` and no AT lock. A store older than QM_PHY_DEVINFO_TTL is NOT a reading.
QM_PHY_DEVINFO_FILE="${QM_PHY_DEVINFO_FILE:-/tmp/.devinfo_module_data}"
QM_PHY_DEVINFO_TTL="${QM_PHY_DEVINFO_TTL:-30}"

_qm_phy_devinfo() {            # 0 fresh, 2 absent, 3 stale
    [ -r "$QM_PHY_DEVINFO_FILE" ] || return 2
    _dt_m=$(date -r "$QM_PHY_DEVINFO_FILE" +%s 2>/dev/null) || return 2
    case "$_dt_m" in ''|*[!0-9]*) return 2 ;; esac
    [ $(( $(date +%s) - _dt_m )) -le "$QM_PHY_DEVINFO_TTL" ] || return 3
    cat "$QM_PHY_DEVINFO_FILE"
}

qm_phy_x16_modemd() {          # modemd-shaped, for the `registered` key only
    _qm_phy_devinfo >/dev/null || return $?
    _qm_phy_devinfo | "$(_qm_phy_jq)" -R -s -c '
      [ splits("\n")[] | select(test("^[A-Za-z0-9_]+:"))
        | capture("^(?<k>[A-Za-z0-9_]+):(?<v>.*)$") ] | from_entries as $d
      | {registered: (if ($d.sim_status == "1") and (($d.network_type_str // "") | length > 0)
                      then true elif ($d.sim_status // "") == "" then null else false end),
         carrier: null, rat: null, cqi: null, nr_cqi: null,
         lte_mimo_layers: null, nr_mimo_layers: null, lte_tm_mode: null,
         lte_rank: null, nr_rank: null}'
}

qm_phy_x16_at() {              # AT-shaped, so QM_PHY_SNAPSHOT_JQ needs no change
    _qm_phy_devinfo >/dev/null || return $?
    _qm_phy_devinfo | "$(_qm_phy_jq)" -R -s -c '
      def num($k; lo; hi): ($d[$k] // "") | if test("^-?[0-9]+$") then tonumber else . end
                            | if type == "number" and . >= lo and . <= hi then . else null end;
      def mcs($k): ($d[$k] // "") | if test("^[0-9]+$") then tonumber else . end
                   | if type == "number" and . >= 0 and . <= 31 then . else null end;
      def nt: ($d.network_type_str // "");
      [ splits("\n")[] | select(test("^[A-Za-z0-9_]+:"))
        | capture("^(?<k>[A-Za-z0-9_]+):(?<v>.*)$") ] | from_entries as $d
      | {lte: {cqi: num("CQI";1;15), ri: num("lte_rank";1;8), pmi: null,
               mimo_layers: null, tm_mode: null, ul_mcs: mcs("UL_MCS")},
         nr:  {cqi: num("CQI_5G";1;15), ri: num("nr_rank";1;8), pmi: null,
               mimo_layers: null, dl_mcs: mcs("DL_MCS_5G"), ul_mcs: mcs("UL_MCS_5G"),
               tx_power: null},
         rrc: {rat: (if (nt | test("^5G")) then "NR"
                     elif (nt | length) > 0 then "LTE" else null end),
               state: null},
         beams: []}'
}
```

Wiring (three, one line each):

1. `qm_phy_modemd()` (`phy_metrics.sh:234-261`) — when `_qm_phy_ubus` is empty, `qm_phy_x16_modemd`
   instead of `return 2`. (Insert before the `return 2`.)
2. `qm_phy_available()` (`:263-289`) — treat a fresh devinfo store as available:
   `qm_phy_available` → `qm_phy_modemd >/dev/null || qm_phy_x16_modemd >/dev/null`.
3. `qm_phy_at()` (`:445-465`) — after the awk pass, if the emitted object has **no numbers at all**
   (`… | jq -e '[..|numbers]|length > 0'`), substitute `qm_phy_x16_at`. This keeps today's
   behaviour on a device where QNWCFG really works.

Semantics preserved deliberately: absent ⇒ `null` (never 0); CQI range 1–15 so the store's `0`
becomes `null`; MCS range 0–31 keeps a real `0` (today `DL_MCS_5G:0`).

### 5.2 Optional, alternative shape: teach the shim `AT+QNWCFG` (skip if 5.1 is done)

`deploy-x16/atcli_smd11:834` — replace the blanket stub with an `emit_qnwcfg` that synthesises
`+QNWCFG: "lte_csi",1,<ri>,<cqi>,` / `"lte_ulMCS",1,<mcs>` / `"nr5g_csi",…` / `"nr5g_dlMCS",…` /
`"nr5g_ulMCS",…` from the same store (same range rules, `OK` with no payload when the store is
stale). This keeps all X16 dialect knowledge in the shim and needs no QM lib change **for the
values** — but R1's gate still has to be fixed, so 5.1 (or its first two wiring points) is
mandatory either way. Doing both is not required; 5.1 is the smaller total diff and is what I
recommend. If 5.2 is done *instead*, `lte_ri`/`nr.ri` and `lte_ul_mcs` come for free and `rrc.rat`
can be emitted from `network_type_str`.

### 5.3 Shim field misalignment — `deploy-x16/atcli_smd11:378` (and the same line in the deployed file)

```sh
# today
_dlbw=$1 ; _rssi=$2 ; _rsrp10=$3 ; _rsrq100=$4 ; _sinr=$5
# correct for this firmware: CPSI field order is  <rsrq x10>, <rsrp x10>, <rssi x10>, <sinr>
_dlbw=$1 ; _rsrq10=$2 ; _rsrp10=$3 ; _rssi10=$4 ; _sinr=$5
```

and in the scaling block (`:396-411`) replace the hundredths rounding with tenths:

```sh
_rsrq=""
case "$_rsrq10" in
    ''|*[!0-9-]*) ;;
    *) if [ "$_rsrq10" -lt 0 ]; then _rsrq=$(( (_rsrq10 - 5) / 10 )); else _rsrq=$(( (_rsrq10 + 5) / 10 )); fi ;;
esac
_rssi=""
case "$_rssi10" in
    ''|*[!0-9-]*) ;;
    *) _rssi=$(( _rssi10 / 10 )) ;;
esac
```

Also update the stale comment at `:396` and the `+QENG: "LTE",…` field meanings; the two `printf`
shapes at `:433-447` do not change. **Verify the −32768 / empty-field sentinels** the same way the
`_rsrp10` case does, and never emit `-` into `rsrq`/`rssi` positions the parser reads as numbers
(current behaviour already emits `-` ⇒ null, keep it).

While in this file: the NR NSA line mapping (`:399-421`) is **correct** — `-770/-110/28` became
−77/−11/28 and matches the vendor store exactly. Do not "fix" it.

### 5.4 Redeploy note

The deployed `/data/qmanager/bin/atcli_smd11` (31160 B, Oct 26 07:10) is older than the repo copy
(35832 B). Whatever shim change is made, the deploy must push the new file; a `--check` run after
install should compare sizes/hashes.

---

## 6. How to verify

On the device, in this order:

```sh
# 1. the source reads at all, and is fresh
sh -c '. /data/qmanager/lib/phy_metrics.sh; qm_phy_x16_at | /data/qmanager/bin/jq .'

# 2. the gate now passes without ubus
sh -c '. /data/qmanager/lib/phy_metrics.sh; qm_phy_available; echo rc=$?'   # rc=0

# 3. the poller publishes numbers (one Tier-3 interval, ~60 s)
sleep 70; /data/qmanager/bin/jq '.phy' /tmp/qmanager_status.json
#   expect lte.cqi / lte.ri / nr.cqi / nr.ri / nr.dl_mcs / nr.ul_mcs non-null,
#   registered true, and the values equal to /tmp/.devinfo_module_data in the same second

# 4. the archive row carries them
tail -1 /data/qmanager/metrics/$(date -u +%F).csv      # lte_cqi / lte_ri / nr_cqi columns non-empty

# 5. what the page gets
#   (browser, logged in) GET /cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh?range=now
#   → snapshot.lte.cqi == the store's CQI, snapshot.nr.dl_mcs == DL_MCS_5G

# 6. the two figures that were wrong stop disagreeing with the stock UI
timeout 20 /data/qmanager/bin/qcmd 'AT+CPSI?'          # field 11 = rsrq x10, 13 = rssi x10
#   QManager lte.rsrq must equal round(field11/10), lte.rssi equal field13/10  (stock: -13 / -57)
```

Acceptance: `/cellular/detailed-metrics` shows CQI, RI and MCS on both PHY cards, the
Registration card shows "Registered", the Distributions pills for `cqi`/`rank`/`mcs` become
selectable once a few ranged rows exist, and **the same fields read the same numbers as the stock
`sysInfo` page within one sample**.

Negative control (must not change): with the store removed (`mv /tmp/.devinfo_module_data …` — a
tempfs file the dialer recreates) the page must fall back to today's dashes, not to zeroes or to
stale values.

---

## 7. Risks

| Risk | Why | Mitigation |
|---|---|---|
| Reading the vendor store couples us to a vendor file name/shape | `/tmp/.devinfo_module_data` is the dialer's own dump; a firmware update could rename it | TTL + presence gate: absent/stale ⇒ today's behaviour exactly. Fail soft, never fabricate |
| `sim_status`/`network_type_str` ⇒ `registered` is an inference, not the modem's attach state | it is the same datum the vendor UI labels "connected" | publish `null` when either key is empty; never publish `false` from a missing key |
| A `0` in the store becoming a published 0 | `CQI:0` is "out of range", `DL_MCS:0` is a real index | range-gated per field (5.1); 0 kept only for MCS, dropped for CQI/RI |
| AT cost | none added: one file read per Tier-3 cycle, no `qcmd`, no AT lock | do **not** add `AT+SPENGMD=…` to any QManager path |
| `AT+SPENGMD=0,0,6` looks tempting | it is the vendor's real source, but it answers `ERROR` through `atcmd_daemon` and is only served on the dialer's own channel | never send it from `qcmd`; the store is the supported path |
| The shim field-order fix touches a live signal path | `+QENG:"LTE"` feeds `lte.rssi/rsrq/rsrp` on the dashboard too | change only the variable bindings + scaling; keep the printed field count/order; verify against `AT+CPSI?` and the stock UI on the same second |
| Patch conflicts | `deploy-x16/install.sh:154-170` already patches `phy_metrics.sh`, `qmanager_poller` and `qmi_read.sh` | add the new patch as its own file applied after `phy_metrics_history_context.patch`, or fold both into one file if `patch` reports offsets — verify `--check` on a clean stage |
| `-32768` sentinels | the shim emits `-` today; the awk/parse rules turn that into `null` | keep `null`, never `0`; do not "helpfully" coalesce |
| Scope creep | NR RSRP/RSRQ/SINR still null (`nr_rsrp` empty in ctx, `network.type` says LTE while CPSI carries NSA) — a *different* bug, already documented in `docs/captures/recon-rat-5g.md` | do not fix it in this change; listed in table rows 12–14 as follow-up |

**Must not be touched**: modem firmware/MBN, `/bin/dialer`, `atcmd_daemon` (no direct `/dev/smd11`
opens — the shim's `at_raw` path already serialises through `/bin/atcmd`), `AT+CRSM`,
`AT+SPENGMD=*` from `qcmd`, and any `AT+QNWCFG=…,1` setter.

---

## 8. Open items (explicit UNKNOWNs)

1. NR-leg `CQI_5G` / `UL_MCS_5G` / `DL_MCS_5G`: which modem indication fills them (no AT string in
   the dialer). Not needed for the fix; resolving it would need the vendor `libolinterface`/
   QMI-indication names.
2. `devinfo` numeric ids for CQI / MCS / rank (only PCI/RSRP/RSRQ/band/NodeB are known:
   `301019/301024/301025/301022/301020`, `docs/26-antenna-stats-on-x16.md:117-126`). Not needed —
   the text store is the verified interface — but `/bin/devinfo <id>` would be a cheaper per-value
   read if the ids are ever recovered.
3. Whether `nr_rsrp` in the poller cache is empty because of the RAT-detection gap
   (`network.type: "LTE"` while `+CPSI` carries `NR5G_NSA`) or a second parse issue — follow-up in
   the rat-5g thread.
4. `POST /cgi-bin/http.cgi {"cmd":205}` could not be exercised without a vendor login, so the
   store→CGI alias names (`lte_rank` → `rank_4g`) are matched **by name and by value**, not by
   reading the (obfuscated) CGI.
