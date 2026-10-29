# 35 — Which SIMCom release is on this unit, and whether it can be updated

Two questions, one measurement each:

1. **What SIMCom software is the module running?** → §1.
2. **Is there a path to a newer one, for stability?** → §4. Short answer: **the
   only path is a Tozed/ZLT ODU firmware package from the operator or ODM. There
   is no "SIMCom firmware update" that can be applied to this box on its own** —
   the SIM8260E *is* the box's SoC (§2), so the SIMCom baseline and the ZLT
   application ship in one signed image.

Captured 2026-10-28, device uptime 9 126 s, no reboot during the capture. Raw
output: [captures/2026-10-28-modem-firmware/version.txt](captures/2026-10-28-modem-firmware/version.txt).

---

## 1. The version, read from the module

```
ATI          Revision: V1.0.01                      <- what the vendor UI shows
AT+CGMR      +CGMR: 2212B01X62M88A-LGA_CUS_TZ       <- the real build id
AT+CSUB      +CSUB: B01V22
             +CSUB: SDX65_LE12_LGA_M88_TZ_V1.00_230410
AT+SIMCOMATI Revision: 2212B01X62M88A-LGA_CUS_TZ    (= CGMR, plus IMEI)
```

Decoded, field by field:

| Fragment | Meaning | Confidence |
|---|---|---|
| `2212` | SIMCom build prefix (project/release code) | naming convention |
| `B01` + `V22` (`+CSUB`) | baseband/software branch **B01**, revision **V22** | `+CSUB` states it |
| `X62` | Snapdragon **X62** generation (SDX65 line) — matches the vendor tree path `/home/tzsoft/sunsea-x62/` in `tz_upgrade_client` | high |
| `M88` / `LGA` | module hardware/memory variant, **LGA** form factor | `+CSUB` states it |
| `CUS` | **customer (custom) build**, not a SIMCom catalogue build | high |
| `TZ` | customized for **Tozed (ZLT)** | high |
| `SDX65_LE12_…_V1.00_230410` | SIMCom Linux/LE baseline **LE12**, dated **2023-04-10** | `+CSUB` states it |

Underneath it, the Qualcomm metabuild this unit boots (`/firmware/image/Ver_Info.txt`):

```
modem   MPSS.DE.2.0-01026-OLYMPIC_GENALL_PACK-1     (Time_Stamp 2023-02-15)
apps    LE.UM.6.2.3.r1-06200-SDX65.0-1
boot    BOOT.MXF.1.1.1-00175-Olympic-1
```

So there are three version numbers, and they are three different clocks:

| Number | Value | Where it comes from |
|---|---|---|
| Module release (what you asked for) | `2212B01X62M88A-LGA_CUS_TZ`, baseband `B01V22` | SIMCom, via `AT+CGMR`/`+CSUB` |
| SIMCom/Qualcomm baseline date | **2023-04-10** (LE12) / 2023-02-15 (MPSS) | `+CSUB`, `Ver_Info.txt` |
| Router product firmware | `1.09.39.10`, cfg `X16-OMN247-4.00` | Tozed, `SYS_FW_USER_VER` — see [11](11-device-and-firmware.md) |

**The baseline is ~3½ years old.** That is the number that matters for a
stability question, and it is not the `V1.0.01` the vendor UI shows.

## 2. Why "updating the SIMCom" means "updating the ODU"

The SIM8260E is an **LGA module whose SDX65 is the whole SoC**: one chip runs the
Linux router (`sdxlemur`, `LE.UM.6.2.3`) *and* the modem (`MPSS.DE.2.0`). The
device is not a host CPU driving a separate modem — which is why no AT-only or
modem-only update exists.

Evidence, all read-only on this unit:

- `/proc/mtd` is one Qualcomm boot chain — `sbl, mibib, xbl_config, abl, aop, tz,
  boot, modem (109.8 MB), simcom, system, oemdata, userdata, recovery, fota`
  plus `efs2/efs2_bak` and `apdp`/`sec`.
- `/firmware/image` on the read-only rootfs carries the module's own image set
  (226 files): `modem.b00…modem.b28`, `amss20.bin`, `Data20.msc`,
  `modem_pr/mcfg`, `olympic/qdsp6m.qdb`, `tzsc.mbn`, `cmnlib`, `keymaster`.
  The ODU image *contains* the modem image.

Consequence: a SIMCom stock image would replace the router. The unit would lose
the ZLT application layer, `X16-OMN247` configuration, band/CA policy and VoLTE
setup — everything in [11](11-device-and-firmware.md) and
[29](29-wan-drops-and-band-switching.md).

## 3. Would a newer baseline actually fix the instability?

Honest answer: **plausible, unproven — and not the cheapest thing to try first.**

Against "firmware is crashing":

- `subsys0: modem` is `ONLINE`, `ipa_fws` `OFFLINING` (its normal state).
- `dmesg` over the whole 2.5 h boot (1 126 lines) contains **no** SSR, modem
  restart, watchdog bark or fatal error — only the normal MPSS power-up at
  12.4–22.0 s.
- The five captured teardowns are all **NAS/RRC**: `EMM detached`,
  `EMM attach failed`, `Released AT RRC`, once `No cause information available`
  — see [29 §4c](29-wan-drops-and-band-switching.md).

For "firmware could still be involved":

- `EMM detached` / failed re-attach inside an EN-DC flap is exactly the layer a
  newer MPSS baseline tends to change (NAS robustness, NR anchor handling,
  operator-specific attach quirks). Three of the five causes are
  network-initiated, but the *handling* of them is the modem's.
- The build predates the deployments it is being asked to hold up on
  (`B01V22`, 2023-04).

So: treat a newer baseline as a candidate fix for the *recovery* behaviour, not
as the established cause of the drops. The experiments in
[29 §5](29-wan-drops-and-band-switching.md) are far cheaper and reversible — a
drop-rate baseline with `router-fix/ttl-normalise/` deployed, then
`AT+CSYSSEL="nr5g_disable"` (the LTE-pin test) — and either of them either
closes the question or produces the evidence a vendor would need to act.

## 4. The update paths that exist, ranked

### Path A — Tozed/ZLT ODU package (the only viable one)

A full-image package for the product, carrying the modem images in
`/firmware/image` and installed through the device's own upgrade flow
(`recovery`/`fota` partitions, `/bin/tz_upgrade_client`, `/bin/fota`).

- A newer generation is known to exist for this exact product:
  `2.0.0.5` / `X16-OMN247_4.0.04` (see [11](11-device-and-firmware.md)).
- Source: **the operator (Ooredoo Oman) or the ODM (Tozed/ZLT)**, quoting the
  area/product config `OMN247`. It is not reachable from any channel the device
  has configured ([21](21-fota-and-update-channels.md)).
- This is the *only* path that keeps secure boot, the ZLT app and the
  `X16-OMN247` configuration intact.

### Path B — SIMCom FAE, for the `CUS_TZ` build

Technically the "SIMCom update" you asked about: SIMCom does build and ship
per-customer images (`CUS` + `TZ` in the revision string proves this unit is one).
Getting one requires the Tozed project on the SIMCom side, and the resulting
image still has to be delivered inside a Tozed package (Path A) to be flashable
here. Realistic form: **ask Tozed** for the module baseline in their next release
and ask them what it is; SIMCom will not hand a third party a `CUS_TZ` image.

### Path C — generic SIM8260E firmware via QFIL / qdl / QFirehose — **not viable**

- No flash tool on the device: only `tz_upgrade_client` and `/bin/fota`;
  no `QFirehose`, `qdl`, `fh_loader`, or SIMCom update tool anywhere in `PATH`.
- The module boot chain carries `apdp` + `sec` partitions: this is a
  secure-booted Qualcomm image, and a generic build would not carry the
  provisioning/attestation this unit is fused against (worth confirming with
  Tozed, but the layout is unambiguous enough not to bet an ODU on).
- It overwrites `system`/`boot` as well as `modem`, i.e. it *is* a router
  reflash — to SIMCom's stock Linux, not ZLT's.
- Physically: it is a soldered LGA in a sealed outdoor unit; QDL needs the board
  in emergency-download mode over USB at boot, i.e. physical access.

### Path D — the network FOTA channel — exists in code, unusable today

- `USR_FOTA_SWITCH=0`, `USR_FOTA_URL=""` — the client has nowhere to look
  ([21](21-fota-and-update-channels.md)). Do not point it at an arbitrary host:
  auto-upgrade is armed and an untrusted package is root compromise.
- Worth recording, though: `tz_upgrade_client` reports **`modem_chip_firmware_version`,
  `modem_chip_bootloader_version`, `modem_chip_kernel_version`, `module_version`,
  `module_phy_version`** to its FOTA server. So the Tozed protocol *can* carry a
  module-firmware update to this unit. That is Path A with a network delivery
  rather than a USB stick — same package, same signing, once a trusted server
  exists.

## 5. Risk, if a package is ever obtained

| Risk | Reality |
|---|---|
| No rollback | `scripts/efs-nv/backup.sh --raw` preserves `efs2`, not `boot`/`modem`/`system`. Reverting means flashing the *old* vendor package, so **keep the current `1.09.39.10` package before upgrading**. |
| Field failure | The flash writes the same chip that provides LAN/Wi-Fi and the WAN. A bad write is a dead ODU at a remote site, i.e. a truck roll, not a re-flash. |
| Config loss | `userdata`/`oemdata` carry `/data/qmanager`, the deployed modules and the call-terminal contacts. Back them up first ([17](17-backups-and-restore.md)). |
| Boot-window hazards | Everything in AGENTS.md §4 applies again for the first boot after an ODU upgrade. |

## 6. Re-checking it later (safe commands only)

```sh
for c in "ATI" "AT+CGMR" "AT+CSUB"; do timeout 6 atcmd "$c"; done
cat /firmware/image/Ver_Info.txt
```

Do **not** use `AT+CLAC`, `AT+CNBP?`, `AT+CSYSSEL=?` or `AT+COPS=?` to enumerate
capabilities: they block the shared AT channel until `atcmd_daemon` respawns
(AGENTS.md §6, [33](33-antenna-controllability.md)).

## 7. What to ask the vendor for

> ZLT X16, area/product config `OMN247`, current product firmware `1.09.39.10` /
> cfg `X16-OMN247-4.00`, module baseline `2212B01X62M88A-LGA_CUS_TZ`
> (`+CSUB B01V22`, `SDX65_LE12…V1.00_230410`, MPSS `MPSS.DE.2.0-01026`).
>
> 1. The newest ODU package for `OMN247` (we see a `2.0.0.5` / `X16-OMN247_4.0.04`
>    generation exists) and **its** module baseline string.
> 2. The SIMCom release note for that baseline, specifically whether it changes
>    EMM attach/detach handling and EN-DC anchor release on an operator that
>    detaches the UE at NAS (`EMM detached`, `EMM attach failed` in `AT+CEER`).
> 3. Whether the package is signed/accepted by a secure-booted unit as shipped,
>    and whether downgrade back to `1.09.39.10` is permitted.
