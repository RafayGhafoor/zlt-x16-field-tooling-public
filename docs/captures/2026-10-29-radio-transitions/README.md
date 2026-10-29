# 2026-10-29 — radio transitions, 18 minutes at 1 Hz

Sanitised excerpt from `scripts/flap-meter` on the X16 (`zlt-root`), captured while
investigating the "it keeps switching bands" report. **Kept:** PCI / EARFCN / band /
EN-DC availability, which carry no subscriber data. **Not kept:** the vendor dialer
log the analyzer joins against (`/tmp/logs/DIALER.log`) — it stays on the device.

What it shows: the serving cell never moved (B3 / EARFCN 1312 / PCI 256 in every
STATE line) while the **B5 secondary carrier toggled activated↔deactivated every
10–45 s**, and B5's PCI flickered `469 → 477 → 469` inside one second. Later B1's
SCC dropped too, leaving B3 alone. So the visible "band flipping" is
carrier-aggregation churn, not reselection — and `AT+CCAINFO?` has no field that
can show it (`docs/36`, `scripts/flap-meter/README.md`).

Analysis of this file:

```sh
scripts/flap-meter/analyze.sh docs/captures/2026-10-29-radio-transitions/transitions-18m.log
```
