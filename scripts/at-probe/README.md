# scripts/at-probe — the read-only AT/NV reads nothing else exposes

Host-side, `ZLT_HOST`-parameterised, and **read-only**: every command is a query sent
through `/bin/atcmd` (the vendor's serialised client) under `timeout -s KILL`, so it
cannot wedge the shared AT channel the way a raw write can. Nothing here writes NV,
config or `/data`.

```sh
./at-probe.sh sn                     # module serial number  (AT+CNVR=2497,0)
./at-probe.sh reboot                 # modem reboot policy + counters
./at-probe.sh nv 2497                # NV by number          (AT+CNVR=)
./at-probe.sh nv --path /nv/item_files/modem/mmode/lte_bandpref
./at-probe.sh health                 # no AT at all: fd table, bus dir, guard log
./at-probe.sh all
```

## What each one is for

| Command | Source | Why it matters |
|---|---|---|
| `sn` | `AT+CNVR=2497,0` → 15 bytes, hex in the reply | The module SN. It is the item `atcmd_daemon`'s `AT+MODULE_SN` **writes** with `AT+CNVW=2497,0`, so this is the safe read for a value only writable through an unauthenticated path (`docs/42` §1, `docs/38` §4.1). Nothing in the tree surfaced it before. |
| `reboot` | `AT+CFAILUREMGRCFG?`, `AT+CBACKUPRESULT`, `AT+CRESTORECOUNT` | The modem's own failure/reboot policy — the thing `docs/29` could only infer from behaviour. Field order is undocumented, so it prints raw. |
| `nv` | `AT+CNVR=<item>,0` and `AT+CNV=<efs-path>,0` | A **third** independent source beside `scripts/efs-nv` (DIAG) and `scripts/qmi-probe` (QMI). Our band/capability claims rest on sources agreeing (`docs/33`, `docs/36`); this adds one with no cross-compiled tool. |
| `health` | `/proc/<pid>/fd`, `/tmp/logs/ATCMD_DAEMON.log`, `/tmp/.sockmsg` | Whether the indication stream is alive (`/dev/smd9` fd), what the vendor itself logged, and which vendor daemons are actually up (socket vs 1-byte placeholder) — `docs/38` §1, `docs/39` §4. |

## Two things it decodes for you

- **NV hex → text.** The SN comes back as hex of the raw bytes with `0x00` padding;
  `sn` prints both, and strips the padding.
- **The `atcmd_receive:` echo.** `/bin/atcmd` prints it on its own line before the
  payload. This script drops it — and separates ssh's stderr while doing so, because
  `2>&1` used to fold ssh's host-key/post-quantum warnings into line 1 and make every
  "is this the echo line?" test look at the wrong line.

## Traps it respects

- `AT+CFUN?`, `AT+CLAC`, `AT+CSYSSEL=?` are **never** issued (they hang; `AGENTS.md` §6).
- No command here is on the do-not-touch list (`CNVW` writes, `AT+SPIMEI`, `AT+CLCK`,
  `AT+CPWD`) — `docs/42` §3 lists those so nobody has to rediscover them.
- `timeout -s KILL`, never a plain `timeout`: `atcmd` ignores `SIGTERM` and a plain
  timeout leaves the channel held.
