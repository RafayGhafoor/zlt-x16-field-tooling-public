# Test-authoring brief — coverage for the X16 QManager port

You are writing tests, not features. **Do not change production files.** If a
test exposes a bug, record it in your final report; do not fix it.

## The goal, and why it is framed this way

This repo ports QManager (written for a Quectel RM520N-GL) onto a SIMCom
SIM8260E in a ZLT X16. **A second device is expected.** So the tests must
encode *the contract between the port and a device*, not the quirks of this one
box. Concretely:

- Device-specific truth (AT responses, which command answers what, numeric
  scaling) belongs in **fixtures**, so adding a device means adding fixtures,
  not rewriting tests.
- A test should fail with a message that names **the assumption that broke**,
  e.g. `SINR is whole dB on this firmware; if a device reports tenths, its
  fixture must say so` — not just `expected 13, got 130`.
- Where a value genuinely does not exist on a device, the correct contract is
  **null, never 0 and never a guess**. Test that.

## Harness conventions (match `tests/unit_atcli_smd11.sh`)

- POSIX `sh`, no bashisms, must run on macOS and Linux with no installs.
- `set -u`. Self-contained: sourcing nothing from the network.
- Print `  ok   <what held>` / `  FAIL <what broke>` lines, a final
  `PASS  N assertions` or `FAIL  N passed, M failed` line, and **exit non-zero
  on any failure**.
- Fixtures live in `tests/fixtures/`. Fake executables (used via an env var the
  code under test already honours) live directly in `tests/` and must be
  `chmod +x`.
- Never depend on the device. These are host tests.

## Existing suites (read them first, match their style, do not edit them)

```
tests/unit_atcli_smd11.sh        153 assertions — shim transport/dialect/safety
tests/unit_traffic_sampler.sh
tests/unit_neighbour_scan.sh
tests/unit_speedtest.sh
tests/unit_tower_schedule.sh
tests/unit_history_archive.sh
tests/fake-atcmd                 fake /bin/atcmd, fixture-driven (FAKE_CPSI=...)
tests/fixtures/                  captured real responses
tests/smoke_endpoints.sh         device-side endpoint sweep (needs --device)
tests/check_boot_wiring.sh       device-side boot assertions
```

`tests/run-all.sh` is **owned by the main agent — do not edit it.** Write your
suite so it can be invoked as `sh <yourfile>` and registered later.

## Hard rules

- **Never write to the device.** Read-only probes only, and only if a task says
  you may. Prefer the captures in `docs/captures/` — they already contain the
  real AT/QMI output you need.
- Do not `grep -r` over `/firmware`, `/usr`, `/bin`, `/data` on the device.
- Do not edit any file outside the paths your task assigns you.
- Run your suite before you finish, and paste the real output in your report.

## Reference material (read what your task needs)

| File | What it proves |
|---|---|
| `docs/captures/recon-rat-5g.md` | `+CPSI` emits a second `NR5G_NSA` record; EN-DC shape |
| `docs/captures/recon-detail-metrics.md` | devinfo store fields, the metric-by-metric table |
| `docs/captures/recon-cellular-info.md` | CCAINFO field 9 = SINR×10; RSSI −32..−39 |
| `docs/captures/recon-sms.md` | `/data/sms/sms_read` grammar, 17 real rows |
| `docs/captures/recon-apn.md` | `+CGPADDR` field layout; active-CID bug |
| `docs/captures/recon-distance-mimo.md` | TA µs→index factor; rank=MIMO layers |
| `docs/captures/recon-time-and-logs.md` | NTP/TZ state, log catalogue |
| `deploy-x16/README.md` | what the payload is and why each file exists |
