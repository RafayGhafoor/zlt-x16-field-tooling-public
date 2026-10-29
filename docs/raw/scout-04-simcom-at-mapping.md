# SIMCom SIM8260E AT Command Mapping for QManager

Sources: `SIM8200_Series_AT_Command_Manual_V1.01.pdf` (451 pp, 2020-12-03; extracted to
`/tmp/notes-simcom-at/manual.txt` with PyMuPDF — `pdftotext` is not installed on this host),
plus `firmware-analysis/*.strings` (dialer, libolinterface, basic_prv) extracted from THIS
device (SIM8260E, `2212B01X62M88A-LGA_CUS_TZ`), and `DIAGNOSIS.md`.

Evidence tiers used below:

- **DEVICE** — command string literally present in this unit's shipped binaries
  (`firmware-analysis/dialer.strings`, `libolinterface.strings`, `basic_prv.strings`). Strongest
  evidence; it is what the vendor dialer actually drives the modem with.
- **MANUAL** — documented in the SIM8200/8260 AT manual but not referenced by the shipped
  binaries. Needs one live verification.
- **ABSENT** — in neither. Assume unavailable.

---

## Mapping table

| QManager need | Quectel command today | SIMCom command(s) | Response format differences | Feasibility |
|---|---|---|---|---|
| EPS registration stat | `AT+CEREG?` | **`AT+CEREG?`** [DEVICE] | Identical 27.007 form: `+CEREG: <n>,<stat>[,"<tac>","<ci>",<AcT>]`. SIMCom returns `<tac>`/`<ci>` as **quoted hex strings** (`"00C3"`), Quectel returns them unquoted. Parser must tolerate quotes. `<n>` defaults 0. | **Direct** (minor parsing) |
| 2G/3G registration + LAC/CI | `AT+CREG?` | **`AT+CREG?`** [MANUAL §4.2.1] | Same; `+CREG: <n>,<stat>[,"<lac>","<ci>"]`. LAC/CI unsupported in CDMA mode. Shipped binaries use `+CREG:` only as a URC (manual.txt:3498). | **Direct** |
| GPRS registration | `AT+CGREG?` | **`AT+CGREG?`** [MANUAL §8.2.1, manual.txt:7469] | `+CGREG: <n>,<stat>[,"<lac>","<ci>"]` — same as Quectel. | **Direct** |
| 5G/NR registration stat | `AT+C5GREG?` | **`AT+C5GREG?`** [DEVICE] | `+C5GREG: <n>,<stat>[,"<tac>","<ci>",<AcT>,<octet_len>,<nssai>]`. Extra trailing `<octet_len>`,`<nssai>` (network slice) that Quectel's `C5GREG` does not emit. `<AcT>` adds 10=EUTRA_5GCN, 11=NR_5GCN, 12=NGRAN, 13=EUTRA_NR. | **Parsing work** |
| Combined serving-cell info (band, EARFCN, PCI, TAC, cell ID, RSRP/RSRQ/SINR) | `AT+QENG="servingcell"` | **`AT+CPSI?`** (+ periodic `AT+CPSI=<0-255>` seconds) [DEVICE] | Big difference. `+CPSI:` returns **one CSV line per RAT, not key=value**: `+CPSI: LTE,Online,460-11,0x5A1E,187214780,257,EUTRAN-BAND3,1850,5,5,-94,-850,-545,15`. RSRP/RSRQ/RSSI are **dBm×10 / dB×10** (−850 = −85.0 dBm). NR leg is a separate line `+CPSI: NR5G_NSA,644,NR5G_BAND78,627264,-960,-120,95` (fields: PCellID, band, arfcn/ssb, RSRP×10, RSRQ×10, SNR×10). `+CPSI: NO SERVICE,<mode>` when deregistered. Note SIMCom's own example has an **unquoted MCC-MNC and a missing comma before RSRP in the NR5G_SA form** — parse defensively. | **Parsing work** (main replacement for QENG) |
| RSSI / CSQ | `AT+CSQ` | **`AT+CSQ`** [DEVICE] | Same `+CSQ: <rssi>,<ber>`. SIMCom extends the `<rssi>` table (100–199 = −116…−25 dBm for TD-SCDMA/RSCP), so a naive 0–31/99 parser will see values >31. | **Direct** (clamp >31 or map extended range) |
| RSRP/RSRQ/RSCP/ECNO (CESQ) | `AT+CESQ` | **`AT+CESQ`** [DEVICE] — **not in the manual** (0 hits), but the dialer sends it and parses `rxlev,ber,ecno,rsrq,rsrp` | Same 27.007 layout `+CESQ: <rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>`; dB×10. Undocumented ⇒ no contract, but empirically supported by this dialer. | **Direct** (verify once live) |
| SINR | `AT+QENG` / `AT+QSINR` | **`AT+CPSI?`** (`<RSSNR>` for LTE, `<SNR>` for NR5G) [DEVICE] | No standalone SINR command exists. LTE RSSNR is range 0–30 (integer); NR5G SNR is −230…400 → ÷10 dB. | **Parsing work** (from CPSI) |
| Extended RF metrics (MCS, CQI, mod, Tx power) | `AT+QENG` | **`AT+CNWINFO?`** (URC-enable `AT+CNWINFO=1`) [DEVICE] | `+CNWINFO: <SYS_MODE>,<EGCI>,<eNBID>,<MCS>,<DL_MOD>,<UL_MOD>,<CQI>,<TX_POWER>` — SYS_MODE is `LTE` or `NR5G`; EGCI decimal (PLMN‖cellID), eNBID hex string. Different field order from QENG. | **Parsing work** |
| Operator name / selection | `AT+COPS?`, `AT+COPS=?`, `AT+COPS=0` | **`AT+COPS?` / `AT+COPS=?` / `AT+COPS=<mode>,2,"<oper>"`** [DEVICE]; `AT+COPS=3,2` set numeric format; `AT+COPN` (read operator names), `AT+CPOL` (preferred list) [MANUAL] | `+COPS: <mode>,<format>,"<oper>"[,<AcT>]` — same. `AT+COPS=?` scan is **slow and is aborted by any serial input** (manual.txt:3677). `<AcT>` adds 11/12/13 for 5G. `AT+COPS=2` force-deregister is supported. | **Direct** |
| IMEI | `AT+CGSN` | **`AT+CGSN`** [MANUAL §2.2.30] and **`AT+SIMEI?`** → `+SIMEI: <imei>` [DEVICE] | `AT+CGSN` returns a bare line (no `+` prefix), identical to Quectel. `AT+SIMEI?` is the SIMCom-native form the dialer prefers. `AT+SIMEI=<15-digit>` writes IMEI (dangerous — do not expose). | **Direct** |
| IMSI | `AT+CIMI` | **`AT+CIMI`** [DEVICE] | Identical bare-line response. | **Direct** |
| ICCID | `AT+QCCID` / `AT+ICCID` | **`AT+CICCID`** → `+ICCID: <iccid>` [DEVICE] | **Command name differs** (`CICCID`, not `QCCID`/`ICCID`) and the URC-style prefix is `+ICCID:`. | **Direct** (rename only) |
| MSISDN | `AT+CNUM` | **`AT+CNUM`** [DEVICE] | `+CNUM: "<alpha>","<number>",<type>`; multiple lines, often `""` alpha. Same as Quectel. | **Direct** |
| SIM state | `AT+CPIN?` | **`AT+CPIN?`** → `+CPIN: READY\|SIM PIN\|SIM PUK\|PH-SIM PIN\|SIM PIN2\|SIM PUK2\|PH-NET PIN` [DEVICE] | Same. Additional SIMCom-specific: `AT+SPIC` (remaining PIN/PUK attempts) [MANUAL §3.2.6], `AT+CPAS` (activity), `AT+CSPN` (SPN from SIM). The dialer also parses `+CEN2:` and `+SPERROR:` SIM URCs that have no Quectel analogue. | **Direct** + extra signals |
| Flight mode / RF off | `AT+CFUN=0/1/4` | **`AT+CFUN=0\|1\|4`** [DEVICE], `AT+CFUN=7` (offline), `6` (reset) [MANUAL §3.2.1] | Same values 0/1/4, **plus SIMCom-specific 5=FTM, 6=Reset, 7=Offline**. Note the manual's rule: after `AT+CFUN=7` you must issue `AT+CFUN=6` or reboot to return online — `AT+CFUN=1` alone is not documented as sufficient. Map QManager's "airplane mode" to `CFUN=4`, not `CFUN=0`. | **Direct** (careful with 6/7) |
| PDP/APN definition (QICSGP equivalent) | `AT+QICSGP=<cid>,<type>,"<apn>",...` | **`AT+CGDCONT=<cid>,"<PDP_type>","<apn>"`** [DEVICE]; auth via **`AT+CGAUTH=<cid>,<auth>,"<user>","<pass>"`** [DEVICE] | SIMCom splits what QICSGP does into two commands. `CGDCONT` has a very long optional tail (`<ipv4_ctrl>,<emergency_flag>,…,<ssc_mode>,<s_nssai>,<pref_access_type>,<always_on_req>`) — the dialer emits both `AT+CGDCONT=%d,"%s","%s"` and a fully-zero-padded 5-arg form. `+CGDCONT:` read response echoes the whole tail; parse only fields 1–3. | **Direct** (2 commands instead of 1) |
| PDP activate/deactivate | `AT+QIACT` / `AT+QIDEACT` | **`AT+CGACT=<0\|1>[,<cid>]`** → `OK`; `AT+CGACT?` → `+CGACT: <cid>,<state>` per line [DEVICE] | Same semantics; SIMCom caps `<cid>` at **1…42**. No bearer-idle/`QIACT` distinction. Dialer retries `AT+CGACT=%d,%d` N times then gives up (`dialer.strings`). | **Direct** |
| PDP address | `AT+CGPADDR` | **`AT+CGPADDR[=<cid>]`** [DEVICE/MANUAL §8.2.12] | `+CGPADDR: <cid>,"<addr>"` — Quectel emits the address **unquoted** in some versions; SIMCom quotes it. Dialer parses `+CGPADDR: %d`. | **Direct** (minor parsing) |
| PDP context runtime info (IP, GW, DNS) | `AT+CGCONTRDP=<cid>` | **`AT+CGCONTRDP=<cid>`** [DEVICE] — **not in the manual** (0 hits). Dialer uses `AT+CGCONTRDP=6` (primary CID) with fallback to `=1`, and has a dedicated `sunsea_deco_CGCONTRDP()` decoder. | Not documented ⇒ no spec, but this is the **only** source of DNS servers and gateway on this modem. Field count/quoting must be derived from live output before relying on it. | **Parsing work** (high value, needs a capture) |
| Attach state | `AT+CGATT?` | **`AT+CGATT?`** [MANUAL §8.2.2] | `+CGATT: <0\|1>` — identical. Not used by the shipped dialer. | **Direct** |
| PDP event URCs (deact, addr change) | `AT+QINDCFG`, `+QIURC` | **`AT+CGEREP=<mode>[,<bfr>]`** → `+CGEV:` [MANUAL §8.2.14] | `+CGEV` codes (PDN ACT/DEACT, ME reason) differ from `+QIURC: "pdpdeact",<cid>`. URC text must be re-mapped. | **Parsing work** |
| Band list / band query | `AT+QNWPREFCFG="lte_band"` | **`AT+CSYSSEL="lte_band"`** → `+CSYSSEL: "lte_band",1:2:3:…` [DEVICE] | **Format is colon-separated** (3GPP TS 36.101 band numbers), not a hex bitmask. Companion keys: `"nr5g_band"` (SA), `"nsa_nr5g_band"`, `"w_band"`, `"nr5g_disable"` (0=none,1=SA,2=NSA). `AT+CSYSSEL=?` enumerates supported bands per key. Bare `AT+CSYSSEL` resets all bands to default. | **Parsing work** (bitmask↔colon list; this is the QNWLOCK analogue) |
| Band locking | `AT+QNWLOCK="common/4g",<n>,<band>,<pci>,<freq>` | **`AT+CSYSSEL="lte_band",<B1:B2:…>`** (band lock) and **`AT+CCELLCFG=1,<pci>,<freq>`** / `AT+CCELLCFG=0` (cell lock), `AT+CCELLCFG?` → `+CCELLCFG: <pci>,<freq>` [DEVICE] | Two separate mechanisms where Quectel has one command. SIMCom has **no PCI+band combo lock**; PCI lock takes an explicit **frequency (Hz?/ARFCN per manual example `1850`)** rather than Quectel's EARFCN/band pair. NR: `AT+C5GCELLCFG="pci",<pci>,<freq>,<scs>,<band>`, `AT+C5GCELLCFG="arfcn",<len>,<scs:freq>`, `AT+C5GCELLCFG="unlock"` [DEVICE for pci/unlock]. **The manual explicitly says C5GCELLCFG "was not verified test, so suggest customer not use it"** (manual.txt:5180). | **Parsing work + risk** (CCELLCFG/C5GCELLCFG the risky half) |
| NR enable/disable (SA/NSA) | `AT+QNWPREFCFG="nr5g_disable_mode"` | **`AT+CSYSSEL="nr5g_disable",<0\|1\|2>`** [DEVICE] | Same semantics (1=SA, 2=NSA), read-back `+CSYSSEL: "nr5g_disable",<n>`. Quectel's `QNWPREFCFG` roles `"mode_pref"` map to SIMCom `AT+CNMP=<n>` [DEVICE] and `AT+CNAOP` (acquisition order) [MANUAL]. | **Direct** |
| RAT / mode preference | `AT+QNWPREFCFG="mode_pref"` | **`AT+CNMP=<n>`** [DEVICE]; `AT+CNSMOD?` → `+CNSMOD: <n>,<stat>` [MANUAL §4.2.14] | SIMCom's `<n>` enumeration (2=auto, 13=GSM only, 14=WCDMA only, 38=LTE only, 109=NR5G only…) is **different from Quectel's string modes** — needs an explicit value map. | **Parsing work** |
| CA (carrier aggregation) info | `AT+QCAINFO` | **`AT+CCAINFO?`** [DEVICE] — **not in the manual** (0 hits). Dialer decoder keys on `+CCAINFO: "SCC"` / `"PCC"` labels. | Undocumented; layout unknown until captured. No CA command of any kind in the manual. | **Parsing work / verify live**; if output is empty → treat as unavailable |
| Neighbour cells | `AT+QENG="neighbourcell"` | **none** | The manual has zero occurrences of "neighbour/neighbor". The dialer contains LTE neighbour strings (`pcid=%s,4g_lte_neighbor rsrp=%s`) fed from a SIMCom-proprietary source (likely `AT+SPENGMD`/`AT+SPNCELLSCAN`), not from any manual command. | **Unavailable** (or QMI/`SPNCELLSCAN` reverse-engineering) |
| MBN / carrier profile | `AT+QMBNCFG="List"/"Select"/"AutoSel"` | **`AT+CMCFG="list"`, `AT+CMCFG="autoselect"[,0\|1]`, `AT+CMCFG="deactive","<file>"`** [DEVICE], response `+CMCFG: "<name>",<n>` / `+CMCFG: "AutoSelect",0` | **This is the real QMBNCFG analogue and it is present on this device.** Quectel's `QMBNCFG` is *rejected* here (`DIAGNOSIS.md`: "The SIMCom firmware rejects `AT+CNVMBN?` and `AT+QMBNCFG="List"`"), but the dialer carries a complete `CMCFG` client. Semantics differ: `autoselect,1` enables automatic profile selection instead of Quectel's `QMBNCFG="AutoSel",1`; there is no `"Select"` verb — activation is `AT+CMCFG="deactive",<file>` plus autoselect. The dialer also holds `qmbn_ver`/`mbn_ver` strings. | **Parsing work** — best available MBN path |
| NV item read/write (QCFG/QNVR equivalent) | `AT+QCFG`, `AT+QNVR` | **`AT+CNV=<path>[,<r/w>,<value>]`** and **`AT+CNVR=<index>,<0\|1>`** → `+CNVR: <idx>,"<value>"` [DEVICE] | SIMCom addresses NV **by EFS path string** (`AT+CNV=/nv/item_files/wcdma/rrc/…`) or by numeric item index (`AT+CNVR=2497,0`), where Quectel uses named keys. No enumerable key list. Index 6860 returns `module_identification`. | **Parsing work**, narrow scope; do not expose generically |
| Reboot | `AT+CFUN=1,1` / `AT+QPOWD` | **`AT+CRESET`** [MANUAL §3.2.13] → `OK` then module restarts; `AT+CFUN=1,1` also takes effect (`<rst>` only valid with `<fun>=1`) | `AT+CRESET` returns `OK` **before** the modem actually drops — the serial port goes away shortly after. Quectel `CFUN=1,1` behaves the same way. | **Direct** |
| Power off | `AT+QPOWD` | **`AT+CPOF`** [MANUAL §3.2.12] | Different command name; `OK` then URC/power-down. | **Direct** |
| Factory reset | `AT+QPRTPARA=3` / `AT&F` | **`AT&F`** (reset to manufacturer defaults) [MANUAL §2.2.20], **`ATZ`** (restore user settings from ME) [§2.2.26], **`AT&W`** (save) [§2.2.25] | Quectel's parameter-reset has no SIMCom equivalent. `AT&F` only resets AT-command settings, **not** PDP profiles or the vendor's `mdlcfg`/`tzcfg` store — a real factory reset must be done by the router app, not the modem. `AT+CRESTORECOUNT` exists on the device (dialer: `AT+CRESTORECOUNT` → `+CRESTORECOUNT: <n>`) but its meaning is unverified. | **Partial / mostly unavailable** |
| SMS format/mode | `AT+CMGF=1` | **`AT+CMGF=<0\|1>`** [MANUAL §9.2.3] | Identical. | **Direct** |
| SMS send | `AT+CMGS` | **`AT+CMGS="<num>"`** then body + `0x1A`; **`AT+CMGSEX`**, **`AT+CMSS`**, **`AT+CMSSEX`** [MANUAL §9.2.13/20/21] | Same `> ` prompt and `+CMGS: <mr>` / `OK`; failures come back as `+CMS ERROR: <err>` (code table §3.4). SIMCom adds `CMGSEX` (extended options). | **Direct** |
| SMS receive / storage | `AT+CNMI=2,1,0,0,0`, `AT+CPMS="SM","SM","SM"`, `AT+CMGR`, `AT+CMGD` | **`AT+CNMI=<mode>,<mt>,<bm>,<ds>,<bfr>`**, **`AT+CPMS`**, **`AT+CMGR`**, **`AT+CMGL`**, **`AT+CMGD`**, **`AT+CMGRD`** [MANUAL §9.2] | `+CMTI: "<mem>",<index>` on new message (same as Quectel). SIMCom supports mem values `"SM","ME","MT"` only; `"SR"` (status report) is not listed. `AT+CNMI=1,2,0,0,0` and `=2,1,0,0,0` are the documented working combinations. | **Direct** |
| URC destination / routing | (implicit) | `AT+CATR=<port>` [MANUAL §3.2.11] | No Quectel analogue. Needed only if QManager multiplexes UART/USB. | **N/A** |

---

## SIMCom-proprietary `AT$` commands

**None.** The string `AT$` appears **zero times** in the manual and **zero times** across
all `firmware-analysis/*.strings`. On SIM8200/8260 the vendor extensions use `AT+` with
vendor-only names instead (`+CMCFG`, `+CNVR`, `+CNV`, `+CCAINFO`, `+CRESTORECOUNT`,
`+SPENGMD`, `+SPNCELLSCAN`, `+SPIMEI`, `+SIMEI`, `+SPIC`, `+SPCAPABILITY`,
`+SPCONFIGSIMSLOT`, `+CSYSSEL`, `+CPSI`, `+CNWINFO`, `+CNWSEARCH`, `+CFAILUREMGRCFG`,
`+CBACKUPRESULT`, `+CNDISFLOW`, `+CAVIMS`, `+VOLTESETTING`, `+SPURSPEVA`, `+IMSHOLTEINFU`,
`+CEN2`, `+SPERROR`, `+CIREGU`, `+CQCNV`, `+CMCFG`). Treat that list as the true
"proprietary surface" and expect undocumented response layouts.

## Confirmed vs manual-only, and known rejections

**CONFIRMED on this device (SIM8260E, 2212B01X62M88A, from `*.strings`):** `+CPSI`,
`+CESQ`, `+CSQ`, `+CEREG`, `+C5GREG`, `+CNWINFO`, `+CCAINFO`, `+CCELLCFG`, `+C5GCELLCFG`,
`+CSYSSEL` (incl. `nr5g_disable`, `lte_band`, `nr5g_band`, `nsa_nr5g_band`, `w_band`),
`+CNMP`, `+CSYSSEL=?`, `+COPS?/?=/=3,2/=m,2,oper`, `+CGDCONT?/=`, `+CGACT?/=`,
`+CGAUTH?/=`, `+CGPADDR`, `+CGCONTRDP` (undocumented but used), `+CGACT=0,<cid>`,
`+CFUN=1/4`, `+CPIN?`, `+CICCID`, `+CIMI`, `+CNUM`, `+SIMEI?`, `+SPIMEI`, `+SPIC`,
`+CMCFG` (list/autoselect/deactive), `+CNVR`, `+CNV`, `+CRESTORECOUNT`,
`+CFAILUREMGRCFG`, `+CBACKUPRESULT`, `+CLCK="SC",2`, `+CPWD`, `+CLCC`, `+CUSD`,
`+CNDISFLOW`, `+CAVIMS`, `+VOLTESETTING`, `+SPENGMD`, `+SPNCELLSCAN`, `+CNWSEARCH`
(`"lte",120` / `"nr5g",3`), `+SPCAPABILITY`, `+SPCONFIGSIMSLOT`, `+SPURSPEVA`,
`+CSYSSEL`, `+CUAD`-family URCs (`+CIREGU`, `+CSCON`, `+CEN2`, `+CREG`, `+CGREG`).

**MANUAL-ONLY (not referenced by shipped binaries — verify before shipping):** `AT+CREG`,
`AT+CGREG`, `AT+CGATT`, `AT+CGEREP`/`+CGEV`, `AT+COPN`, `AT+CPOL`, `AT+CGSN`, `AT+CSPN`,
`AT+CPAS`, `AT+CRESET`, `AT+CPOF`, `AT&F`/`AT&W`/`ATZ`, all of chapter 9 except `CSCA?`
(`CMGF`, `CPMS`, `CNMI`, `CMGR`, `CMGL`, `CMGS`, `CMGD`), `AT+CNSMOD`, `AT+CNAOP`,
`AT+CGTFT`, `AT+CGEQREQ`/`CGEQMIN`.

**Known REJECTED on this unit (`DIAGNOSIS.md`):** `AT+CNVMBN?` and `AT+QMBNCFG="List"`
return ERROR — these are Quectel/Qualcomm-named commands not implemented by this SIMCom
firmware. Also confirmed: no Pakistan-specific MBN exists in the image; only
`ROW_Commercial` and `W_One_Commercial` are present. Use `AT+CMCFG="list"` to enumerate
what the modem itself believes is available, and `PDC`/QMI (`qmicli`) when a real
profile-ID activation is required — AT alone cannot do PDC activation.

## Gaps requiring QMI/`qmicli` fallback

1. **Neighbour cells** — no AT command in manual or in the shipped dialer path.
2. **MBN/PDC activation and profile IDs** — `CMCFG` only does list/autoselect/deactive;
   `DIAGNOSIS.md` records the working PDC path via ARM `qmicli` + QRTR with
   `ROW_Commercial` = `0B:18:13:5B:…:53:56`.
3. **Detailed PDU teardown reason** — `AT+CEER` collapses to "Regular deactivation"; the
   real WDS/DSI reason is only reachable via QMI (`dsi_get_call_end_reason()` in
   `basic_prv`, per DIAGNOSIS.md).
4. **Extended CA / per-CC metrics** — `CCAINFO` is undocumented; if empty, QMI
   `NAS/GET_CA_INFO` is the fallback.
5. **NR cell lock** — `C5GCELLCFG` is explicitly untested per the manual.

## Risks / open questions

- `AT+CPSI?` is the single point of failure for serving-cell, band, RSRP/RSRQ/SINR and NR
  leg data. Its NR5G_SA example in the manual is **syntactically inconsistent** (missing
  comma, unquoted PLMN); capture two real samples per RAT before writing the parser.
- `AT+CGCONTRDP` is the only DNS/gateway source and is **not documented** for this
  firmware. `DIAGNOSIS.md` shows the dialer using CID 6 (not 1) as primary, with a
  `CGCONTRDP=1` fallback — QManager must not hardcode CID 1.
- `AT+COPS=?` blocks and is aborted by any serial byte; do not run it on the URC channel.
- `AT+CFUN=7` requires `AT+CFUN=6` or a reboot to recover — a UI that only offers 0/1/4
  avoids the trap entirely.
- `AT+SIMEI=` and `AT+CNV=`/`AT+CNVR=` write persistent modem state. Keep them out of the
  QManager AT passthrough allow-list.
- `AT+CCELLCFG`'s `<freq>` unit is ambiguous in the manual (example `1850` looks like
  EARFCN, text says "Frequency, unsigned long int"). Verify on-air before exposing band
  lock in the UI.
- Nothing in this mapping was executed against hardware in this run; all DEVICE claims are
  string-presence evidence, not observed responses.

Scratch notes: `/tmp/notes-simcom-at/manual.txt`, `/tmp/notes-simcom-at/strings-at.txt`.
