# 36 — Talking QMI to the modem directly (and what it says about bands, CA and cell lock)

**Date:** 2026-10-29 · **Device:** X16, `zlt-root`, uptime <1 h, SIM8260E,
serving B3 PCI 256 EARFCN 1312 · **Trigger:** reading `github.com/btsearch/bunnylock`,
an Android band/cell-lock app whose QMI layer is the only part that concerns us.

Everything below is **read-only**. No band, RAT, PLMN or cell-lock write was
issued, and none is proposed by this doc.

---

## 1. What was already here, and what was missing

QManager already has a QMI read path (`qmanager/scripts/usr/lib/qmanager/qmi_read.sh`
→ `qmicli` 1.34 + private `libqmi-glib`/`libqrtr-glib`, `qmanager/dependencies/qmi/`).
It covers neighbours, signal, registration and RF band info. bunnylock's value was
everything *else* QMI can answer:

| Capability | AT today | Our qmicli 1.34 | bunnylock's raw QMI |
|---|---|---|---|
| band capability (what the module can do) | **unreadable** — the only query hangs (`AGENTS.md` §6) | `--dms-get-band-capabilities` | `DMS 0x0045` |
| band/RAT preference (what it will do) | `AT+CSYSSEL="lte_band"`, colon string, **can truncate** (`AGENTS.md` §6) | `--nas-get-system-selection-preference` | `NAS 0x0034` |
| LTE CA incl. activation state | `AT+CCAINFO?` — no state field | `--nas-get-lte-cphy-ca-info` | `NAS 0x00AC` |
| LTE / NR cell-lock read | `AT+CCELLCFG?` (docs/23) | **no command** | `NAS 0x00D7` / `0x015A` / `0x010F` |
| modem reboot, PS attach/detach | `/bin/dialer` restart | `--dms-set-operating-mode` | `NAS 0x0023`, `DMS 0x002E` |

To test the missing column without libqmi, `scripts/qmi-probe/` was written:
27 KB of static armv7 C, GET-only (`AGENTS.md` module conventions; build recipe
follows `scripts/efs-nv/build.sh`).

## 2. The portable finding: this kernel uses the *mainline* QRTR control ABI

bunnylock's `cpp/qrtr.c` hard-codes the **Android downstream** numbers. Copied to
this box verbatim, it fails with `ENODEV` for the control port and `ECONNRESET`
for a live node — a wrong-ABI error that looks like "no modem".

| | Android downstream (bunnylock) | mainline / this X16 kernel |
|---|---|---|
| `QRTR_PORT_CTRL` | `2` | `0xFFFFFFFE` |
| `QRTR_TYPE_NEW_LOOKUP` | `5` | `10` |
| `QRTR_TYPE_NEW_SERVER` | `3` | `4` |

Settled by `LD_PRELOAD`-ing a `sendto`/`getsockname` shim around the *working*
`qmicli`, which showed exactly one 20-byte control packet per run: `cmd=10` to
`(local_node, 0xFFFFFFFE)`. Three more facts the same trace gave:

- **The local node id is 2 here, not 1.** It cannot be assumed: kernel 5.4 has no
  `/sys/bus/qrtr`, so `getsockname()` on an unbound socket is the only source.
  Binding a node id that is not your own fails `EINVAL`
  (`net/qrtr/qrtr.c`: `addr->sq_node != ipc->us.sq_node → -EINVAL`).
- **Service ports are dynamic, per service, and reachable only through the
  nameservice reply**: NAS is `qrtr://3 port 55`, DMS is `qrtr://3 port 68`.
- **No QMUX header on QRTR, and no "get client id" exchange** — a connected
  socket is the client. The wire request was a bare 7 bytes. No `/dev/qcqmi`, no
  `CAP_NET_ADMIN`, and QCMAP/dialer are untouched by any of it.

## 3. Results

```
service 0x02 (DMS) -> qrtr://3 port 68     service 0x03 (NAS) -> qrtr://3 port 55
caps 125 B / 1 ms      ssp 369 B / 1 ms      ca 165 B / 1 ms     <- the QMI round trip
```

Those 1 ms figures are the **QMI transaction inside a running process**, not what a
shell pays. End-to-end on the device (2026-10-29, 20 calls each, back-to-back on a
box at load ~3.5, `/proc/uptime` deltas):

| Path | mean | max |
|---|---|---|
| AT via the shim (`AT+CSYSSEL=?` for capability) | 32.5 ms | 60 ms |
| `qmicli --dms-get-band-capabilities` | 58.0 ms | 100 ms |
| `qmi-probe caps` | **12.5 ms** | **20 ms** |

So the honest claim is narrower than "QMI is faster": **`qmicli` is slower than a
warm AT read** (58 vs 32 ms) because it links libgobject. Our own probe is the fast
one. For the boot-time capability read that difference is irrelevant (once per
boot, then cached) — what justifies moving it is that it takes **no AT lock** and
cannot hit the `AT+CSYSSEL=?` hang, and that a QMI band mask cannot truncate.

**3.1 Band policy now has four independent sources, and they agree.**

| Source | LTE bands |
|---|---|
| EFS `modem/mmode/lte_bandpref` (`docs/33-modem-nv-and-ul-capability.md`) | 1,3,5,28,38,41 |
| `AT+CSYSSEL="lte_band"` (measured today) | `1:3:5:28:38:41` |
| QMI SSP TLV `0x15` = `15 00 00 08 20 01 00 00` (today) | 1,3,5,28,38,41 |
| QMI SSP extended TLV `0x23` (today) | 1,3,5,28,38,41; all bytes 8–31 zero |

The QMI read returns a mask, so the `AT+CSYSSEL` truncation artefact documented in
`AGENTS.md` §6 cannot occur on this path — and both values still agree, which
means the truncated reads seen earlier were indeed artefacts, not policy.

**3.2 Capability vs policy — B8 was never a policy omission.**

`DMS 0x0045` (capability) vs `NAS 0x0034` (policy):

```
LTE capable : 1 3 5 7 8 18 19 20 26 28 32 38 39 40 41 42 43 (+46, 48 extended)
LTE policy  : 1 3 5 28 38 41
NR capable  : 1 3 5 7 8 20 26 28 38 40 41 48 77 78 79
NR SA/NSA   : 1 8 40 41 78            NR mode TLV 0x2B = 1  (SA disabled)
mode pref   : 0x0050 = LTE | NR5G
```

This is the first read of the capability set on this unit that did not depend on
the QManager status JSON. It removes the last ambiguity from `docs/33`: B8, 7, 20,
26, 32, 39, 42, 43 are **capable but not permitted** — a policy question (`SSP`,
EFS), not a hardware one. `NR mode = 1` matches `AT+CSYSSEL="nr5g_disable",1` and
`docs/23`'s NR-SA refusal: the modem is NR-NSA-only as configured.

**3.3 CA now reports activation state, which AT does not expose.**

| | `AT+CCAINFO?` | QMI `NAS 0x00AC` |
|---|---|---|
| PCC | `EUTRAN_BAND3,1312,100,256,-73,…` | B3, PCI 256, EARFCN 1312, 20000 kHz |
| SCC1 | `EUTRAN_BAND1,150,50,502,2,-90,…` | B1, PCI 502, EARFCN 150, 10000 kHz, **activated** |
| SCC2 | `EUTRAN_BAND5,2450,50,469,1,-71,…` | B5, PCI 469, EARFCN 2450, 10000 kHz, **activated** |
| state field | none (AT's 5th SCC field tracks it, unverified) | explicit `state` per carrier |

Values agree with `+CPSI` (PCI 256, B3, EARFCN 1312; RSRP field 12 = −733 → −73.3 dBm).
Successive reads caught SCC2 (B5, RSRP −71 dBm) flipping **both ways**
(`deactivated → activated → deactivated` within minutes) while SCC1 (B1, RSRP
−90 dBm) stayed up: **the modem holds the weaker B1 SCC and adds/drops the stronger
B5 SCC opportunistically.** That is live state, not a decoder artefact — the same
raw TLV bytes changed value between calls. Invisible over AT, so worth carrying into
the CA/antenna work (`docs/26`, `docs/33`).

**3.4 Cell lock: the QMI path does not exist on this firmware.**

`NAS 0x00D7` (LTE lock GET) and `NAS 0x010F` (NR lock GET) answer
`0x5E not-supported`; `NAS 0x015A` (full-EARFCN readback) answers `0x47`. Three
attempts each, consistent. Meanwhile `AT+CCELLCFG?` → `+CCELLCFG: 0,0` (unlocked),
exactly as `docs/23` records.

So the two transports tell a coherent story: **SIMCom implemented cell lock in the
AT/vendor layer, not in QMI NAS.** The consequence for us is a saved workstream —
there is no QMI cell-lock writer to build, and the PCI-lock idea against the CID-6
flapping in `DIAGNOSIS.md` would have to go through `AT+CCELLCFG` (already mapped in
`docs/23`), with the same reboot/rollback discipline.


### The 1 Hz reads: neighbours and signal

`qm_qmi_neighbours` and `qm_qmi_signal` prefer the probe too (`cells-text`,
`signal-text`), same qmicli-shaped text, so the existing awk parses both. Measured
on the X16 (2026-10-29, 10 ticks each, sampler paused, load ~4):

| one live tick (neighbours + signal) | mean |
|---|---|
| qmicli backend | 367–682 ms |
| probe backend | 225–317 ms |

~1.7× cheaper at that point, and the reason was that `qm_qmi_signal` still made
**one** qmicli call for `--nas-get-serving-system`. That is now `reg-text` (NAS
`0x0024`), so the whole tick is probe-backed — no libgobject fork per second at
all. Re-measured with it in place (10 ticks each, load ~6, so absolutes are
inflated; the ratio is the signal):

| one live tick (neighbours + signal + registration) | mean |
|---|---|
| qmicli backend | 998–1182 ms |
| probe backend | 357–416 ms |

~2.5–3×. The remaining cost is process start (three static-binary forks plus the
library's own forks), not the modem.

Two facts found by doing it, both worth keeping:

- **Signal info is NAS `0x004F`, not `0x0051`** (which this modem refuses with
  error `0x47`), and LTE lives in TLV `0x14` with `{i8 rssi, i8 rsrq, i16 rsrp,
  i16 snr}`. 5G is TLV `0x17` (`rsrp, snr`) — and it is always present with the
  `0x8000` "not available" sentinel, so presence alone does not mean 5G was
  measured. Printing it raw produced an RSRP of −3276.8 dBm that the library
  dutifully reported as a number.
- **Push the library through the installer, or apply its patch.** The deployed
  `qmi_read.sh` carries `deploy-x16/qmi_read_ld_library_path.patch` (the ash trap
  where `VAR=val func` does not reach the function's children — `platform.sh`
  defines `qm_timeout` as a function). A hand push of the plain repo file breaks
  **every** qmicli call with status 3 while the probe path keeps working, because
  the probe is static and needs no `LD_LIBRARY_PATH`. That looks like "the probe
  is faster" and is really "qmicli is broken".

## 4. What this changes

0. **The poller's capability read is QMI-first, verified and deployed.** The block
   in `scripts/usr/bin/qmanager_poller` calls `qm_qmi_capability_lines`, falls
   back to `qcmd_exec 'AT+QNWPREFCFG="ue_capability_band"'`, and logs which
   answered. `qmi_read.sh` backs it with `qm_qmi_capability_lines` (DMS 0x0045),
   `qm_qmi_policy_lines` (NAS 0x0034, the read that cannot truncate) and a
   probe → qmicli → AT backend order.

   It was withheld for one round because the poller restarted every ~40 s with it
   in place. That was **not the change**: `bash -x` showed it dying at
   `. /usr/lib/qmanager/parse_at.sh` → `exit 1` before reaching the block, because
   an ad-hoc `sed` of `/usrdata` is not what `deploy-x16/qm_pathfix_x16.sh` does.
   The deploy rewrites **three** patterns — `/usr/lib/qmanager` → `$QM_ROOT/lib`,
   `/usrdata/qmanager` → `$QM_ROOT`, `/usrdata` → `/data` — and missing the first
   one leaves a poller that cannot load its own libraries. Push payload files
   through the installer, or apply all three.

   Verified after the full rewrite: `bash -x` trace shows `bands_via=qmi` with no
   AT fallback and the trace ending in its steady-state loop (killed by `timeout`
   after 80 s, exit 143, i.e. still running); deployed, the unit stayed `active`
   for 6 × 12 s with the cache rewritten to the same three lists; the previous
   file is at `/data/zlt-backups/20261029/qmi-bands/qmanager_poller.pre-wiring`.

1. **Nothing gets rewritten.** `qmi_read.sh`/`qmicli` stays the production read
   path; `qmi-probe` is a diagnostics complement (and a 1 ms alternative for
   anything the poller wants to read twice a second on a 1-core box).
2. **Band capability is now readable** — the `AGENTS.md` §6 "not readable over AT"
   gap has a working answer that needs no AT channel, no `atcmd` timeout, and no
   dependency on QManager's JSON.
3. **No QMI write path will be built.** Cell lock is refused by the modem's NAS
   server; band/RAT/PLMN SSP writes exist in QMI but duplicate a working AT path
   at the cost of EFS/NV risk (`AGENTS.md` §5.2, rule 4).
4. **CA activation state is available cheaply** and is the first measurement that
   shows the SCC preference order on this unit.

## 5. Reproduce

```sh
cd scripts/qmi-probe && ./build.sh
ssh zlt-root 'cat > /tmp/qmi-probe && chmod +x /tmp/qmi-probe' < out/qmi-probe
ssh zlt-root '/tmp/qmi-probe ports; /tmp/qmi-probe caps; /tmp/qmi-probe ssp; /tmp/qmi-probe ca'
ssh zlt-root '/tmp/qmi-probe ltelock; /tmp/qmi-probe nrlock'     # expect 0x5E
```

`QMI_DEBUG=1` shows the discovery steps and which control ABI answered. See
`scripts/qmi-probe/README.md` for the message/TLV reference.
