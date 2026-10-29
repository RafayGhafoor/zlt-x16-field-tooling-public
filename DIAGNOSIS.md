# ZLT X16 Upload Disconnect Diagnosis

> **Update 2026-10-26 — see [`docs/`](docs/README.md).**
>
> This document is the 2026-09-01 deep dive and is still the best source on the
> modem/dialer internals. Two things in it have since been corrected:
>
> 1. *"The factory configuration had no TCPMSS clamp in the mangle table."* —
>    true, but the `filter` table **does** clamp:
>    `-A forward_mdl_chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`
>    (7573 packets matched, actively working). With WAN MTU 1400 that yields MSS
>    1360, which is correct. Treat the MTU hypothesis as **closed**.
> 2. The customer's "NAT table / firmware 1.5 → 2.x" theory has been tested and
>    does not hold: the actual firmware is `1.09.39.10`, conntrack peaks at ~1 %,
>    and the failure is a carrier-side PDP deactivation. See
>    [`docs/12-speedtest-disconnect-diagnosis.md`](docs/12-speedtest-disconnect-diagnosis.md)
>    and [`docs/14-config-defects-and-fixes.md`](docs/14-config-defects-and-fixes.md).
>
> SSH access is now enabled on port 22 — see
> [`docs/10-access-and-ssh.md`](docs/10-access-and-ssh.md).



Date: 2026-09-01

## Confirmed failure

During sustained upload, the router remains reachable but the cellular data
session is deactivated:

- `rmnet_data0` went down at kernel uptime `428.879s`.
- It returned at `463.525s`, producing a 34.6-second outage.
- The default route disappeared during the outage.
- The recovered session received a different WAN address and gateway.
- LTE registration remained active (`CEREG: 0,1`).
- The SIMCom dialer reported `Datacall Disconnected`, `state[0]`, `err[1]`.
- `AT+CEER` reported `Regular deactivation`.
- The dialer detected PDU session CID 6 as inactive and recreated it.

This is a cellular PDP/PDU data-session teardown, not a router reboot, Wi-Fi
disconnect, or loss of LTE registration.

## Active WAN configuration

| Item | Active value |
|---|---|
| Modem | SIMCom SIM8260E |
| Module revision | V1.0.01 |
| Module firmware | `2212B01X62M88A-LGA_CUS_TZ` |
| Modem baseband | `MPSS.DE.2.0-01026-OLYMPIC_GENALL_PACK-1` |
| Firmware generation | 2023 metabuild |
| Data manager | SIMCom/Sunsea `dialer` |
| PDP profile | CID 6 |
| APN | `connect.mobilinkworld.com` |
| PDP type | IPv4 |
| WAN interface | `rmnet_data0` |
| WAN MTU | 1400 |
| LAN/DHCP MTU | 1500 |
| TCP MSS override | Firmware setting disabled (`USR_DHCP_MSS=0`) |
| Runtime TCP MSS correction | 1360, both forwarded directions |
| TCP MTU probing | Enabled by `zlt-wan-fix.service` |
| QCMAP autoconnect | Disabled in `mobileap_cfg.xml` |
| QCMAP backhaul priority | WWAN fifth |

The factory configuration had no TCPMSS clamp in the mangle table. LAN clients
could therefore advertise MSS 1460 and forward those flows onto the 1400-byte
cellular WAN, whose correct IPv4 TCP MSS is 1360. This can produce
fragmentation and PMTU/offload stress during upload. It does not by itself
explain why the modem accepts a normal PDU deactivation, but it is a concrete
configuration defect and a plausible trigger for the old data stack.

## NVRAM and persistent configuration

Persistent storage includes:

- `efs2` and `efs2_bak`: modem EFS/NV storage.
- `modem`: modem firmware image.
- `simcom`: SIMCom vendor partition.
- `devinfo`: vendor configuration database.
- `/productinfo/tzcfg`: default and update configuration.
- `/data` and `/persist`: runtime overrides and modem support state.

Raw EFS, identity, SIM, RF calibration, credential, and security contents were
not dumped.

Safe authoritative values read through `mdlcfg`:

| Key | Value |
|---|---|
| `SYS_CFG_VER` | `X16-OMN247-4.00` |
| `SYS_AERA_ID` | `OMN247` |
| `SYS_FW_USER_VER` | `1.09.39.10` |
| `USR_NW_AUTO_DIAL` | `1` |
| `SYS_REBOOT_WHEN_MODEM_UNORMAL` | `0` |
| `USR_APN_PDP_TYPE` | `IP` |
| `USR_APN_MTU` | `1400` |
| `USR_DHCP_MTU` | `1500` |
| `USR_DHCP_MSS` | `0` |
| `SYS_INTERNET_LIMIT_SWITCH` | `0` |
| `SYS_FLOW_STATISTICS_SWITCH` | `0` |
| `SYS_DIALER_RESET_LOCK` | `0` |
| `USR_YOCTO_ORCA_SCG_LIMIT_SW` | `1` |
| `USR_YOCTO_ORCA_SCG_LIMIT_AT_STR` | `2,60,1800,5,3,120,1800,5` |
| `USR_LTE_LOCK_BAND_MASK` | `5` |

The device is running an Ooredoo Oman (`OMN247`) product configuration while
using a Jazz Pakistan APN. The generic hardware may support this, but the
operator customization and old SIMCom dialer are important differences from
the stable GreenPacket router.

The flow-control daemon is running, but its log is empty and the Internet
limit switch is disabled. A configured traffic quota did not cause the
disconnect.

## MBN assessment

The modem firmware includes many operator packages but no Pakistan-specific
carrier MBN. The expected fallback is:

`generic/common/ROW/Commercial/mcfg_sw.mbn`

Observed ROW package:

- Size: 48,436 bytes
- SHA-256:
  `a51ccca8e832c10344d18882498461fdc380fe3e4171659fb5f89c9a54df2dc0`
- Embedded identifier: `ROW_Commercial`
- Hardware MBN: Olympic standalone LE/SS

The package is structurally readable and contains normal ROW IMS/data policy
items. The same generic `ROW_Commercial` profile is documented as selected and
stable on the GreenPacket O5A. This makes the MBN a lower-probability cause.

The SIMCom firmware rejects the common read-only commands
`AT+CNVMBN?` and `AT+QMBNCFG="List"`. Confirming the selected and activated
profile requires a compatible Qualcomm PDC/QMI client. No MBN selection,
activation, NV write, or modem reset was performed.

### External ROW/PTCRB report

An external report described a Quectel modem that failed roaming attach with
EMM cause 33 while using `ROW_Commercial`. Selecting
`ROW_Generic_3GPP_PTCRB_GCF` fixed that device.

That case does not currently match this X16:

- The external modem uses Quectel commands such as `AT+QMBNCFG`, `AT+QCFG`,
  and `AT+QENG`; this X16 contains a SIMCom SIM8260E and rejects
  `AT+QMBNCFG`.
- The external failure occurred during roaming attach (`CEREG: 0,5`) with
  EMM cause 33. This X16 is registered on its home network (`CEREG: 0,1`).
- This X16 successfully establishes and transfers data before sustained
  upload triggers a later PDU deactivation.
- Its extended report is `Regular deactivation`, not EMM cause 33.
- No EMM/ESM cause 33 or registration-reject event exists in the available
  router logs.
- The X16 firmware image contains only `ROW/Commercial`; no
  `ROW_Generic_3GPP_PTCRB_GCF`, PTCRB, or GCF package is present.

The report is useful evidence that MBN policy can affect packet-service
behavior, but its exact command sequence and replacement profile must not be
used on this SIMCom router. A compatible MBN would need to come from a
SIM8260E firmware package and be selected through the SIMCom/Qualcomm PDC
mechanism.

### PDC profile experiment

A compatible ARM `qmicli` and its QRTR libraries were staged on the router,
and both firmware-supplied MBNs were loaded through Qualcomm PDC. The recovery
bundle is retained under `/data/zlt-mbn-recovery`.

| Profile | PDC configuration ID |
|---|---|
| `ROW_Commercial` | `<mac-redacted>:<mac-redacted>:<mac-redacted>:53:56` |
| `W_One_Commercial` | `<mac-redacted>:<mac-redacted>:<mac-redacted>:DF:4B` |

Activating `W_One_Commercial` made the fault substantially worse. CID 6
deactivated repeatedly, including without a controlled upload, and recovery
could take about 39 seconds. `ROW_Commercial` was then reactivated
successfully using its known PDC ID.

Post-rollback checks confirmed:

- LTE registration remained valid (`CEREG: 0,1`).
- CID 6 and the default route were recreated with new addresses.
- A 25-second interval transferred more than 40 MB upstream before another
  CID 6 deactivation.
- The dialer continued to report `state[0]`, `err[1]`, followed by successful
  registration checks and CID 6 recreation.
- Further disconnects occurred at `09:26:33` and `09:28:34` router time.

The ROW rollback restored the original behavior but did not solve it.
Therefore `W_One_Commercial` is unsuitable, while the available evidence does
not support MBN selection as the root cause. Do not test additional
carrier-specific profiles without an official SIM8260E-compatible generic or
PTCRB/GCF package and a verified rollback ID.

## Other findings

- No modem subsystem restart or crash occurred during the captured outage.
- No thermal mitigation was active; observed temperatures were about 39-45 C.
- Memory, CPU load, and conntrack usage were healthy.
- IPA/QMAP checksum, queue, TX, RX, and aggregation error counters were zero.
- `QCMAP_Bootup.service` fails on every boot, although the later QCMAP process
  remains running.
- A historical 43.7 MB `/data/coredump/core.dialer` exists, showing that the
  vendor dialer has crashed previously.
- The active IPACM config classifies Ethernet interfaces as ODU interfaces,
  but its WAN definitions otherwise match the factory configuration.

## Firmware reverse engineering

The following binaries were extracted exactly from the router and analyzed
locally:

- `/bin/dialer`: unstripped 32-bit ARM PIE with complete DWARF information.
- `/usr/lib/libolinterface.so.1.0.0`: SIMCom OSM IPC client wrapper.
- `/usr/bin/basic_prv`: SIMCom packet-data provider using Qualcomm
  `libdsi_netctrl`.

The packet-data control path is:

`dialer -> libolinterface -> OSM IPC -> basic_prv -> libdsi_netctrl -> WDS`

The reverse-engineered disconnect path shows:

- `data_call_evt_cb()` in `dialer` only logs the disconnect notification. It
  does not request a teardown.
- `basic_prv` receives a spontaneous DSI disconnect event and calls
  `dsi_get_call_end_reason()`.
- That detailed DSI/WDS reason is collapsed into the public SIMCom API's
  generic `err=1`, so the useful modem reason never reaches the dialer log.
- `dsi_stop_data_call()` is confined to the explicit data-call-stop API and is
  not called by the spontaneous disconnect event path.

This rules out the observed callback itself as the initiator and favors a
carrier/modem-protocol teardown below the dialer.

The dialer's recovery is also defective. Its one-second handler invokes the
PDP-state and WAN-address watchdogs only on an approximately 60-second
schedule. The watchdog discovers that the address is already gone, tears down
the stale context, and recreates CID 6. This explains the observed recovery
delays from roughly 6 to 59 seconds depending on where the failure occurs in
the timer cycle.

No SCG limiter action, NR disable command, modem subsystem restart, or local
data-call-stop request was found immediately before the captured disconnects.

## Installed MTU workaround

A reversible workaround is installed and enabled as
`zlt-wan-fix.service`. Its files are:

- `/data/zlt-wan-fix/zlt-wan-fix.sh`
- `/etc/systemd/system/zlt-wan-fix.service`

After `TZApp.service` starts, it:

- keeps `rmnet_data0` at MTU 1400;
- clamps forwarded TCP SYN packets to MSS 1360 in both directions;
- enables `net.ipv4.tcp_mtu_probing=1`.

The change does not replace `dialer`, alter modem firmware, write an MBN, or
change persistent DHCP/NVRAM values. Local source and removal instructions
are under `router-fix/`.

A router-originated 128 MiB upload completed with HTTP 200 at approximately
3.84 MB/s after applying the runtime settings, without a PDU teardown or a new
dialer disconnect event. Router-originated TCP already derives MSS from the
1400-byte WAN and does not traverse the FORWARD clamp, so an upload from a
client physically routed through the X16 is still required to validate the
specific LAN MSS correction.

## Comparison with GreenPacket O5A

The working O5A uses:

- A newer `MPSS.DE.3.0` modem generation.
- QCMAP as the exclusive WAN owner.
- Explicit IPv4-only policy.
- WWAN as the first backhaul.
- QCMAP autoconnect enabled.
- WAN route MTU 1500.
- TCP PMTU probing enabled.

The X16 uses an older `MPSS.DE.2.0` SIMCom stack and a vendor-specific Sunsea
dialer. Its disconnect is generated below the Linux routing layer as a normal
PDU deactivation.

## Likely causes, ranked

1. LAN MTU 1500 to WAN MTU 1400 mismatch interacting with the old packet-data
   stack during forwarded uploads.
2. Old SIM8260E modem firmware or lower DSI/WDS defect triggered by sustained
   uplink traffic.
3. Carrier/APN interaction with the legacy `connect.mobilinkworld.com` profile.
4. Ooredoo Oman product customization being used on a Pakistan carrier.
5. MBN policy mismatch. Direct testing shows `W_One_Commercial` is worse and
   that restoring `ROW_Commercial` preserves the original failure, making the
   available MBNs less likely than the firmware, APN, and MTU issues.

## Recommended test sequence

1. Test the same SIM and upload workload in the working GreenPacket router.
2. Configure the X16 with the exact APN/PDP type used by the working router.
3. Keep IPv4-only and perform a 256-512 MiB upload from a client physically
   routed through the X16 while `zlt-wan-fix.service` is active.
4. Make WWAN the first QCMAP backhaul and enable autoconnect.
5. Repeat the upload test while capturing the dialer log and `AT+CEER`.
6. Obtain a newer SIM8260E firmware, preferably a newer MPSS generation, from
   the router or module vendor.
7. Keep `ROW_Commercial` active unless an official SIM8260E-compatible generic
   or PTCRB/GCF package becomes available.
8. If the failure remains, add a reversible fast-recovery watchdog before
   attempting any binary patch. Instrument `dsi_get_call_end_reason()` or
   collect modem diagnostic logs to recover the detailed WDS reason.

## Evidence

- `zlt-diagnostic-20260901-093727/connectivity.csv`
- `zlt-diagnostic-20260901-093727/router.jsonl`
- `zlt-mbn-wone-20260901-1018/connectivity.csv`
- `zlt-mbn-row-restored-20260901-1023/connectivity.csv`
- `zlt-mbn-row-state-20260901-1026/router.jsonl`
- `firmware-analysis/dialer`
- `firmware-analysis/libolinterface.so.1.0.0`
- `firmware-analysis/basic_prv`
- `firmware-analysis/one-second-handler.asm`
- `firmware-analysis/basic-data-event.c`
- `firmware-analysis/basic-data-api.c`
- `firmware-analysis/mtu-upload-test.log`
- `router-fix/zlt-wan-fix.sh`
- `router-fix/zlt-wan-fix.service`
- `/tmp/logs/DIALER.log` on the router
- `/firmware/image/Ver_Info.txt` on the router
- `/etc/data/mobileap_cfg.xml` on the router
- `/productinfo/tzcfg/main_config` through the mounted product configuration
- GreenPacket comparison:
  `/Users/emumba/Downloads/projects/greenpacket-o5a`
