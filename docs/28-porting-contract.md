# 28 — The device contract (what a new device must provide)

This module is a **port layer**: QManager speaks Quectel, the X16 is a SIMCom
SIM8260E. Every fix in `deploy-x16/` is really a statement about the *shape of a
device*, not about this box. This page collects those statements in one place so
a second device is a checklist and a set of fixtures, not an archaeology dig.

Each row is a contract. "Encoded in" is the code that assumes it; "tests" is
what fails if a new device breaks it. When you port, add a fixture for the new
device and the tests tell you what to change — the alternative is rediscovering
these from a broken UI.

---

## 1. Transport

| Assumption | Encoded in | If a new device differs |
|---|---|---|
| AT is reachable through **one serialised client with no server-side timeout**; a command the modem never answers blocks every later caller, including the dialer | `atcli_smd11` `at_raw`, `QM_AT_TIMEOUT`, the blacklist | Keep the allowlist + per-call timeout even if the new transport is nicer. The allowlist is what stops one bad translation from taking the WAN down. |
| A `;`-compound is issued by splitting and running each part, restoring `AT+` on bare `+X` tokens | `atcli_smd11` chain splitter | Nothing. This is transport-neutral. |
| `+CPSI?` may return **two records** (LTE and `NR5G_NSA`) on one answer | `emit_qeng` | A device whose capability query or serving-cell read returns one record per call changes `emit_qeng` only. |

## 2. Serving cell / RAT

| Assumption | Encoded in | Verify |
|---|---|---|
| CPSI LTE fields 11–14 are **RSRQ, RSRP, RSSI, SINR**, the first three in tenths of a dB, SINR whole | `emit_qeng` | `tests/unit_atcli_smd11.sh` pins each position and the scaling |
| EN-DC is signalled by a **second CPSI record**, not by a token inside the LTE line | `emit_qeng` | EN-DC fixtures in the same suite |
| The synthesised EN-DC `LTE` row must **drop** the `servingcell` prefix (the parser selects it that way) | `emit_qeng` | same suite |
| `+CCAINFO` field 9 is SINR in 0.1 dB | `emit_qcainfo` | `unit_atcli_smd11.sh` (`PCC SINR from CCAINFO field 9`) |
| Wideband RSSI can legitimately be as high as ≈ −32 dBm; the sanity floor is −20 dBm and the real rule is **RSSI ≥ RSRP** | `emit_qcainfo` | same suite, incl. a negative control |

## 3. Timing advance / distance

| Assumption | Encoded in | Verify |
|---|---|---|
| TA arrives in **microseconds** from QMI; `calculateLteDistance` wants an **index**; one index = 16·Ts = 0.5208 µs, i.e. **×1.92** | `emit_qnwcfg_time_advance` | host test of the conversion + `tests/ts/distance.test.ts` |
| Index 0 means "no data", valid range 1..1282 | same | boundary cases in the shim suite |
| NR timing advance **does not exist** on this generation: libqmi 1.34.0 has no NR TA, no AT command, nothing in the vendor store | same | asserts a bare `OK`, so the UI shows "not reported" instead of a number |

## 4. Non-AT sources (the part most likely to differ)

Both are injected, so a new device points them elsewhere rather than editing
code:

| Variable | Default | What it is |
|---|---|---|
| `QM_PHY_DEVINFO_FILE` | `/tmp/.devinfo_module_data` | the vendor dialer's dump of its devinfo table (`CQI`, `CQI_5G`, `lte_rank`, `nr_rank`, `DL_MCS_5G`, `sim_status`, `network_type_str`, …) |
| `QM_QMI_BIN` / `QM_QMI_LIBDIR` | `/data/qmanager/lib/qmi/{bin,lib}` | libqmi `qmicli` plus its private `.so`s |
| `QM_QMI_DEV` | `qrtr://3` | the QMI node (NAS was on node 3 here) |
| `ATC` | `/bin/atcmd` | the AT client |

A device with no vendor store and no QMI is fine: every consumer fails soft and
the UI shows "not reported". **A device with richer sources must not regress the
fallback** — that is what the fail-soft tests exist for.

## 5. Vendor-owned data paths

| Path | Grammar | Owner |
|---|---|---|
| `/data/sms/sms_read/<slot>` | `<slot> <flag> <sender> <YYYY-MM-DD> <HH:MM:SS> <body>`; `$` = space in the sender; flag 0 = **unread** | `/bin/sms_mgr` |
| `/etc/qmanager/video_domains.txt` | one domain per line | QManager (seeded by the module) |

Rows are **not uniform**: some have no sender and join date and time with `$`,
and some contain control bytes (raw `0x19`/`0x01`), which makes the whole JSON
array invalid if they reach `jq` unescaped. A parser that assumes a fixed field
count will lose every message rather than one.

## 6. Host platform

| Assumption | Where it bites |
|---|---|
| `sh` is **ash** (busybox): `VAR=val func` does **not** export `VAR` into the function's children | `qmi_read.sh` — `platform.sh` defines `qm_timeout` as a function, so a prefixed `LD_LIBRARY_PATH` never reached `qmicli`. Export explicitly. |
| busybox **awk 1.31**: `splits()` is a streaming filter (use `split()[].`); a 6-argument `printf` can emit a spurious line; `gsub(/\n/)` works but raw control bytes need `[\001-\037]` | `sms.sh` parser, `phy_metrics.sh` awk |
| busybox **ntpd** has no `-g` and **refuses to step a large offset, exiting 0** | `qmanager-timesync` — must bootstrap the clock from an HTTP `Date:` header before handing over to NTP |
| `flock` has no `-w` | CGI lock helpers poll with `-n` |
| No `ip`, no `ifconfig` in `PATH`, no `getent`, no `python` | use `/bin/busybox.nosuid`, `/proc/net/*`, `/sys/class/net` |
| Journald does not persist | any durable evidence must go to `/data/log/<service>.log` |

## 7. Boot ordering

| Assumption | Encoded in |
|---|---|
| `/etc` is a **separate volume mounted ~10.6 s in**, after systemd has scanned its units, so `systemctl enable` cannot start anything at boot | `start_qmanager`, all units are launched from the `StartTZApp` hook |
| `/tmp` is empty at boot | boot-time caches (`/tmp/qmanager_supported_bands.env`, `/tmp/.time_synced`) are rebuilt, never assumed |
| Nothing self-heals by default | `qmanager-guard.timer`, `qmanager-dpi-ensure.timer`, `zlt-smartdns.timer` |

## 8. What "porting" actually means here

1. Point `ATC` and (if it has them) `QM_PHY_DEVINFO_FILE` / `QM_QMI_*` at the
   device's sources.
2. Add fixtures: a serving-cell capture, a CAINFO capture, a capability
   response. Run the suites — the failures name the assumption that broke.
3. Wire boot via whatever the device actually runs after `/etc` mounts; do not
   trust `systemctl enable`.
4. Anything the device cannot report must stay `null`. **Never** substitute a
   plausible constant: the UI renders null as "not reported", which is true,
   and a fabricated 0 or an aggregate copied into four slots is not.

## 9. Known-unportable by construction

- NR neighbour cells (no source on this generation).
- NR timing advance (libqmi 1.34.0 has none).
- Per-antenna RSRQ (`AT+CRSRQ?`/`AT+CSRQ?` answer ERROR).
- `AT+QICSGP` (Quectel PDP-context auth) — genuinely unsupported here; the APN
  save path is the only caller and it is honest noise in the log view.
- Full-band `AT+QSCAN` (Quectel-only); the LTE neighbour scan uses the native
  `AT+QENG="neighbourcell"` instead.
