# 38 — Inside `atcmd_daemon`: the AT channel's actual source

**Date:** 2026-10-29 · **Device:** X16, `zlt-root` (uptime < 1 h, so
`/tmp/logs/ATCMD_DAEMON.log` is this boot's) · **Trigger:** decompiling the binary
that owns the only AT channel on this box, instead of continuing to infer its
behaviour from the outside.

Everything here is **read-only**. No AT command outside `AT`, no NV write, no
daemon restart. The two binaries analysed are vendor bytes already in
[`../firmware-analysis/`](../firmware-analysis/):

| Binary | Where | Why it matters |
|---|---|---|
| `atcmd_daemon` (30 KB, ARMv7 PIE, stripped, GCC 9.3) | `/bin/atcmd_daemon`, run from `/etc/initscripts/start_atcmd_daemon` | **the only holder of `/dev/smd8`**, i.e. the only thing that talks AT to the modem |
| `atcmd` (9.7 KB, same toolchain) | `/bin/atcmd` | the CLI every one of our tools (and QManager) drives |

Decompiled output is committed beside them, and every claim below has a line you
can read:
`firmware-analysis/atcmd_daemon.decomp.annotated.c` (4000 lines, 190 string
literals resolved) and `firmware-analysis/atcmd.decomp.annotated.c`.

> **How the artifacts were made** — [`../scripts/decompile/`](../scripts/decompile/).
> Ghidra headless (`DumpDecomp.java`) decompiles every function, then
> `annotate.py` resolves the ARM *literal-pool* string idiom that both Ghidra and
> r2ghidra print as arithmetic: the vendor toolchain builds PIC, so a string is
> `ldr r1,[pc,#x]` + `add r1,pc` and the decompiler shows `DAT_000141e4 + 0x13ede`
> instead of the literal. `./decompile.sh <binary>` reproduces both dumps.
> Line numbers in the daemon's own log confirm the match byte-for-byte: the
> current firmware writes `atcmdd_send_atcmd, 871` and the decompiled call is
> `savelog(0, …, "atcmdd_send_atcmd", 0x367, …)` — `0x367` = 871 **[M]**.

---

## 1. The two ports (and one that does not exist)

`main` opens, in this order ([`main` @ 0x13dc0](../firmware-analysis/atcmd_daemon.decomp.annotated.c)):

| fd | node | mode | when |
|---|---|---|---|
| 5 | **`/dev/smd8`** | `O_RDWR` | always, retried once a second forever |
| 6 | **`/dev/smd9`** | `O_RDONLY` | only if cfg item `SYS_VOLTE_SW` is `"1"`, then a `read_tty_thread` is started |

Measured on the live daemon **[M]**:

```
$ ls -l /proc/$(pgrep -f '^atcmd_daemon$')/fd
lr-x  6 -> /dev/smd9          # indications, read-only
lrwx  5 -> /dev/smd8          # AT commands + their responses, read/write
lrwx  4 -> /tmp/logs/ATCMD_DAEMON.log
```

So the single AT channel is `smd8`, and there is a *second*, dedicated
**indication** stream on `smd9`. This corrects the "the X16 has no AT character
device" line in [05](05-the-at-problem.md) — it has several; what it does not have is
one we may open (`crw-rw-r-- radio:radio` and the daemon already holds it).

### The indication thread cannot recover

`read_tty_thread` handles a read error by calling a helper that closes the fd and
loops `usleep(100 ms); open(<path>, O_RDWR)` **forever**. That helper opens
**`/dev/smd3`** ([`FUN_00013b90`](../firmware-analysis/atcmd_daemon.decomp.annotated.c)):

```c
path = "/dev/smd3";
do { usleep(100000); iVar1 = open(path, 2); } while (iVar1 < 0);
```

`/dev/smd3` **does not exist on this unit** — the full list is
`smd7 smd8 smd9 smd10 smd11 smd21 smd22 smd38 smdcntl0 smdcntl1 smdcntl8` **[M]**.
One bad read on the indication port therefore parks that thread in a 10 Hz
`open()` loop for the rest of the boot: URCs (call state, SMS delivery, USSD)
stop arriving while `AT` commands keep working — which presents as "the UI still
polls fine but the call/sms features have gone deaf". No recovery short of
restarting the daemon. This is a vendor bug, not ours, and it is *silent*
(the spin does not log).

## 2. The bus message, from both ends

`atcmd_daemon` calls `init_sockmsg(5, …)` — app id **5** = `APP_ID_ATCMD` — and
`/bin/atcmd` connects to **`/tmp/.sockmsg/atcmd_daemon`**, then binds
**`/tmp/.tmpsock/atcmd`** to receive the answer. Both sides agree on this
`0x1014`-byte struct (**[E]** client `main`, daemon `FUN_00011d00`), which is
`tSOCK_MSG` from the bus library — the vendor's own field names are in the DWARF,
and [39](39-sockmsg-bus.md) has them with the full app-id table:

```c
typedef struct {              /* tSOCK_MSG / tMSG, 0x1014 bytes */
    int       id;             /* 0x0000 */
    eMSG_TYPE type;           /* 0x0004  0 = unicast, 1 = broadcast */
    int       len;            /* 0x0008 */
    char      data[4096];     /* 0x000c  the AT payload, below */
    eAPP_ID   srcId;          /* 0x100c  set by the library */
    eAPP_ID   dstId;          /* 0x1010  set by the library */
} tMSG;
```

The AT payload inside `data` — offsets here are **absolute** (i.e. `data` starts at
`0x0c`), and relative to `data` in brackets:

| abs | in `data` | field | request (`/bin/atcmd`) | reply (daemon) |
|---|---|---|---|---|
| `0x00` | — | `id` | **`0xea60`** (see the reply rule below) | echoed |
| `0x04` | — | `type` | `0` = unicast · `1` = broadcast | `0` |
| `0x08` | — | `len` | `0x1004` | **`0x1000`** |
| `0x0c` | `+0x00` | magic | **`0xabcd`** | `0xabcd` |
| `0x10` | `+0x04` | `at_id` | `0` from `/bin/atcmd`; the library's own helper randomises `% 59999`; the daemon echoes it | echoed |
| `0x14` | `+0x08` | `timeout_second` | **15** | `0` |
| `0x18` | `+0x0c` | `atcmd_len` | `strlen(cmd)` | `strlen(resp)` |
| `0x1c` | `+0x10` | `atcmd[]` | the command, **no `\r` needed** | the response text |
| `0x100c` | — | `srcId` | `0` from `atcmd` | — |
| `0x1010` | — | `dstId` | **5** = `APP_ID_ATCMD` | — |

Three details worth having written down, because we had been guessing at all of
them:

- **`id` chooses the reply transport, and that is why the CLI is special.** `id ==
  0xea60` (60000) is the value `/bin/atcmd` uses; for that id the daemon does
  **not** answer on the bus at all — it opens a *raw* unix socket to the fixed path
  `/tmp/.tmpsock/atcmd` and writes the text there (`send_response_to_atcmd`, with a
  5 × 100 ms connect retry), so every CLI caller needs no registered app id. Any
  other `id` (e.g. `0xabcd`, which the library's own unused helper uses) gets a
  normal `tMSG` reply on the bus to `srcId`.
- the length field distinguishes the two directions (`0x1004` request,
  `0x1000` reply), and `FUN_00012e5c` uses `*pMsg == 0xea60` to pick the AT path.
- `atcmd`'s reply socket path is **fixed**: it `unlink()`s and re-`bind()`s
  `/tmp/.tmpsock/atcmd` on *every* invocation, then `listen(1)`/`accept(1)`. Two
  concurrent `atcmd` calls cannot both work — the second steals the path. That is
  the decompiled form of the serialisation warning in [34](34-at-shim-cost.md), and
  the `5 × 100 ms` retry above is the only slack in it.

## 3. What one request costs the channel

`atcmdd_send_atcmd` (0x1291c) is the whole lifecycle, and it is **serialised by
construction**: one queue, one worker, one fd.

1. **queue** — `atcmdd_create_queue_hdl(0x3c, …)`: at most **60** pending nodes.
   Past that the daemon logs `queue_hdl is full` and rejects.
2. **timeout** — clamped, not trusted:
   `t = pMsg->timeout_second; if (t < 1) t = 3; else if (t > 0x3b) t = 0x3c;`
   → **3…60 s**, and that `t` becomes the `select()` tv_sec.
3. **write** — appends `\r\n` unless the command already contains `\r`,
   then `safe_write()`; on a write error it reopens `smd8` and retries.
4. **read** — `select()` then `safe_read()`, which loops until it sees `\r\nOK\r\n`
   or `ERROR`, re-synchronising the echo. Its failure modes are logged as
   `atcmd[%s] at_read[%s] not correspond correctly, try recursive again`
   (recursion bounded at 4: `dislocation count greater than four`).
5. **oversize** — if the response does not fit the caller's buffer it is written
   to **`/tmp/.atcmd_daemon_transfer`** and the client gets
   `%s\r\nATCMD_DAEMON_FILE_OK\r\n` instead of the text. *A client that does not
   know this sentinel will treat a big response as garbage.* (Threshold: 0xf8c =
   3980 bytes.)

Consequences we can now state as fact rather than inference: a wedged command
holds the channel for at most ~60 s, but **every queued caller pays its own
timeout behind it** — 60 nodes × their timeouts is why `AT+CLAC` looked like an
eternal hang in [05](05-the-at-problem.md) / [33](33-antenna-controllability.md)
even though no single wait is unbounded.

## 4. Two pseudo-AT commands that never reach the modem

This is the part worth the decompilation. `atcmdd_send_atcmd` inspects the
command text **before** writing it to `smd8` and rewrites two of them.

### 4.1 `AT+MODULE_SN` — an NV write exposed as an AT command

The check is on the first 12 bytes, case-insensitive (`+0x20` per byte):

```c
pbVar9 = cmd - 1; pbVar6 = "AT+MODULE_SN";        // 0x5494
do { if (*++pbVar9 != *++pbVar6 && *pbVar9 - *pbVar6 != 0x20) goto send_raw; }
while (pbVar9 != cmd + 0xb);
FUN_000127f8(cmd, buf, 0x100);                    // set_module_sn_atcmd
```

`set_module_sn_atcmd` takes the payload from `cmd + 0xd` (or `+0xe` if it is
quoted), requires **exactly 15 characters**, hex-encodes each byte (`%2X`) and
emits

```
AT+CNVW=2497,0,"<30 hex chars>\r\n"
```

i.e. **NV item 2497**, written as 15 raw bytes. This is now **confirmed by
measurement** ([42](42-vendor-at-surface.md) §1): the dialer reads the same item
with `AT+CNVR=2497,0`, and on this unit it answers
`4D5030363234303335334244423043…` = **`<module-sn-redacted>`** — 15 characters, exactly
the length this function demands. So NV 2497 *is* the module serial number, and it
has a read counterpart. Which means:

- `AT+MODULE_SN="0123456789ABCDE"` **writes** that NV slot through the same
  unauthenticated channel as `AT` — use `AT+CNVR=2497,0` if you only want to read it;
- the pseudo-command has **no read form**: any 15-character payload is a write.
  Treat `AT+MODULE_SN` as device-provisioning-only, and back up EFS first
  (`scripts/efs-nv/backup.sh --raw`) if it is ever needed;
- a shorter payload is rejected with `sn length incorrect` and an **empty**
  command is handed to the modem, which then just times out.

Not tried on the device: writing NV 2497 to see what breaks. The instruction is
enough.

### 4.2 `AT+TOZEDSMS<number>,<text>` — the SMS manager's private path

When the command contains `AT+TOZEDSMS`, the daemon does not forward it. It
`strtok_r`s the argument list on `,`, drops the first **12 characters** of field
0 (that is the `AT+TOZEDSMS` prefix), and builds

```
AT+CMGS=<field0+12>\r\n        then waits for '>'
<field1>                       the body
+CMGS: / +CMS ERROR            read back and returned
```

So the live syntax is `AT+TOZEDSMS+923001234567,hello` — prefix and number
concatenated, comma, then the text. It exists because the vendor SMS manager
(`tz_sms_mgr` → `sms_evt_cb` → `/tmp/.tmpsock/atcmd`) needed a way to send an
SMS body without driving the `>` prompt itself. Usable, documented nowhere, and
one more thing that a compromised local process can do quietly.

## 5. The three commands the vendor itself flags

`atcmdd_send_atcmd` logs at level **0** (always) for exactly three patterns
(**[M]**, seen live as line `871`):

```
AT+CNETCI=38        (strcmp, exact)
AT+CNWSEARCH="lte"  (strcmp, exact)
AT+CFUN=…           (strstr)
```

That is a list of the commands this firmware's authors found worth watching —
and it matches what we know: `CFUN` is what QManager issues to bounce the modem
(the current log has `AT+CFUN=4` then `AT+CFUN=1` at 17:53:14/15) and
`CNWSEARCH` is the blocking network scan. Practical use: **`grep 'Received AT
cmd' /tmp/logs/ATCMD_DAEMON.log` is a cheap audit of every modem reset and every
network scan**, whoever issued it, on a device where journald does not persist.

Note the asymmetry: the pattern is `AT+CFUN=` (a **write**), because a write is what
bounces the modem. The *query* `AT+CFUN?` is not in this list and is not usable — it
**hangs** on this firmware ([AGENTS](../AGENTS.md) §6, killed at 20 s with no reply),
same class as `AT+CSYSSEL=?`. Read the functional mode from `AT+CPSI?`/`AT+CEREG?` or
QMI instead ([42](42-vendor-at-surface.md) §3, [36](36-qmi-direct-probe.md)).

## 6. USSD and call indications are exchanged through `/tmp` files

`vcall_evt_cb` (0x122e4) is the modem-callback for USSD/call notifications. It
gates on cfg `SYS_USSD_SW`, hex-encodes the payload four nibbles per character
(`%04x` per char) and then communicates entirely through fixed paths:

| path | direction | content |
|---|---|---|
| `/tmp/.ussd_ret` | daemon → whoever | the last USSD response, hex-encoded |
| `/tmp/.ussd_need_reply` | daemon → whoever | `0` / `1` / `2` = the reply state the handler expects |
| `/tmp/.ussd_last_time_need_reply` | daemon | touched on `notification_type == 2`, removed on `3` |

and sets the flag `USSD_HAD_RET`. The function's own debug prints are the
literal strings `simcom_CUSD_handler cmd_echo 0/1/2`, which is what the vendor's
`CUSD` (USSD) handling is called. Nobody authenticates these files, and `/tmp` is
tmpfs (`/tmp/logs` — including `ATCMD_DAEMON.log` — is wiped at boot, consistent
with [17](17-backups-and-restore.md)).

## 7. How indications get to the UI

`read_tty_thread` reads up to 8 KB from `smd9`, splits it on `\r\n\r\n` (falling
back to a single `\r\n`), and hands each frame to `atind_task_perform`, which
validates that the frame starts and ends with CRLF and then sends
`proxy_sockmsg_send_common_msg(6, 0x19, msg)` — **app id 6 = `APP_ID_ATIND`,
message `0x19`**, header `0x1010 / 0 / 0x1000 / 0xabcd`. So URC consumers are a
*broadcast* listener, not request/response clients. Anything wanting
`RING`/`+CMTI`/`+CUSD` must subscribe like `APP_ID_ATIND` does, or scrape `/tmp`.

The strings `deco text:` / `deco failed: did't match any start symbol` are the
legacy names for this framing step — there is **no encryption** in
`atcmd_daemon`; `libmdlencrypt.so` is linked but no symbol from it is imported.

## 8. Security notes (all [E], none exploited)

The design assumes every bus and file participant is trusted. On this box it is
not a strong assumption, but the boundaries are worth naming:

| Surface | Property |
|---|---|
| sockmsg app 5 / `/tmp/.tmpsock/atcmd` | **no authentication and no caller check**; `flags == 1` (broadcast) is the only early-out. Any process that can reach the socket gets root's AT privilege — that includes `AT+MODULE_SN` (§4.1) and arbitrary SMS (§4.2) |
| `/tmp/.atcmd_daemon_transfer` | fixed path, written root-owned, **read back by clients**; on a world-writable `/tmp` this is a classic symlink target |
| `/tmp/.ussd_ret`, `/tmp/.ussd_need_reply` | same shape, and they *steer* the USSD reply state |
| buffer handling | `safe_read` copies the modem's answer with `SIGPIPE`/bounds logging; the file-transfer branch is the only place a length is not re-checked against the caller's buffer, which is why it exists |

Nothing here is exploitable by a remote web request on its own; it matters
because every CGI in the vendor UI runs as root and several of them shell out.

## 9. What is still unread / what has since been read

Since this page was written, the three follow-ups it listed have been done:

| Target | Result |
|---|---|
| `libmdlsockmsg.so` (the bus this page calls into) | [39](39-sockmsg-bus.md) — the `tMSG` definition with the vendor's field names, all 55 app ids, the socket layout |
| `libolinterface.so` (SMS/USSD manager `Sunsea_Basic_Init` registers with) | [40](40-simcom-sdk-interface.md) — it is the **SIMCom SDK**: 83 QMI-facing entry points, and USSD arrives as a *voice-call* indication, not over AT |
| `libmdlencrypt.so` | [41](41-vendor-crypto-lib.md) — nothing in the AT/QMI path is encrypted; the `deco` naming here is framing, not crypto |
| `/bin/dialer` AT layer | [42](42-vendor-at-surface.md) — the full vendor AT surface, the `CNVR`/`CNVW`/`CNV` NV family, and `AT+CFAILUREMGRCFG?` (the reboot policy) |

Still open: `libmdlbase.so` (the `osm_requester` layer under `libolinterface`), and
whatever consumer owns the `groups` pseudo-app id (3) — nothing on the box binds it.

## 10. Reproduce

```sh
scripts/decompile/decompile.sh firmware-analysis/atcmd_daemon atcmd_daemon 122e4
scripts/decompile/decompile.sh firmware-analysis/atcmd atcmd
```

`122e4` is a *forced* function entry point: Ghidra will not create it on its own
because the ARM literal pool of the preceding function looks like data, and that
is exactly where `vcall_evt_cb` lives. If a future binary shows a `/* DECOMPILE
FAILED */` or a suspiciously short function, look for the pool between two
`push {…, lr}` and pass its end as `EXTRA_FUNCS`.

Cross-check the result against the running daemon before trusting it:

```sh
ssh zlt-root 'ls -l /proc/$(pgrep -f "^atcmd_daemon$")/fd; tail -5 /tmp/logs/ATCMD_DAEMON.log'
```

The log carries `(function, line)` for every entry, so a decompiled `savelog`
call site resolves to the same pair — that is what proved this dump matches the
shipped firmware rather than a nearby build.
