# 23 — Cell locking and tower schedules on the SIM8260E

## Findings

The Quectel command family used by the upstream QManager (`AT+QNWLOCK`) is not
implemented by the X16's SIMCom SIM8260E. The SIM8260E has a narrower, native
LTE cell-lock command, which is enough for a single LTE EARFCN+PCI target. NR-SA
cell locking and modem lock-persistence controls are not safe to claim here.

| Evidence | Result | Interpretation |
|---|---|---|
| X16 `AT+QNWLOCK=?` / `AT+QNWLOCK="common/4g"` | `ERROR` | Quectel LTE lock API is absent |
| X16 `AT+CCELLCFG=?` | `ERROR` | This firmware has no advertised test form |
| X16 `AT+CCELLCFG?` (read-only) | `+CCELLCFG: 0,0` then `OK` | Native LTE lock read succeeds; current state is unlocked |
| X16 `AT+C5GCELLCFG=?` | `ERROR` | No tested NR command form |
| X16 `AT+C5GCELLCFG?` (read-only) | `OK`, no lock-state payload | No reliable NR state to parse |
| `/bin/dialer` strings | `AT+CCELLCFG=0`, `AT+CCELLCFG=1,%s,%s`; `AT+C5GCELLCFG="unlock"`, `AT+C5GCELLCFG="pci",%s,%s,%d,%d` | Vendor userland contains an LTE lock path and an NR path; a string alone is not proof that a command works |
| Factory UI `/tzwww/html/advance/lockPhyCell.html`, `/tzwww/js/advance/lockPhyCell.js` | LTE form labels the inputs EARFCN and Physical Cell ID; setting or clearing confirms a router reboot | The native operation is disruptive; do not exercise it as a casual probe |
| Factory UI `RequestCmd.LOCK_PHY_CELL` | `160` | The vendor UI uses the vendor CGI, not QManager's Quectel CGI |

The vendor UI and the SIMCom command manual describe the LTE operation as
`AT+CCELLCFG=1,<pci>,<freq>` / `AT+CCELLCFG=0`; the UI labels `<freq>` as EARFCN.
The SIMCom read response is ordered `<pci>,<freq>`, whereas QManager's
`QNWLOCK` shape is `<earfcn>,<pci>`. The X16 shim translates those orders and
supports **one LTE cell only**. Multi-cell input is refused rather than silently
approximated. The wrapper's **read** translation has been exercised on the
router; a lock write has deliberately not been applied to the customer's live
cell.

## Current QManager behavior

- `tower/status.sh` can now report the native LTE lock read through QManager's
  expected `QNWLOCK` response shape.
- One LTE target can be submitted through QManager's existing tower-lock flow.
  A user-initiated lock is expected to cause a radio interruption; use the
  explicit unlock operation to roll it back.
- NR-SA lock and `save_ctrl` persistence remain refused because the native write
  and state formats are not verified on this firmware. Do not turn a missing
  NR/persistence read into “unlocked” or “disabled”.
- A tower schedule requires at least one saved lock target. The X16 supports
  LTE-only targets through this adapter; it does not pretend NR-SA scheduling
  is supported.
- The runtime timer helper originally could not arm anything because its two
  static `qmanager-tower-schedule-{apply,clear}.service` units were absent. The
  X16 installer now deploys these units, and `start_qmanager` re-arms a saved
  schedule after `/etc` is mounted (the vendor loads systemd's unit graph too
  early to see files under `/etc` at boot). A future-time install/list/teardown
  cycle was verified live without touching the modem or QManager config.

## Safety and rollback

No lock was applied while investigating this feature. The device's current
read-only `AT+CCELLCFG?` result was `0,0` (unlocked). If an operator later
chooses to test LTE locking, first capture the current serving-cell
EARFCN/PCI and have the WAN recovery path ready. The vendor's own unlock form
uses `AT+CCELLCFG=0`; still verify post-reboot state, WAN registration, and LAN
reachability before declaring the test successful.

Host regression coverage is `tests/unit_tower_schedule.sh`. It exercises the
LTE-only translation, argument order, unsupported NR refusal, schedule payload
validation, the missing-target guard, and timer arm/teardown decisions without
issuing a write to a modem.
