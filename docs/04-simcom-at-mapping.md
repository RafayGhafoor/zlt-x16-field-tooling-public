# 04 — SIMCom SIM8260E AT mapping

Full report with response formats: [raw/scout-04-simcom-at-mapping.md](raw/scout-04-simcom-at-mapping.md).
Sources: `SIM8200_Series_AT_Command_Manual_V1.01.pdf` (451 pp) + command strings found in
**this unit's** shipped binaries (`firmware-analysis/*.strings`).

Evidence tiers: **DEVICE** = string present in this unit's binaries · **MANUAL** = documented
but not used by the vendor dialer (needs one live check) · **ABSENT** = neither.

## Good news first

3GPP-standard commands **survive unchanged**: `CEREG`, `CGREG`, `C5GREG`, `COPS`, `CSQ`,
`CESQ`, `CPIN`, `CIMI`, `CNUM`, `CGSN`, `CGDCONT`, `CGCONTRDP`, `CGACT`, `CGAUTH`, `CGPADDR`,
`CMGF`, `CMGS`, `CPMS`, `CMGL`, `CMGD`, `CRSM`, `CFUN`.

**No `AT$` proprietary commands exist on this platform** — the real vendor surface is
`+CPSI +CNWINFO +CCAINFO +CSYSSEL +CCELLCFG +C5GCELLCFG +CMCFG +CNVR +CNV +SPENGMD
+SPNCELLSCAN +SIMEI +SPIC +CICCID`.

## The mapping table (QManager need → SIMCom)

| Need | Quectel | SIMCom | Notes / caveats |
|---|---|---|---|
| Registration | `+CEREG`, `+C5GREG` | same | TAC/CI come **quoted hex**; `C5GREG` appends `<octet_len>,<nssai>`; AcT adds 10–13 |
| **Serving cell, band, RSRP/RSRQ/SINR** | `+QENG="servingcell"` | **`+CPSI?`** | **CSV per RAT**, not key=value. Values ×10 (`-850` = −85.0 dBm). NR leg is a separate line. Manual's NR5G_SA example has a missing comma — parse defensively |
| RSSI | `+CSQ` | same | extended 100–199 range breaks naive 0–31 parsers |
| RSRP/RSRQ (dB×10) | — | `+CESQ` (**DEVICE**, undocumented) | verify once live |
| SINR | `+QENG`/`+QSINR` | from `+CPSI` (`RSSNR` LTE 0–30, NR SNR ÷10) | no standalone command |
| MCS/CQI/mod/tx power | `+QENG` | `+CNWINFO` (**DEVICE**) | different field order |
| Operator | `+COPS`, `+QSPN` | `+COPS` (`=3,2` for numeric), `+COPN`, `+CPOL` | `+QSPN` → parse `+COPS` name field |
| IMEI | `+CGSN`, `+EGMR` | `+CGSN`, **`+SIMEI?`** (write `+SIMEI=`) | never expose the write path |
| ICCID | `+QCCID` | **`+CICCID`** → `+ICCID: …` | rename only |
| APN | `+QICSGP` | **`+CGDCONT` + `+CGAUTH`** | two commands instead of one; long optional tail |
| PDP up/down | `+QIACT`/`+QIDEACT` | **`+CGACT=<0|1>[,<cid>]`** | cid range 1–42 |
| DNS / gateway | `+CGCONTRDP` | `+CGCONTRDP` (**DEVICE**, undocumented) | **primary CID is 6 on this unit**, fallback 1 — do not hardcode 1 |
| PDP URCs | `+QIURC` | `+CGEV` via `+CGEREP` | different text |
| Band list / lock | `+QNWPREFCFG="lte_band",<bitmask>` | **`+CSYSSEL="lte_band",1:3:…`** | colon-separated band numbers, not a bitmask; keys `lte_band`, `nr5g_band`, `nsa_nr5g_band`, `w_band`, `nr5g_disable` |
| Cell lock | `+QNWLOCK="common/4g"` | `+CCELLCFG=1,<pci>,<EARFCN>` / `+CCELLCFG=0` | X16 factory UI labels `<freq>` as EARFCN; QManager maps one LTE cell. LTE write not exercised live. C5GCELLCFG remains unverified; see [23](23-cell-locking-on-sim8260e.md) |
| RAT preference | `+QNWPREFCFG="mode_pref"` | **`+CNMP=<n>`** | numeric enum (2 auto, 38 LTE only, 109 NR only…) |
| CA info | `+QCAINFO` | `+CCAINFO?` (**DEVICE**, undocumented) | layout unknown until captured; no CA command in the manual at all |
| Neighbour cells | `+QENG="neighbourcell"` | **native `+QENG="neighbourcell"`** | Verified live on this X16: SIM8260E returns LTE intra/inter rows; do not translate it through the serving-cell shim |
| MBN | `+QMBNCFG` (rejected here!) | **`+CMCFG="list"/"autoselect"/"deactive"`** | real MBN selection needs PDC over QMI (`qmicli`) |
| NV | `+QCFG`/`+QNVR` | `+CNV=<efs path>`, `+CNVR=<index>` | narrow scope, keep out of passthrough |
| Reboot / poweroff | `+CFUN=1,1` / `+QPOWD` | `+CRESET` / `+CPOF` | `OK` arrives before the port drops |
| Factory reset | `+QPRTPARA=3` | **`AT&F` only resets AT settings** | real reset is the router app's job |
| SMS | `CMGF/CMGS/CPMS` | same | `"SM","ME","MT"` only |
| Flight mode | `+CFUN=0/4` | `+CFUN=0/1/4` (+5/6/7 vendor) | **use 4, never 7** (`CFUN=7` needs `CFUN=6` or a reboot to recover) |

## Confirmed present on this unit (DEVICE evidence)

`+CPSI +CESQ +CSQ +CEREG +C5GREG +CNWINFO +CCAINFO +CCELLCFG +C5GCELLCFG +CSYSSEL
+CNMP +COPS +CGDCONT +CGACT +CGAUTH +CGPADDR +CGCONTRDP +CPIN +CICCID +CIMI +CNUM
+SIMEI +SPIC +CMCFG +CNVR +CNV +CLCK +CPWD +CLCC +CUSD +CSPN +CRESTORECOUNT
+CNWSEARCH +SPCAPABILITY +SPCONFIGSIMSLOT +SPENGMD +SPNCELLSCAN`

## Known rejections

`AT+CNVMBN?` and `AT+QMBNCFG="List"` → **ERROR** on this firmware.

## Hard risks

1. `+CPSI?` is a single point of failure for cell/band/signal/NR — capture ≥2 real samples per RAT before writing the parser.
2. `+CGCONTRDP` is the only DNS/gateway source and is undocumented — capture it verbatim.
3. `AT+COPS=?` blocks and is aborted by any serial byte.
4. `AT+SIMEI=`, `AT+CNV=`, `AT+CNVR=` write persistent modem state — exclude from any passthrough.
