# scripts/demo — run the UI locally, with data

The UI is a static export whose data comes from CGI shell scripts on the modem.
Opening `out/index.html` gives you a page that spins forever, because every
`/cgi-bin/...` fetch 404s. This harness serves the export **and** answers those
fetches, so the real components render with real shapes on your laptop — no device
in the loop, no hand-written mocks.

```sh
scripts/demo/capture-fixtures.sh                 # once per data refresh, needs the device
scripts/demo/demo_server.py <export-dir> 4174    # serves UI + fake backend
```

Then open <http://127.0.0.1:4174/> and log in with **any** password.

Two faces side by side (build them first — see `branding/README.md` in the
QManager tree):

```sh
NEXT_PUBLIC_ROUTER_BRAND=zlt QM_SRC=./qmanager deploy-x16/install.sh --build
cp -R deploy-x16/out /tmp/demo-zlt       2>/dev/null   # or: /tmp/qm-stage/www
python3 scripts/demo/demo_server.py /tmp/demo-zlt     4174   # ZLT
python3 scripts/demo/demo_server.py /tmp/demo-qmanager 4173 # canonical
```

## What is real and what is fake

| | |
|---|---|
| **Real** | every component, every token, every route, the brand layer, the JSON shapes |
| **Fake** | the numbers. They are one snapshot of the live ZLT X16, replayed |
| **Not fake** | *when* they were taken. Each response's epoch seconds are shifted by one shared delta (`now − max`), so the snapshot reads as "just now" and the *relative* ages inside it stay true. Without that, every card renders as stale — which is a different, wrong demo |

`auth/check.sh` always answers authenticated and `auth/login.sh` sets the
`qm_logged_in` indicator cookie the UI reads, so any password lands on the
dashboard. Nothing writes to a device.

## Fixtures

`capture-fixtures.sh` logs into the device, pulls each GET endpoint in its list and
streams the results back with a tar pipe (no scp — AGENTS.md §1). The file naming
(`public/overview.sh` → `public_overview.sh.json`, plus `…__cells24h.json` for a
queried variant) is shared with `demo_server.py`, so a new endpoint needs one line
in the list and nothing else.

**Fixtures are git-ignored.** They contain the device's real IMSI, ICCID and IMEI —
one SIM's identifiers, not lorem ipsum. Capture them on demand; do not commit them.
