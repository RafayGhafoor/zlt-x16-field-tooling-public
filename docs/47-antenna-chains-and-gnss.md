# 47 — The 8 antennas, and where a GNSS position would come from

**Date:** 2026-10-29 · **Device:** X16, `zlt-root`, uptime 5 h, EN-DC **not** active
during these checks · **Questions:** (1) the ODU is specified with 8 antennas but the
UI reports 4; (2) can we get real-time coordinates?

Short answers: **(1) nothing is missing — the 8 are 4 LTE + 4 NR5G chains, and the
NR half only exists while NR is aggregated** (it is not, today). **(2) the GNSS chain
starts and runs, but no fix was obtained in 3 minutes here**, and the reason is
assistance/sky-view, not software.

---

## 1. Antennas: 4 chains per RAT, 8 with NR up

### What the modem reports

SIMCom exposes per-chain measurements for **four ports per RAT**, and a separate row
for each RAT actually in use:

```
$ /bin/atcmd 'AT+CRSRP?'          # 2026-10-29, no NR leg
+CRSRP: LTE,-73,-72,-75,-75
$ /bin/atcmd 'AT+CRSSI?'
+CRSSI: LTE,-41,-41,-44,-43
```

versus the [26](26-antenna-stats-on-x16.md) capture from **2026-10-26**, when the unit
was EN-DC:

```
+CRSRP: LTE,-96,-98,-90,-90
+CRSRP: NR5G,-75,-76,-81,-76      <- the other four chains
+CSINR: LTE,8,0,8,8
+CSINR: NR5G,22,20,13,20
```

The values differ per RAT, so both rows are genuine measurements — not the LTE numbers
repeated. **8 chains = 4 LTE + 4 NR5G.** With NR released (today) only 4 exist to
report, and the UI is right to show 4.

Whether the hardware has eight physical elements or four dual-band elements feeding
both RATs is a datasheet question; what software can say is that the modem measures at
most four chains per RAT, so a "missing antenna" is not hiding in a parser.

### Why the UI shows what it shows

The path is complete end to end, and it already carries both halves:

| Layer | LTE | NR5G |
|---|---|---|
| shim (`deploy-x16/atcli_smd11`) | `AT+CRSRP?` → `+QRSRP: v0..v3,LTE` | same reply, re-emitted as `+QRSRP: v0..v3,NR5G` |
| parser (`parse_at.sh` `parse_qrsrp/qsrq/qsinr`) | `sig_lte_rsrp/rsrq/sinr` | `sig_nr_rsrp/rsrq/sinr` |
| poller (`qmanager_poller:2930`) | `signal_per_antenna.lte_rsrp …` | `signal_per_antenna.nr_rsrp …` |
| UI (`components/.../antenna-statistics.tsx:31-32`) | `<TechCard prefix="lte">` | `<TechCard prefix="nr">` |

So the page renders **two cards** — four ports each. When NR is up you see 8 values;
when it is not, the NR card shows the parser's `-32768` sentinel as
`antenna_statistics.port.not_reported`. That is correct behaviour, but it is also why
"only 4 antennas" is the honest reading of the screen: the other four are the NR chains
and they are inactive, not unreported.

If the expectation is "8 numbers always", the fix is not in the antenna code — it is to
show the NR card's ports with their *last* values plus an "NR not aggregated" label, or
to hide the card entirely. That is a UI decision, not a data problem.

### A trap found while checking: `AT+CSINR?` can hang

```
$ timeout -s KILL 12 /bin/atcmd 'AT+CSINR?'
Killed                                  # no reply in 12 s
```

`AT+CSINR?` is in the shim's allowlist and is what the antenna page's SINR card asks
for. `at_fetch` runs it under `timeout`, so a hang costs the shim's timeout once, then
the command is blacklisted for the rest of the boot ([38](38-atcmd-daemon-internals.md)
§3) — the page degrades instead of wedging, but the first load after a boot can stall.
It answered normally in the 2026-10-26 capture, so this is state-dependent (no NR leg
today), the same class as `AT+CFUN?`. Not changed here; recorded so the next person
does not chase a "broken SINR card".

## 2. GNSS: what exists, what we measured

### The stack is present and running

| Piece | State |
|---|---|
| `/usr/bin/simcom_gnss` (38 KB) | the vendor's GNSS daemon |
| `simcom-gnss.service` | **active (running) 5 h 04 m**, `Restart=always`; `is-enabled` says *disabled* only because the enable symlink lives in `/lib/systemd/system/multi-user.target.wants/` — the AGENTS §6 trap |
| `/usr/bin/atfwd_daemon` | the AT-forward daemon it talks to (the only two binaries referencing the location sockets) |
| `/dev/socket/data/www/socket_atfwd_location_file` | bound by `simcom_gnss` (mode 0777) |
| `/dev/socket/data/www/socket_location_atfwd_file` | the atfwd side of the pair |
| `/usr/bin/example_gnss` (9.6 KB) | **SIMCom's own SDK demo, shipped in the image** — it links `Sunsea_Gnss_*` |
| `libolinterface` | 13 `Sunsea_Gnss_*` exports incl. `GetGnssLocationInfo`, `AddRxIndMsgHandler`, `Set_Indications` |

Two side notes that saved time later: the publish socket is **not** an HTTP endpoint
(`curl --unix-socket` returns nothing), and the request socket does not exist until a
client creates it — so there is no passive "cat the position" path.

### What we can drive today, and what came back

`example_gnss` is interactive (`12` = set indication mask, then a mask value; `1` =
start; `2` = stop; `99` = exit; a stray empty line is needed because it mixes `scanf`
and `fgets`). Driven through that sequence, on the unit:

```
diag:successfully connected to socket 4
gnss init success
addrxindmsghandle success!!
set indications success!!
gnss start success!!
gnss stop!!
```

**`gnss start success!!`** is the modem accepting a GNSS session — the whole chain
works: SDK client → QMI/AT path → engine.

No position followed, in a 60 s and then a 180 s window:

```
$ scripts/gnss-probe/gnss-probe.sh --seconds 60
== no position in 60s
  the engine DID start (session accepted) — so this is a visibility/assistance ...
```

Two facts explain that without inventing a bug:

- **no assistance data has ever been downloaded**: `/data/localxtra.bin` is absent, so
  this engine had never been started before today. A cold start with no XTRA and no
  almanac is minutes, not seconds;
- **a GNSS receiver needs sky**. This ODU is a mast-mounted CPE, but the unit is being
  driven remotely from a lab; nothing in software can compensate for a roof.

### Why not QMI LOC

The modem serves service `0x10`, and our transport reaches it (1 ms round trip), but
the firmware implements only a stub of it — measured with
`qmi-probe raw 0x10 <msg>`:

```
0x0020…0x0023  -> missing-arg        (4 messages, all requiring TLVs)
0x0024…0x0030  -> error 0x0039       (not implemented)
```

That matches how the vendor built it: `simcom_gnss` drives GNSS with **AT commands
forwarded through `atfwd_daemon`** (`+CGPSXD`, `+QGPS`, `open_nmea_port`, NMEA), and
`Sunsea_Gnss_*` wraps that. So QMI LOC is a dead end here; the SDK is the road.

### Routes, ranked

| Route | Cost | Notes |
|---|---|---|
| **SDK client** (`dlopen libolinterface`, `Sunsea_Gnss_Init` + `Set_Indications` + indication handler) | a small helper, same shape as [`../router-fix/voip-bridge/x16-audio.c`](../router-fix/voip-bridge/x16-audio.c) | recommended; `example_gnss` is the working reference for the call sequence |
| SDK demo driven by script | done — [`../scripts/gnss-probe/`](../scripts/gnss-probe/) | proves the chain, not production-grade (interactive, one session at a time) |
| atfwd socket protocol | unknown framing; only `atfwd_daemon` speaks it | would mean reverse-engineering a private protocol to reach a daemon that already exists |
| QMI LOC | — | not viable, see above |
| AT `+CGPSXD`/`+QGPS` directly | — | avoid: `simcom_gnss` owns the session and this modem hangs on innocent queries (`AT+CSINR?` above) |

## 3. Turned off (2026-10-29, `router-fix/gnss-off/`)

Since the engine starts and never fixes, the daemon is now stopped, masked, and
re-stopped at every boot by a hook in `StartTZApp` — a boot hook rather than only
`systemctl mask`, because a mask is a unit file under `/etc/systemd/system` and this
firmware mounts `/etc` at ~10.6 s, *after* systemd has loaded units (AGENTS §4).

| | before | after |
|---|---|---|
| `simcom-gnss.service` | active (running), 5 h 04 m | inactive / **masked** |
| cost | 16 threads, 2964 kB RSS | gone |
| `/data/localxtra.bin` | absent (never started before) | absent |
| `atfwd.service` | active (pid 924) | **active, untouched** (its own unit; nothing `Requires` the GNSS one) |
| WAN / QManager | rmnet_data0 + poller/httpd up | unchanged |

**Boot-proven 2026-10-30 01:14** (a real reboot, `docs/captures/reboot-verify-20261030-0113.txt`):
`/data/log/zlt-gnss-off.log` contains

```
2026-10-30 01:14:32 simcom-gnss.service stopped at boot
```

i.e. the unit **did start** during boot even with the mask in place — the mask is a unit
file under `/etc/systemd/system`, and this firmware has already loaded its units by the
time that volume mounts (~10.6 s). The boot hook is what stopped it. That is exactly why
the module does not rely on `mask` alone, and it is now measured rather than argued: on a
strictly mask-only setup the daemon would be running right now.

Rollback: `cd router-fix/gnss-off && ./install.sh --uninstall`.

One leftover, harmless: `/dev/socket/data/www/socket_atfwd_location_file` stays in
`/dev/socket/data/www/` after the daemon exits (a socket file with no listener). It is
in `/dev`, so it goes away on the next boot anyway.

## 4. Reproduce

```sh
# the antenna half
/bin/atcmd 'AT+CRSRP?' ; /bin/atcmd 'AT+CRSSI?'     # one row per RAT in use
grep -n 'signal_per_antenna' qmanager/scripts/usr/bin/qmanager_poller
grep -n 'prefix="'           qmanager/components/cellular/antenna-statistics/antenna-statistics.tsx

# the GNSS half
systemctl status simcom-gnss.service | head -4          # running, enabled via /lib
scripts/gnss-probe/gnss-probe.sh --seconds 300 --collect /tmp/gnss.txt
qmi-probe raw 0x10 0x0023                               # the LOC stub, for the record
```
