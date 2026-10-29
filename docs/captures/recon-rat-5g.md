# Recon — QManager reports 4G while the box is on 5G (NR NSA)

Investigation date: 2026-10-26. Device read-only; no state changed.
Host repos: `zlt-x16` (shim + tests), `greenpacket-o5a-qmanager` (parsers + UI).

---

## 1. Reproduced symptom

The modem is in **EN-DC / NR5G-NSA** right now. Two `AT+CPSI?` samples, 20 s apart,
taken through the deployed shim:

```
$ timeout 10 /data/qmanager/bin/qcmd 'AT+CPSI?'
+CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-133,-898,-579,-9
+CPSI: NR5G_NSA,47,NR5G_BAND41,509070,-770,-110,21,1,9

OK
```
```
+CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-138,-899,-581,0
+CPSI: NR5G_NSA,47,NR5G_BAND41,509070,-770,-110,22,1,9
```

So the NR leg exists: **PCI 47, n41, SSB ARFCN 509070, RSRP −77.0 dBm**, LTE anchor
B1 / PCI 104.

What QManager *sees* for the same seconds — the same command, in the shape the
poller actually issues:

```
$ timeout 10 /data/qmanager/bin/qcmd 'AT+QENG="servingcell"'
+QENG: "servingcell","CONNECT","LTE","FDD",410,01,2E38917,104,250,1,3,3,D857,-88,-6,-132,1

OK
```

One line. The NR leg is gone. `/tmp/qmanager_status.json`:

```json
"network": { "cfun": 1, "type": "LTE", ... },
"lte": { "band": "B1", "pci": 104, ... }
```

`network.type = "LTE"` → the UI renders the 4G tile:
`components/dashboard/network-status.tsx:84-97` → `labelKey: "network.signal_lte"`
(→ "LTE Signal" in `out/locales/en/dashboard.json:22`) with `Md4gMobiledata`, and
`lib/radio-info.ts:88-96` maps `network.type === "LTE"` → `registered-lte`.
No NR card is shown at all (`network-status.tsx:68-83` only takes the 5G branch
on `"5G-NSA"` / `"5G-SA"`).

Host-side proof that the *parser* is fine and the *shim* is the loss point —
feed both shapes through the real `parse_serving_cell`:

```
$ ./harn.sh '+QENG: "servingcell","CONNECT","LTE","FDD",410,01,2E38917,104,250,1,3,3,D857,-89,-6,-133,-9'
network_type=LTE      service_status=connected lte_state=connected nr_state=inactive lte_band=B1 nr_band= nr_rsrp=

$ ./harn.sh '+QENG: "servingcell","CONNECT"
+QENG: "LTE","FDD",410,01,2E38917,104,250,1,3,3,D857,-89,-6,-133,-9
+QENG: "NR5G-NSA",410,01,47,-77,21,-11,509070,41'
network_type=5G-NSA  service_status=connected lte_state=connected nr_state=connected lte_band=B1 nr_band=N41 nr_rsrp=-77
```

---

## 2. Root cause — the shim never synthesises the NR line

`deploy-x16/atcli_smd11` (deployed as `/data/qmanager/bin/atcli_smd11`) translates
Quectel `AT+QENG="servingcell"` into SIMCom `AT+CPSI?`. It reads the CPSI cache —
which contains **both** lines — but scans for and uses only the LTE one:

`deploy-x16/atcli_smd11:323-327`
```sh
    for _l in $_cpsi; do
        case "$_l" in
            '+CPSI: LTE'*) _lte=$(printf '%s' "$_l" | tr -d '\r'); break ;;
        esac
    done
```
and then emits exactly one `+QENG:` line, always tagged `"LTE"`:

`deploy-x16/atcli_smd11:393-397`
```sh
    printf '+QENG: "servingcell","%s","LTE","%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n\nOK\n' \
        "$_qstat" "$_tdd" "${_mcc:-0}" "${_mnc:-0}" \
        "${_hex:-0}" "${_pcid:-0}" "${_earfcn:-0}" "$_bn" \
        "${_ulbw:-0}" "${_dlbw:-0}" "$_tac_hex" \
        "${_rsrp:--}" "${_rsrq:--}" "${_rssi:--}" "${_sinr:--}"
```

`+CPSI: NR5G_NSA,…` is never matched anywhere in `emit_qeng` (the only other
`NR5G` references in the file are the band-number comment at :259/:331 and the
`AT+CNMP`/`AT+CSYSSEL` paths at :553-620 — none of them the serving cell).

The QManager parser then classifies by counting *quoted* RAT tokens in the
response it is handed:

`greenpacket-o5a-qmanager/scripts/usr/lib/qmanager/parse_at.sh:324-330`
```awk
            hn = 0; hs = 0; hl = 0
            for (i = 1; i <= NLINES; i++) {
                if (index(LN[i], "\"NR5G-NSA\"") > 0) hn = hn + 1
                if (index(LN[i], "\"NR5G-SA\"") > 0)  hs = hs + 1
                if (index(LN[i], "\"LTE\"") > 0)      hl = hl + 1
            }
```
`hn = 0` → the EN-DC branch at :331 is skipped, the SA branch at :375 is skipped,
and the LTE-only branch runs:

`parse_at.sh:393-397`
```awk
            } else if (hl > 0) {
                # ===== LTE-ONLY MODE =====
                ...
                ntype = "LTE"
                nrst = "inactive"
```

That value is written straight into the cache and the UI:

- `scripts/usr/bin/qmanager_poller:1678-1693` — `qcmd_exec 'AT+QENG="servingcell"'`
  (the Tier-1 compound is `T1_COMBINED='AT+QENG="servingcell";+QCAINFO=1;+QCAINFO;+QCAINFO=0'`),
  `parse_serving_cell "$result"` at :1737.
- `qmanager_poller:2874` — `network: { … type: $net_type, … }`.
- `qmanager_poller:1929-1934` — `nr_avail` becomes `0` (the AT read *did* answer,
  and carried no NR leg), so the UI also believes "we looked and there is no NR".

Everything downstream is correct; the single wrong fact is "the modem did not
report an NR5G-NSA serving cell", which is false.

**One-line answer:** `+CPSI` returns the 5G leg as a second record
(`+CPSI: NR5G_NSA,<pci>,<band>,<ssb_arfcn>,<rsrp>,<rsrq>,<sinr>,…`) and
`deploy-x16/atcli_smd11:323-327` throws it away because it only matches
`'+CPSI: LTE'*`. Nothing to do with `ENDC` inside the LTE line, `sysmode`, `+QNWINFO`
or `+CREG`: this unit's LTE line carries no ENDC token (`NR5G_NSA` *is* the
sysmode token of the second line), and `AT+QNWINFO` is stubbed to `OK` by the shim
(`atcli_smd11:743`) because SIMCom has no such command.

---

## 3. How the stock UI does it

Stock UI = the vendor `simcom_war` app served by `mini_httpd`:
`/tmp/mini_httpd.conf` → `dir=/tzwww`, `cgipat=cgi-bin/*`, `port=80`
(`/bin/mini_httpd -C /tmp/mini_httpd.conf`, PID verified with `ps w`).

Path:

1. The **vendor dialer** parses both `+CPSI` lines and formats the RAT itself.
   `firmware-analysis/dialer.strings:2080-2088` (strings extracted from this unit's
   `/bin/dialer`):
   ```
   f_network_type_str
   +CPSI: LTE,Online
   USR_TR069_AREA_OPERATOR
   USR_CELL_ID_DISPLAY_SCHEME
   +CPSI: NR5G_NSA
   5G(NSA)
   -3276
   +CPSI: NR5G_SA,Online
   5G(SA)
   +CPSI: WCDMA,Online
   ```
   i.e. `strstr(buf,"+CPSI: NR5G_NSA")` → the display string `5G(NSA)`. The same
   table also carries `freq_5g/pci_5g/rsrp_5g` and the `AT+CNWSEARCH="nr5g"` path.
2. That string is exported to the web layer as **`network_type_str`**
   (`firmware-analysis/dialer.strings:5520` `current_network_type_str`,
   `:5550` `network_type`).
3. The dashboard JS consumes `network_type_str` verbatim:
   `/tzwww/js/dashboard/dashboard.js` (`GET_DASHBOARD_INDEX`, cmd `401`,
   `JSONMethod.GET`, POSTed to `/cgi-bin/http.cgi` — `js/main.js`:
   `GET_DASHBOARD_INDEX:401`, `Url.DEFAULT_CGI:"/cgi-bin/http.cgi"`):
   ```js
   var t = e.network_type_str;
   … vm.currentNet = t;                       // "5G(NSA)"
   vm.signalValue = "" == e.RSRP ? ("" == e.RSRP_5G ? "-" : e.RSRP_5G) : e.RSRP;
   ```
   The stock page therefore has a **separate 5G RSRP field (`RSRP_5G`)** and a
   separate 5G metric family (`PCI_5G`, `FREQ_5G`, `SINR_5G`, `RSRQ_5G`,
   `RSSI_5G`, `CELL_ID_5G`, `ENODEBID_5G`, `CQI_5G` — counted in `/tzwww/js` and
   `/tzwww/html`), i.e. stock treats EN-DC as "LTE anchor + NR leg", exactly what
   QManager's own `parse_at.sh` EN-DC branch expects.
4. `/tzwww/cgi-bin/http.cgi` (ELF, `stat`ically linked, 468 680 B) answered
   `{"success":false,"cmd":-1,"message":"SessionId parameter is missing"}` without a
   session; its `.text` strings are obfuscated (`strings` yields no `network_type_str`,
   `grep -a` finds none), so **which store it reads is UNKNOWN** — resolving it would
   need a logged-in session or the vendor source. It does not matter for the fix:
   the value's origin (`f_network_type_str` → `5G(NSA)`) and its consumer
   (`network_type_str`) are both established.

So stock is right for a mundane reason: the vendor dialer reads the line the shim
deletes.

---

## 4. Fix plan

Contained fix in **one file** — the X16 shim. No QManager source change is needed:
`parse_at.sh`'s EN-DC branch already does the right thing once it is given the
Quectel EN-DC shape (proved in §1).

### 4.1 What to emit

When the CPSI cache contains `+CPSI: NR5G_NSA,…`, emit the **Quectel EN-DC
3-line shape** instead of the single line:

```
+QENG: "servingcell","<state>"
+QENG: "LTE","<FDD|TDD>",<mcc>,<mnc>,<cellid-hex>,<pcid>,<earfcn>,<band>,<ul_bw>,<dl_bw>,<tac-hex>,<rsrp>,<rsrq>,<rssi>,<sinr>
+QENG: "NR5G-NSA",<mcc>,<mnc>,<pcid>,<rsrp>,<sinr>,<rsrq>,<arfcn>,<band>
```
(15 / 9 fields respectively — the parser's `parse_at.sh:331-374` EN-DC branch, and
the header comment there is the contract.)

The LTE line **must drop the leading `"servingcell","<state>"` pair** — in EN-DC
mode the parser selects the LTE row with
`index(LN[i],"\"LTE\"")>0 && index(LN[i],"\"servingcell\"")==0` (`parse_at.sh:335-341`),
so a line that keeps `"servingcell"` is invisible. This is the single easiest
thing to get wrong.

### 4.2 Field mapping for `+CPSI: NR5G_NSA`

Measured on this unit, cross-checked against the per-chain queries in the same
second (`AT+CRSRP?` / `AT+CSINR?`):

| CPSI f | value (sample) | meaning | scale into `+QENG:"NR5G-NSA"` | evidence |
|---|---|---|---|---|
| 1 | 47 | PCID | as-is | PCI range; differs from LTE PCI 104 as expected |
| 2 | `NR5G_BAND41` | band | strip to `41` (reuse the `*BAND*` logic at `atcli_smd11:356-362`) | band 41 ⇔ SSB ARFCN 509070 is inside n41's raster |
| 3 | 509070 | SSB/ARFCN | as-is | inside n41 SSB raster |
| 4 | −770 | RSRP ×10 (−77.0 dBm) | `/10` truncate (same rule as LTE, :364-373) | `+CRSRP: NR5G,-75,-76,-82,-75` same second |
| 5 | −110 | RSRQ ×10 (−11.0 dB) | `/10` round (same rule as LTE RSRQ, :374-378) | no independent per-chain RSRQ on this modem |
| 6 | 21 / 22 | **SINR, whole dB** | **as-is, do NOT divide by 10** | `+CSINR: NR5G,21,19,…` then `22,20,…` in the two same-second pairs |
| 7 | 1 | UNKNOWN (SCS index? ENDC flag?) | do not use | constant across samples |
| 8 | 9 | UNKNOWN | do not use | constant across samples |

Emit only 9 fields (stop after band). `parse_at.sh` then leaves `nr_scs` empty via
`f(11)` returning `""` (`parse_at.sh:239-243` `f()` returns "" for n>NCSV) and
`nr_bw` is already always null on this build (`qmanager_poller:1895-1900`).

> Correction to `docs/raw/scout-04-simcom-at-mapping.md`: its claim that CPSI NR
> "SNR×10" is **wrong on this unit** — two same-second comparisons show field 6 is
> whole dB, matching `+CSINR` exactly. Do not copy that scaling.

### 4.3 Code

In `deploy-x16/atcli_smd11`, `emit_qeng()` (`:311-398`):

1. Extend the scan at `:319-327` to capture both rows in one pass:
   ```sh
   _lte=""; _nr=""
   for _l in $_cpsi; do
       case "$_l" in
           '+CPSI: LTE'*)       _lte=$(printf '%s' "$_l" | tr -d '\r') ;;
           '+CPSI: NR5G_NSA'*)  _nr=$(printf '%s'  "$_l" | tr -d '\r') ;;
       esac
   done
   ```
   (drop the two `break`s; keep `set -f` / `IFS` handling exactly as now)
2. Keep everything up to `:391` unchanged — the LTE fields are needed in both modes.
3. Replace the final `printf` (`:393-397`) with a branch:
   - `[ -z "$_nr" ]` → **the exact current single printf** (byte-for-byte; the
     existing LTE-only tests pin its 17 field positions).
   - else → split `_nr` on `,` after `${_nr#+CPSI: NR5G_NSA,}` (same
     `set --`/`IFS=,` idiom as `:336-346`), scale f4/f5 per the table, derive the
     band number, then print the 3 lines + blank + `OK`:
     ```sh
     printf '+QENG: "servingcell","%s"\n' "$_qstat"
     printf '+QENG: "LTE","%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
         "$_tdd" "${_mcc:-0}" "${_mnc:-0}" "${_hex:-0}" "${_pcid:-0}" \
         "${_earfcn:-0}" "$_bn" "${_ulbw:-0}" "${_dlbw:-0}" "$_tac_hex" \
         "${_rsrp:--}" "${_rsrq:--}" "${_rssi:--}" "${_sinr:--}"
     printf '+QENG: "NR5G-NSA",%s,%s,%s,%s,%s,%s,%s,%s\n\nOK\n' \
         "${_mcc:-0}" "${_mnc:-0}" "$_npcid" "$_nrsrp" "$_nsinr" "$_nrsrq" "$_narfcn" "$_nbn"
     ```
   Empty/unparsable NR fields must degrade to `-` (the parser's "no value" token
   is a non-numeric like `-`; `_sig_val` maps sentinels to JSON null).
4. Update the header comment block (`:304-310`) — it currently documents only the
   LTE-only layout.

Do **not** emit the EN-DC shape when `_nr` is absent: the LTE-only branch of
`parse_at.sh:393` indexes by position *including* the `"servingcell","<state>"`
prefix, and changing that breaks CA/band/signal on LTE-only cells.

### 4.4 Tests to add — `tests/unit_atcli_smd11.sh`

- Fixture with both CPSI rows (verbatim from §1):
  ```
  +CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-133,-898,-579,-9
  +CPSI: NR5G_NSA,47,NR5G_BAND41,509070,-770,-110,21,1,9
  ```
  Assert: 3 `+QENG:` lines; line 1 `"servingcell"`; line 2 first field `"LTE"` and
  second `"FDD"`, `"servingcell"` absent (grep `-c` 0); line 3 first field
  `"NR5G-NSA"`; NR fields `47 / -77 / 21 / -11 / 509070 / 41`.
- Assert LTE-only fixture is unchanged (all 17 positions from `:107-128` stay green).
- Assert the `no LTE → SEARCH sentinel` case is unchanged (`:143-144`).
- Optional but cheap: pipe the shim output through `parse_serving_cell` in a test
  (needs `qlog_*` stubs) and assert `network_type=5G-NSA`, `nr_band=N41`.

### 4.5 Deployment

The shim is a shell script re-read on every `qcmd` call — **no service restart is
needed**, the next poller cycle (~3 s) picks it up. Deploy with the module's own
installer (`deploy-x16/install.sh:152,302-307` copies it to
`/data/qmanager/bin/atcli_smd11` and runs `sh -n` on it). Note the on-device
`qcmd` is already path-fixed to `/data/qmanager/bin/atcli_smd11`
(`qm_pathfix_x16.sh`); `/usr/bin/qcmd` and `/usr/bin/atcli_smd11` do not exist.

---

## 5. How to verify

On the device, after deploying:

```sh
# 1. the translation itself
timeout 10 /data/qmanager/bin/qcmd 'AT+QENG="servingcell"'
```
expected (values vary):
```
+QENG: "servingcell","CONNECT"
+QENG: "LTE","FDD",410,01,2E38917,104,250,1,3,3,D857,-89,-6,-133,-9
+QENG: "NR5G-NSA",410,01,47,-77,21,-11,509070,41

OK
```

```sh
# 2. one poll cycle later — the cache
sleep 5; grep -o '"type": "[A-Z0-9-]*"' /tmp/qmanager_status.json | head -1
```
expected `"type": "5G-NSA"` (was `"LTE"`), and `nr_band` `N41`, `nr_pci` `47`,
`nr_rsrp` ≈ `-77`, `nr_avail` `1`.

```sh
# 3. UI
curl -s http://127.0.0.1:8080/api/...    # or just open the dashboard
```
Dashboard orb shows the 5G glyph + "5G NSA" sublabel
(`network-status.tsx:68-83`); the radio/overview page enters `registered-nsa`
(`lib/radio-info.ts:90`); the NR band/carrier card appears.

Cross-check the numbers once against a per-chain read
(`qcmd 'AT+CRSRP?'` → `+CRSRP: NR5G,-75,-76,-82,-75`) — the NR RSRP on screen must
be within a couple of dB of the strongest chain.

Host-side before deploying:
```sh
sh tests/unit_atcli_smd11.sh          # must stay 100% green, plus the new cases
```

---

## 6. Risks

| Risk | Why / mitigation |
|---|---|
| **Breaking LTE-only cells** | The LTE-only branch indexes with the `"servingcell","state"` prefix. The fix must keep the present single-line printf byte-identical on that path; the existing tests pin all 17 positions. |
| Extra `+QENG:` lines leaking into CA parsing | `parse_ca_info` only reads `^+QCAINFO:` lines (`parse_at.sh:803+`); the added `+QENG:` lines are inert. Verified: the header line contains no quoted `"LTE"`, the NR line none either (`"NR5G-NSA"` ≠ `"LTE"`), so `hl`/`hn` counting is unaffected. |
| SINR/RSRQ scale wrong | RSRP and SINR are cross-checked live against `+CRSRP`/`+CSINR`; RSRQ has **no** independent per-chain source on this modem, so `/10` is inferred from the manual's convention and physical plausibility — if a 5G cell ever reports an RSRQ outside −3…−20 dB, revisit. |
| Wrong `nr_scs` / `nr_bw` | Not emitted; parser fills `""` / null. Honest null over a fabricated number. |
| Field-7/8 meaning unknown (`1,9`) | Unused by the fix. They must not be guessed into the CSV — an extra field would shift `nscs`/`narfcn`. |
| 5G **SA** still shows LTE | If the cell ever attaches SA, the modem emits `+CPSI: NR5G_SA,Online,…` (seen in `dialer.strings:2087-2088`) with a different field order that has **never been captured on this box**. Do not implement blind; capture `AT+CPSI?` while on SA first. NSA-only network today. |
| AT-cost regression | None: `cpsi_raw` already caches the whole `AT+CPSI?` response (both lines, 1 s TTL), so this is pure parsing, zero extra modem round-trips. |
| Don't touch | `/bin/dialer` (vendor RAT source), `atcmd_daemon`, QManager's `parse_at.sh` awk, `+CNMP`/band-lock paths, and the `+QNWINFO` stub. Never send `AT+CRSM`. |

---

## 7. Adjacent findings (out of scope, do not fix in this change)

1. **LTE RSSI is bogus.** CPSI LTE field 11 reports −115…−138 while
   `+CRSSI: LTE,-62,-65,-58,-59` and `+CSQ: 26` (−61 dBm) say otherwise, in the
   same second; `network.rssi` reaches the UI as `-115`. Field 11's meaning on this
   firmware is **UNKNOWN**; resolving it needs a same-second `+CPSI?`/`+CRSSI?`
   sweep across TDD/FDD bands.
2. **LTE SINR is bogus/lagging.** CPSI LTE field 14 read `-9 / 0 / 2 / 11` while
   `+CSINR: LTE` read `8,6,9,9` in the same seconds. Either field 14 is not SINR
   on this firmware, or the modem's CPSI SINR is stale. A verified alternative
   exists (`+CSINR`, already allowlisted and used by `AT+QSINR`) at the cost of one
   extra AT call per cycle.
3. `emit_antenna()` (`atcli_smd11:215-247`, the composite-from-CPSI variant) is
   **dead code** — the dispatcher only routes to `emit_antenna_native` (
   `AT+QRSRP`/`AT+QSINR`) and `emit_antenna_unavailable` (`AT+QRSRQ`). Safe to keep
   as reference, but it is also LTE-only and will mislead the next reader.
4. `docs/raw/scout-04-simcom-at-mapping.md:27` records the NR5G_NSA field list as
   six fields with "SNR×10" — both are wrong for this unit (8 fields observed,
   SNR in whole dB). Worth correcting when §4 lands.

---

## 8. References

| Thing | Location |
|---|---|
| The loss point | `deploy-x16/atcli_smd11:311-398` (`emit_qeng`), scan at `:323-327`, printf at `:393-397` |
| Parser contract | `parse_at.sh:324-341` (counting + EN-DC LTE row selection), `:331-374` (NR fields), `:393-397` (LTE-only) |
| Poller | `qmanager_poller:1678-1693`, `:1737`, `:2874`, `:1929-1934` |
| UI mapping | `components/dashboard/network-status.tsx:68-97`, `lib/radio-info.ts:88-96` |
| Stock RAT source | `firmware-analysis/dialer.strings:2080-2088`, `:5520`, `:5550` |
| Stock consumer | `/tzwww/js/dashboard/dashboard.js`, `/tzwww/js/main.js` (`GET_DASHBOARD_INDEX:401`, `/cgi-bin/http.cgi`), `/tmp/mini_httpd.conf` |
| Live CPSI/QENG captures | §1 of this file; older single-RAT sample in `docs/captures/at-capture-2026-10-26.txt:101-103` |
