# qmi-probe — read-only QMI over QRTR, with no libqmi

One static armv7 binary that speaks QMI to the modem's NAS/DMS services directly,
plus the host-side build. Read-only by construction: every subcommand is a GET.

Why it exists: `qmicli` (shipped in `qmanager/dependencies/qmi/`, used by
`qmanager/scripts/usr/lib/qmanager/qmi_read.sh`) covers four reads well, but

- it has **no command for the LTE/NR cell-lock GETs** (`strings qmicli | grep
  cell-lock` → 0 hits), so their support could only be *assumed*;
- every call costs a libgobject client fork: measured **58 ms mean / 100 ms max**
  per call on this box, against **12.5 ms mean / 20 ms max** for this binary
  (20 calls each, 2026-10-29). The QMI round trip *inside* a running process is
  1 ms; the rest is process start. A warm AT read via the shim is 32 ms, so this
  binary is ~2.6× faster than AT and takes no AT lock at all.

Nothing here writes a modem setting. Adding writes would mean EFS/NV risk
(`AGENTS.md` §5.2), and the one write worth having — LTE PCI lock — this firmware
refuses outright (below).

## Build and run

```sh
./build.sh                                  # -> out/qmi-probe (27 KB, static musl)
ZLT_HOST=zlt-root
ssh $ZLT_HOST 'cat > /tmp/qmi-probe && chmod +x /tmp/qmi-probe' < out/qmi-probe
ssh $ZLT_HOST '/tmp/qmi-probe ports'        # service -> qrtr node/port, then any command
```

`/tmp` is tmpfs, so the binary disappears on reboot — the right place for a probe.

| Command | QMI message | Returns |
|---|---|---|
| `ports` | QRTR nameservice | node/port for DMS (0x02) and NAS (0x03) |
| `caps` | DMS `0x0045` band capabilities | GSM/WCDMA mask, LTE mask + extended list, NR list |
| `ssp` | NAS `0x0034` system selection preference | mode pref, LTE/SA/NSA band masks, NR mode, change duration |
| `ca` | NAS `0x00AC` LTE CA info | PCC + each SCC: PCI, EARFCN, bandwidth, band, **activated/deactivated** |
| `cells` | NAS `0x0043` cell location info | serving + intra/inter neighbours |
| `cells-text` | NAS `0x0043`, qmicli-shaped | the same, for `qmi_read.sh` |
| `signal-text` | NAS `0x004F`, qmicli-shaped | serving LTE (+5G when real), for `qmi_read.sh` |
| `rf` | NAS `0x0031` RF band info | raw TLVs |
| `ltelock` / `ltelockfull` / `nrlock` | NAS `0x00D7` / `0x015A` / `0x010F` | current cell lock, or the modem's refusal |
| `raw <svc> <msg> [hex]` | anything | `result`/`error`, then every TLV as hex |

`QMI_DEBUG=1` prints the QRTR discovery steps and which control ABI answered.
Exit codes: `0` ok, `1` transport error, `2` usage, `3` the modem refused.

## The trap that costs an afternoon: the QRTR control ABI was renumbered

bunnylock's `cpp/qrtr.c` (the reason this program exists) uses the **Android
downstream** numbering. This vendor's 5.4.210 kernel uses the **mainline** one.
Sent with the wrong set the failure is silent and misleading — `ENODEV` ("no such
device") for the control port, `ECONNRESET` for a node that exists:

| | Android downstream (bunnylock) | mainline / this X16 |
|---|---|---|
| `QRTR_PORT_CTRL` | `2` | `0xFFFFFFFE` |
| `QRTR_TYPE_NEW_LOOKUP` | `5` | `10` |
| `QRTR_TYPE_NEW_SERVER` | `3` | `4` |

Confirmed by tracing the working `qmicli` with an `LD_PRELOAD` shim around
`sendto`/`getsockname`: it sends a 20-byte control packet with `cmd=10` to
`(local_node, 0xFFFFFFFE)` and then connects to what the reply names.
`qmi-probe` tries the modern set first and the legacy set second, and says which
one answered, so it keeps working on an Android-style or older kernel.

Three more facts the same trace settled (all are load-bearing here):

1. **The local node id cannot be assumed.** Kernel 5.4 has no `/sys/bus/qrtr`, so
   there is nothing to read it from; `getsockname()` on an *unbound* socket
   returns it (this unit: **2**, not the `1` Android uses). Binding with a node id
   that is not your own fails `EINVAL` (`net/qrtr/qrtr.c`: `addr->sq_node !=
   ipc->us.sq_node → -EINVAL`).
2. **Service ports are dynamic and per-service.** Discovered via the nameservice
   reply: on this box DMS is `node 3 port 68`, NAS is `node 3 port 55`. A naive
   "send the QMI message to node 3" does nothing without the port.
3. **No QMUX header on QRTR** and no "get client id" exchange: a connected QRTR
   socket *is* the client. The request on the wire was a bare 7-byte header
   (`u8 type=0, u16 txn, u16 msg_id, u16 body_len`) — which is why this binary
   needs neither `/dev/qcqmi` nor CAP_NET_ADMIN.

## Measured on the X16 (2026-10-29)

```
service 0x02 (DMS) -> qrtr://3 port 68      service 0x03 (NAS) -> qrtr://3 port 55
caps : reply=125 B, 1 ms      ssp : reply=369 B, 1 ms      ca : reply=165 B, 1 ms
```

- `caps` decoded **identically to `qmicli --dms-get-band-capabilities`**: LTE
  1,3,5,7,8,18,19,20,26,28,32,38,39,40,41,42,43 (+46,48 extended), NR
  1,3,5,7,8,20,26,28,38,40,41,48,77,78,79. This is the read `AGENTS.md` §6 lists
  as **not available over AT** ("the only query hangs") — see
  `docs/36-qmi-direct-probe.md` for the three-way comparison.
- `ssp` band mask bytes `15 00 00 08 20 01 00 00` decode to 1,3,5,28,38,41 —
  byte-identical to `AT+CSYSSEL="lte_band"` and to EFS `modem/mmode/lte_bandpref`.
- **Cell lock has no QMI path on this firmware.** `NAS 0x00D7` (LTE lock GET) and
  `NAS 0x010F` (NR lock GET) answer `0x5E not-supported`, `NAS 0x015A` (the
  full-EARFCN variant) answers `0x47`, three attempts each, consistently — while
  `AT+CCELLCFG?` still reads `+CCELLCFG: 0,0` (unlocked, as `docs/23` records).
  SIMCom put cell lock in the AT/vendor layer, not in QMI NAS, so no QMI writer
  should be built for it: the PCI-lock idea against the CID-6 flapping in
  `DIAGNOSIS.md` has to go through `AT+CCELLCFG`.
- `ca` decodes PCC (B3, PCI 256, EARFCN 1312, 20 MHz) and both SCCs with an
  explicit activation state. Successive reads showed SCC2 (B5, RSRP −71 dBm)
  flipping both ways (`deactivated → activated → deactivated`) while SCC1 (B1,
  RSRP −90 dBm) stayed up — live state, not a decoder artefact: the raw TLV bytes
  changed between calls. `AT+CCAINFO?` has no state field, so this is the only
  cheap way to see it.

## Using it as the QManager backend

`qmi_read.sh` prefers this binary when it is installed at
`${QM_ROOT:-/usrdata/qmanager}/bin/qmi-probe` or `/data/qmanager/bin/qmi-probe`,
and falls back to `qmicli` and then AT when it is not — so an older install keeps
working. Two subcommands exist only for that: `caps-text` and `ssp-text` print the
same lines `qmicli` prints, so the library keeps **one** parser per band list
instead of two.

Measured end-to-end through the library (2026-10-29): a capability+policy pair
costs ~2× less with the probe than with qmicli, and the win is mostly in
`qm_qmi_available` — the library's liveness check, which ran on every reader and
was itself a 58 ms qmicli call.

## Related

- `qmanager/docs/reference/qmi-transport.md` — the QMI-vs-AT contract and the
  cost model that motivates this.
- `qmanager/scripts/usr/lib/qmanager/qmi_read.sh` — the production read path
  (qmicli); this probe is a diagnostics complement, not a replacement.
- `scripts/efs-nv/` — the NV/EFS side, including the `zig cc -static -musl`
  cross-build recipe this `build.sh` follows.
