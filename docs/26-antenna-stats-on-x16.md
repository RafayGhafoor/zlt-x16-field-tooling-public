# 26 — Antenna Statistics on the SIM8260E

> **Status: resolved.** Per-chain RSRP and SINR now come from the modem's own
> `AT+CRSRP?`/`AT+CSINR?` queries and are mapped in `deploy-x16/atcli_smd11`.
> Read [Resolution](#resolution-the-modem-does-have-per-chain-queries) first;
> the sections below are the investigation trail that led there. RSRQ remains
> the one metric with no per-chain source on this firmware.

## Finding

The X16's `Antenna Stats` page is receiving **one aggregate LTE reading** and
three explicit “not reported” sentinels. It is not receiving four independent
antenna-chain readings. The aggregate is currently placed in the UI's `ANT0 /
Main` slot, which makes the card look like only the main antenna has been
measured; that label overstates what the modem reported.

## Read-only evidence

Live `fetch_data.sh` signal shape at the time of investigation:

```json
{
  "lte_rsrp": [-94, null, null, null],
  "lte_rsrq": [-6, null, null, null],
  "lte_sinr": [13, null, null, null],
  "nr_rsrp": [null, null, null, null],
  "nr_rsrq": [null, null, null, null],
  "nr_sinr": [null, null, null, null]
}
```

The X16 adapter's QManager-format reads confirm the same boundary:

```
AT+QRSRP -> +QRSRP: -94,-32768,-32768,-32768,LTE
AT+QRSRQ -> +QRSRQ: -7,-32768,-32768,-32768,LTE
AT+QSINR -> +QSINR: 8,-32768,-32768,-32768,LTE
```

`-32768` is intentionally translated to `null` by QManager; it means “this
chain was not reported,” not a low signal value. The values in slot 0 come from
`AT+CPSI?`, which yields one LTE serving-cell measurement row (one RSRP/RSRQ/
RSSI/SINR set), not one row per antenna. `AT+CPSI=?` returns only the supported
refresh interval range, `(0-255)`.

Other read-only candidates checked during this investigation:

| Command | Result |
|---|---|
| `AT+CESQ=?` | `ERROR` |
| `AT+SPENGMD=0,6,0` | `ERROR` |
| `AT+SPENGMD=0,5,2` | `ERROR` |
| `AT+SPENGMD=0,6,1` | `ERROR` |
| `AT+SPENGMD=0,6,6` | `ERROR` |
| `AT+SPENGMD=0,0,6` | `ERROR` |
| `AT+CLAC` | Did not complete within a 12-second bound; no further `CLAC` probe was attempted |

The `SPENGMD` forms occur as strings in the vendor dialer, but their live
responses on this unit were errors. A string in the binary is not enough evidence
to treat it as a working sensor source. `/bin/dialer` also has internal names
such as `ant0_rssi`, `ant1_rssi`, `P_Rsrp_ant0`, and `P_Rsrp_ant1`; these are not
available in the QManager-visible modem response tested here.

## Result and next step

There is no verified X16 command producing antenna-specific RSRP/RSRQ/SINR for
ports 1–3. The current output is honest about the *missing* ports, but the
aggregate RSRP in slot 0 is misleadingly labelled `Main`. Do not duplicate it
across ports, and do not publish `AT+CESQ` or `SPENGMD` values that returned
`ERROR` as antenna readings.

A safe UI correction is to label the slot-0 figure **Composite** (or “Aggregate”)
and state that this modem firmware does not expose individual antenna-chain
readings. The user has not yet approved that wording change. Obtaining real
per-chain values requires a firmware/vendor interface that returns independent
chain measurements; no such working interface has been verified on this X16.

## Binary reverse engineering (REA + Ghidra, 2026-10-26)

`firmware-analysis/dialer` is a 32-bit ARM PIE with debug info, not stripped, so
the per-antenna path could be read rather than guessed. REA
(`npx rea-agents`, Ghidra 12.1.2 provider) analysed the image: 651 procedures,
2149 strings, image base `0x10000`.

`sunsea_update_4g_cell_info` is the only producer of antenna data:

1. `sunsea_send_at_with_format(0xf, recv_data, 0x800, "AT+SPENGMD=0,6,0\r")`
2. split the reply on `-`, then each token on `,`
3. token index → field:

| Token | Field |
|---|---|
| 0 | band (P/S) |
| 1 | EARFCN (P/S) |
| 2 | PCI (P/S) |
| 3 | RSRP (P/S) |
| 4 | RSRQ (P/S) |
| 5 | QrxLevMin (P/S) |
| 7 | bandwidth (P/S) |
| 9 | FGI (P/S) |
| 10 | NodeB ID (P/S) |
| 11 | Cell ID (P/S) |
| 22 | UL 64QAM capability |
| **23** | **`P_Rsrp_ant0` / `S_Rsrp_ant0`** |
| **24** | **`P_Rsrp_ant1` / `S_Rsrp_ant1`** |
| **37** | **`ant0_rssi`** |
| **38** | **`ant1_rssi`** |

Values are divided by 100 before display (`strtol(...) / 100`), then published
through `set_devinfo_value_by_id`: `0x497db` PCI, `0x497dc` NodeB ID, `0x497dd`
EARFCN, `0x497de` band, `0x497e0` RSRP, `0x497e1` RSRQ, **`0x49823`
`P_Rsrp_ant0`, `0x49824` `P_Rsrp_ant1`**. `ant0_rssi`/`ant1_rssi` are only used
in the `4G cell info` log line, never published.

### What the device actually holds

`/bin/devinfo <id>` reads that store directly (`get:/bin/devinfo [id]`):

```
301019 (0x497db) = 104          PCI
301020 (0x497dc) = 189321       NodeB ID
301022 (0x497de) = 1            band
301024 (0x497e0) = -90      RSRP
301025 (0x497e1) = -13          RSRQ
301091 (0x49823) =              P_Rsrp_ant0  <- EMPTY
301092 (0x49824) =              P_Rsrp_ant1  <- EMPTY
```

PCI, NodeB ID, RSRP and RSRQ are written **in the same success block** as the
antenna fields, so `AT+SPENGMD=0,6,0` is being parsed successfully — the reply
simply carries no values at tokens 23/24. This is the decisive evidence: the
SIM8260E answers SPENGMD with the serving-cell fields and omits the per-chain
ones. It is not a QManager mapping problem and not a missing AT command.

### Correction to the earlier probe

`/bin/atcmd "AT+SPENGMD=0,6,0"` returns `ERROR`, but that is **not** evidence
about the modem: the dialer sends SPENGMD on its own AT channel
(`sunsea_send_at_with_format(0xf, ...)`), not through `atcmd_daemon`, so the
atcmd client's `ERROR` reflects that path, not modem support. The devinfo
values above are the meaningful result.

Reproduce (host):

```sh
GHIDRA_INSTALL_DIR=/opt/homebrew/Cellar/ghidra/12.1.2/libexec \
  npx rea-agents@latest function firmware-analysis/dialer 0x1d982 \
  --snapshot /tmp/zlt-dialer.snap --format json
# on device: /bin/devinfo 301091 ; /bin/devinfo 301092
```

## External source check

- SIMCom's [SIM8260E product page](https://en.simcom.com/product/SIM8260E.html)
  advertises a **Diversity Receiver** and links an antenna-port mapping guide.
  That confirms RF diversity/physical ports; it does not claim independent
  per-port RSRP telemetry over AT.
- SIMCom's [SIM82XX/SIM83XX AT Command Manual, §4.2.12](https://files.waveshare.com/upload/c/c6/SIM82XX_SIM83XX_Series_AT_Command_Manual_V1.02.pdf)
  documents one LTE `AT+CPSI?` measurement tuple: RSRQ, RSRP, RSSI and RSSNR
  for the serving cell. It does not define a per-antenna array in that response.
- SIMCom's [hardware design guide](https://files.waveshare.com/upload/0/05/SIM83X0-SIM82X0_Series_Hardware_Design_V1.04_%282%29.pdf)
  lists ANT0–ANT3 as physical RF ports. Physical ports and modem-reported
  per-chain measurements are different capabilities.
- The closest public `SPENGMD` example found is a
  [Tozed LT70-C issue](https://github.com/4IceG/luci-app-3ginfo-lite/issues/96).
  Its attached modem script identifies the device as **Spreadtrum SL8563-based**
  and reads `AT+SPENGMD=0,6,0`; that is a different chipset/firmware, so its field
  layout does not transfer to the SIM8260E. Chinese-language searches did not
  find a SIM8260E-specific working per-chain AT response.

## Resolution: the modem DOES have per-chain queries

The dialer's SPENGMD path is a dead end on this firmware, but SIMCom exposes the
measurements directly and they work here. Verified live 2026-10-26:

```
AT+CRSRP?  -> +CRSRP: LTE,-96,-98,-90,-90   / +CRSRP: NR5G,-75,-76,-81,-76
AT+CSINR?  -> +CSINR: LTE,8,7,8,9           / +CSINR: NR5G,21,19,14,19
AT+CRSSI?  -> +CRSSI: LTE,-63,-63,-59,-59   / +CRSSI: NR5G,-64,-65,-71,-65
```

Four values per RAT = four receive chains, already in whole dBm/dB. `AT+CRSRQ?`
and `AT+CSRQ?` answer `ERROR`, so **RSRQ has no per-chain source**.

`deploy-x16/atcli_smd11` now maps these to the Quectel shape QManager's parser
already reads:

| QManager asks | Modem answers |
|---|---|
| `AT+QRSRP` | `AT+CRSRP?` → `+QRSRP: v0,v1,v2,v3,LTE` and `…,NR5G` |
| `AT+QSINR` | `AT+CSINR?` → `+QSINR: v0,v1,v2,v3,LTE` and `…,NR5G` |
| `AT+QRSRQ` | four `-32768` (null) — no per-chain measurement exists |

`parse_at.sh::_ant_pick` already selects a line per RAT, so no parser change was
needed. Deployed and confirmed through the API:

```json
{"lte_rsrp":[-95,-97,-89,-89],"lte_sinr":[9,7,11,9],
 "nr_rsrp":[-75,-76,-81,-75],"nr_sinr":[21,20,15,21],
 "lte_rsrq":[null,null,null,null]}
```

RSSI is available per chain too (`AT+CRSSI?`) but the `SignalPerAntenna`
contract has no per-port RSSI field; adding it is a frontend change, not an AT
one.

## Conclusion and the one usable hook

The SIM8260E's SPENGMD serving-cell reply stops before the antenna tokens, so
this firmware exposes no per-chain RSRP/RSSI. Nothing in QManager should be
changed to fake it.

If a future firmware starts reporting them, the integration point already exists
and needs no AT work: read `/bin/devinfo 301091` (`P_Rsrp_ant0`) and
`/bin/devinfo 301092` (`P_Rsrp_ant1`), which the dialer fills from the same
SPENGMD parse at whole-dBm scale. A QManager source would poll those two ids and
fill ports 0/1 instead of leaving them null — gated on non-empty values, so the
current behaviour is preserved when they are absent.
