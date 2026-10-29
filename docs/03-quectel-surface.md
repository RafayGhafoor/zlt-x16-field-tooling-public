# 03 — Quectel-specific surface (what must move)

Full report: [raw/scout-02-quectel-surface.md](raw/scout-02-quectel-surface.md)

Census: **1055** `AT+` occurrences in source (472 in `scripts/`, 115 in `app/components`,
26 in `constants/at-commands.ts`). One transport, one lock, one device node.

## Command census (production paths only)

| Feature | Command | Sites | SIM8260E equivalent | Difficulty |
|---|---|---|---|---|
| Serving cell / signal | `AT+QENG="servingcell"` | 165 | `AT+CPSI?` (+`CESQ`) | **hard** — 300-line `+QENG:` awk rewrite |
| Carrier aggregation | `AT+QCAINFO` | 169 | `AT+CCAINFO?` (undocumented) | **hard** / possibly unavailable |
| Operator | `AT+COPS?`, `AT+QSPN` | 174 / 8 | `COPS` survives; `QSPN` → parse `+COPS` name | easy |
| Band lock | `AT+QNWPREFCFG` | 112 | `AT+CSYSSEL="lte_band",1:3:…` (colon list) | **hard** — encoding change |
| Frequency lock | `AT+QNWCFG="lte_earfcn_lock"` | 158 | `AT+CCELLCFG` (PCI+freq only) | **hard** / drop |
| Tower lock | `AT+QNWLOCK` | 103 | `AT+CCELLCFG` / `AT+C5GCELLCFG` (manual: "not verified, do not use") | **hard** |
| APN / PDP | `CGDCONT`, `CGCONTRDP`, `CGACT` (**survive**) + `AT+QICSGP` (38) | 72/80/25 | `QICSGP` → `AT+CGAUTH` | medium |
| Cells / neighbours | `AT+QSCAN`, `QENG="neighbourcell"` | 36 | **none** (only `+SPNCELLSCAN`, undocumented) | **hard** / drop |
| SIM slot / detect | `AT+QUIMSLOT` (53), `QSIMSTAT`, `QSIMDET` | — | **none** | **hard** — remove dual-SIM failover |
| SMS | `CMGF/CMGS/CPMS/CMGL/CMGD` | 35 (CPMS) | survive | easy |
| IMEI | `AT+CGSN` survives; `AT+EGMR=1,7` | 14/15 | `AT+SIMEI=` | easy |
| MBN | `AT+QMBNCFG` | 14 | `AT+CMCFG="list"/"autoselect"/"deactive"` | medium |
| Temperature | `AT+QTEMP` | 31 | already falls back to sysfs | trivial |
| Version | `AT+CVERSION` (no SIMCom) | 13 | `AT+CGMR` | easy |
| Data counter | none — reads `/proc/net/dev` on **`rmnet_ipa0`** | — | **same iface name on X16** | none |
| IP passthrough | `/usr/bin/ql_qmap` | 52 | **none** | drop |
| TTL/MTL | `iptables -o rmnet+ -j TTL/HL` | — | `rmnet+` matches X16; **`xt_HL` availability unknown** | easy/medium |
| PHY deep metrics | `QNWCFG` subsets + `ubus call modemd status` | — | none (degrade gracefully — pattern already exists) | drop |

**Commands QManager does NOT use** (do not port them): `QNWINFO`, `QCSQ`, `CESQ`, `CLAC`,
`CSIM`, `CCHO`, `CGLA`, `QDSIM`, `QETH`, `QPOWD`, `QINDCFG`, `CUSD`, `CCLK`.

## Transport

| Layer | File | Contract |
|---|---|---|
| Gatekeeper | `scripts/usr/bin/qcmd` | `qcmd "AT+…"` → payload+`OK` on stdout; `qcmd -j` → JSON; flock `/tmp/qmanager_at.lock`; 1 s poll loop because busybox `flock` lacks `-w` |
| Shim | `deploy/atcli_smd11` | *shell script*, not a binary. One command in `$1`, raw text out, **always exit 0**. Assumes a **raw char device, not a tty** (`stty`/`read -t` do not work) |
| Rust broker | `native/qmanager_atd` | `DEFAULT_AT_DEV`, unix socket, same terminator list (`OK`/`ERROR`/`+CME ERROR`/`BUSY`/…) — **portable**, one file to port (`channel.rs`) |

**Single-channel assumption is load-bearing**: one lock file, one device, one mutex across
`qcmd`, `sms_tool` and `qmanager_atd`.

## Native binaries

| File | Reality | Source in tree? |
|---|---|---|
| `deploy/atcli_smd11` | POSIX **shell** | yes (it *is* the source) |
| `deploy/sms_tool` | POSIX **shell wrapper** around `sms_tool.bin` | yes |
| `dependencies/atcli_smd11` | static ARM ELF, stripped | **no** (upstream `1alessandro1/atcli_rust`) |
| `dependencies/sms_tool` | static ARM ELF, stripped | **no** (upstream `obsy/sms_tool`; patch in tree) |
| `dependencies/qmi/{qmicli,libqmi-glib,libqrtr-glib}` | dynamic armhf ELF | **yes, committed** |
| `dependencies/smartdns` | ELF | no |

## Entware / `/opt`

136 occurrences (`/opt/bin` 20, `/opt/sbin` 19, `opkg` 15, `timeout` 13, `jq` 6, …).
The X16 has no `/opt` and cannot bootstrap Entware → all of it must be replaced by the
payload `bin/` prefix (as `deploy/qm_pathfix.sh` already does for `/usrdata`).
