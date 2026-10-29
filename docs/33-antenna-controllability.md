# 33 — Can the antenna be configured through software?

> **Verdict: no.** On this firmware the four receive chains are **measurable** but
> not **selectable**. There is no AT command, no vendor daemon, no vendor page and
> no device-tree/I²C hook that sets antenna port, diversity, MIMO/SRS switching or
> tuner state. What the software *can* configure is band, RAT and cell — which
> changes what the network schedules onto those chains, not the chains themselves.
>
> Probe date 2026-10-28 21:16–21:36 PKT, device `192.168.3.1`, modem
> SIM8260E `Revision V1.0.01`, uptime unchanged throughout (no reboot).

## The distinction that matters

| Question | Answer |
|---|---|
| Can software **read** per-antenna signal? | **Yes** — `+CRSRP` / `+CSINR` / `+CRSSI`, four chains each. Already mapped; see [26](26-antenna-stats-on-x16.md). |
| Can software **choose** which antenna/chain is used? | **No.** |

## Evidence — measurement works

```
AT+CRSRP?  -> +CRSRP: LTE,-73,-73,-75,-76
AT+CSINR?  -> +CSINR: LTE,12,12,10,10
AT+CRSSI?  -> +CRSSI: LTE,-40,-41,-43,-43
```

Four independent values per query, so Rx diversity is live and observable. (The
spread — 3 dB across chains, −40…−43 RSSI — says all four receive paths are
connected and healthy; a dead port would read tens of dB down.)

## Evidence — configuration is absent

Every candidate control, read in its **test/query** form so nothing was written:

| Command | Response | Family |
|---|---|---|
| `AT+CANT?` / `AT+CANT=?` | `ERROR` | SIMCom antenna |
| `AT+CANTSW?` / `AT+CANTSW=?` | `ERROR` | SIMCom antenna switch |
| `AT+CRXANT?` | `ERROR` | SIMCom Rx antenna |
| `AT+CDIV?` | `ERROR` | diversity |
| `AT+CSRSANT?` | `ERROR` | SRS antenna switching |
| `AT+CANTMODE?` / `AT+CANTTUNE?` | `ERROR` | antenna mode / tuner |
| `AT+QCFG="antsel"` | `ERROR` | Quectel antenna select |
| `AT+QCFG="rx_diversity"` | `ERROR` | Quectel diversity |
| `AT+QCFG="srs_switch"` | `ERROR` | Quectel SRS |

Three independent sources agree, which is why the answer is not "we did not find
the right command":

1. **The vendor manual.** `SIM8200_Series_AT_Command_Manual_V1.01.pdf` documents
   **316** AT commands; the string `antenna` does not occur once, and no
   diversity/SRS/MIMO *set* command exists. The only `ANT`-bearing command is
   `AT+CFTRANTX` — an EFS file transfer, unrelated.
2. **The vendor userland.** `/bin/dialer` contains only measurement paths
   (`P_Rsrp_ant0/1`, `S_Rsrp_ant0/1`, `ant0_rssi`, `ant1_rssi`, consumed from
   `+SPENGMD` tokens). Its app-ID table names `APP_ID_ANTENNASW` and
   `APP_ID_ANTENNA_TUNER`, but **no binary of either name exists on the device** —
   the enum entries are shared-header leftovers, not a running service.
3. **The hardware/OS surface.** No I²C tuner (only `3-001a/1b/1d` present, the
   PMIC/charger set), no RF-switch or antenna node in `/proc/device-tree`, no
   antenna/tuner/RF-switch driver in `dmesg`.

The vendor web UI has no antenna page either (`/tzwww/html/config/` and
`/tzwww/html/advance/` enumerate every page; there is no `antenna*`). The only
antenna item is **read-only reporting**: Device Self-Check shows `antenna_status`
as Success/Fail via the `DEVICE_SELF_CHECK` CGI, and the `deviceAntennaInfo`
helper block in `deviceSelfCheck.html` is commented out. That is a status lamp,
not a control.

## What the software can configure (the honest substitute)

All AT, all already wired through `qcmd` / `atcli_smd11`:

| Lever | Command | Live state now |
|---|---|---|
| LTE band set | `AT+CSYSSEL="lte_band",1:3:…` | as configured (B3 PCC, B1+B5 SCC in CA) |
| RAT preference | `AT+CNMP=<n>` | auto |
| Cell lock | `AT+CCELLCFG=1,<pci>,<earfcn>` / `=0` | `+CCELLCFG: 0,0` → unlocked |
| Flight mode | `AT+CFUN=0/1/4` | online |

Those change *which carrier/cell* the modem camps on — and therefore what the
network schedules (CA, MIMO rank, which chains get used) — but they never select
a port. See [23](23-cell-locking-on-sim8260e.md) for the cell-lock contract.

## The one theoretical back door — do not use it

`AT+CNVR=?` answers `+CNVR: (0-7232),256`: the modem exposes **7233 NV items**
read/write. Qualcomm's NV space does contain RF/antenna-path configuration, so in
principle this is a software route. In practice it is not a usable one:

- no index→meaning mapping is published for this firmware, so finding the right
  item is guesswork;
- NV is calibration-adjacent: a wrong write can desense or brick RF, and this
  board has no verified rollback image;
- `AGENTS.md` §5 rule 3 forbids modem-NV/MBN/PDC writes without a verified
  rollback ID.

Treat antenna topology as **fixed hardware**. SIM8260E ANT0–ANT3 are physical
ports; diversity/MIMO/SRS behaviour is network-scheduled and set by modem
firmware, and this firmware publishes no knob for any of it.

## Probe hazard (learned here, costs 13 minutes of AT outage)

Do **not** run `AT+CLAC` on this unit. It never finishes, and — worse — it wedges
`atcmd_daemon` for *every* client: `/bin/atcmd` requests then hang forever
(`__skb_wait_for_more_packets`), which also silences QManager's pollers and the
call bridge (`AT+CPAS`, `AT+CLCC`, `ATH` all time out; it logs
`AT broker quarantined`). The daemon must be restarted:

```sh
P=$(pgrep -f '^atcmd_daemon$'); kill -9 "$P"; sleep 0.3
setsid /etc/initscripts/start_atcmd_daemon start
/bin/atcmd "AT"   # -> OK
```

Recovery is immediate, the dialer survives it (no reboot; WAN and uptime
unaffected, call bridge logged `AT broker answering again` within the same
second), but nothing restarts that daemon on its own — there is no unit, it is
launched with `&` from `/etc/initscripts/start_atcmd_daemon` — so a kill without
the restart line leaves the modem AT path dead until reboot.

## Reproduce

```sh
# measurement (safe)
/bin/atcmd 'AT+CRSRP?'   /bin/atcmd 'AT+CSINR?'   /bin/atcmd 'AT+CRSSI?'
# configuration probes (safe: query forms only, every one answers ERROR)
for c in 'AT+CANT?' 'AT+CANTSW?' 'AT+CRXANT?' 'AT+CDIV?' 'AT+CSRSANT?' \
         'AT+QCFG="antsel"' 'AT+QCFG="rx_diversity"' 'AT+QCFG="srs_switch"'; do
  printf '%s -> ' "$c"; timeout -s KILL 8 /bin/atcmd "$c"
done
```

Use `timeout -s KILL`: `atcmd` ignores `SIGTERM`, so `timeout 8` alone never
returns and holds the AT channel open (this is how the first CLAC attempt jammed
it).
