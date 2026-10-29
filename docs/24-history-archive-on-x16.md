# 24 — Why the History tab was blank on the X16

## Symptom and proof

The cellular History page requests:

```
GET /cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh?view=cells&range=24h
```

The CGI returned HTTP 200 / `success:true`, but `window.samples` was `0`,
`series.rsrp` was empty, and the timeline/availability arrays were empty. This
was not a browser range-selector problem: the backend had no durable archive
rows to serve.

Before the fix:

| Device | Archive directory | `ubus call modemd status` capability | History result |
|---|---|---|---|
| X16 | `/data/qmanager/metrics/` — **0 CSV files** | `/usr/bin/ubus` missing; `qm_phy_available` returned unavailable | `samples: 0` |
| GreenPacket O5A | `/usrdata/qmanager/metrics/2026-10-26.csv` — 122 lines at capture time | `/usr/bin/ubus` present; `modemd` read succeeded | `samples: 1080` in the requested 24h window |

The X16 still had the short-lived `/tmp/qmanager_signal_history.json` and
`/tmp/qmanager_ping_history.json` rings, but the new History tab reads the
30-day durable day-file archive under `metrics/`. Those `/tmp` rings are not the
source for the cell-history page and are lost at reboot.

## Root cause

`qmanager_poller::poll_tier3()` gates its optional PHY reader on
`qm_phy_available()`, which makes a real `ubus call modemd status`. The X16 has
no `ubus` or `modemd`; the helper correctly returned unavailable. The poller
then left both optional results (`md` and `at`) empty and returned before
calling `qm_phy_archive_row()`.

That gate was too broad for this hardware. X16 Tier 1 already has real serving
cell measurements and identity in the poller's `ctx` (`LTE`, RSRP/RSRQ/RSSI,
PCI, EARFCN, band, cell ID, plus system metrics). Optional CQI/MCS/beam fields
can be null without throwing away the measurements that the History page can
truthfully display.

## Fix

`phy_metrics.sh` now exposes `qm_phy_archive_has_source(md, at, ctx)`. It allows
a context-only row only when the poller has a real LTE/NR metric or cell identity;
it still refuses to archive a row made entirely of nulls. `poll_tier3()` uses
that test instead of requiring the optional QMI/modemd PHY source. When the
normal Tier 1 `network_type` is `LTE`, it records `nr_avail=0` as the measured
LTE-only state rather than writing an unknown value.

The History endpoint is unchanged in its meaning: absent PHY fields remain null,
not fabricated. The X16 archive gains one CSV sample roughly every 75 seconds
while the modem is attached and the Tier 1 context is populated. After a reboot
the history starts with a short span and grows; `/data/qmanager/metrics/` is
persistent across reboot.

## Verification

After deploying the poller + library and restarting **only** `qmanager-poller`
(no dialer/QCMAP restart), `/data/qmanager/metrics/2026-10-26.csv` was created
with its schema row and the first live sample. The same History CGI then returned:

```json
{"success":true,"view":"cells","range":"24h","window":{"samples":1},"series":{"rsrp":[{"v":-94}]},"cells":{"timeline":[...]}}
```

The on-device capture `docs/captures/2026-10-26-qmanager-broken/history-after-fix.json`
contains only the summarized response (no subscriber or raw historical data).
`tests/unit_history_archive.sh` exercises the source predicate, production CSV
writer, and the History CGI against a deterministic one-row fixture. The full
read-only endpoint smoke suite also passes after deployment.

:::warning
The X16 had only just rebooted when the first row appeared. A 24h chart will
initially cover only the time since that reboot; it is not possible to recreate
samples that were never archived. Subsequent Tier-3 samples fill the history
window naturally.
:::
