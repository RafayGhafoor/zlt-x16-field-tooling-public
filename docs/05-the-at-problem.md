# 05 — The AT problem (the crux of the port)

Everything else in this port is mechanical. This is the part that decides whether it works.

## The finding

**The X16 has no AT character device we may open.** The SIM8260E is on the same SDX65
die as the application CPU, so there is no USB/serial modem: `/bin/atcmd_daemon` holds
`/dev/smd8` (`crw-rw-r-- radio:radio`, opened at boot and retried until it succeeds) and
there is no `/dev/ttyUSB*`, `/dev/ttyACM*` or pty **[E]**.

> **Correction (2026-10-29).** Earlier revisions of this page said there is no `/dev/smd*`
at all. There are ten (`smd7`–`smd11`, `smd21`, `smd22`, `smd38`, `smdcntl0/1/8`), and the
daemon writes AT into `smd8` while reading indications from `smd9`. What is true — and what
this page is about — is that the AT channel is *owned*, so opening a node behind the
daemon's back interleaves with its multiplexer. Full port/message map:
>[38](38-atcmd-daemon-internals.md).

Vendor AT traffic is IPC:

```
dialer ── tATCMD_Request{magic 0xabcd, len 0x1014, rand at_id} ── sockmsg bus ──> APP_ID_ATCMD daemon
        └─ waits on pthread_cond_timedwait for tATCMD_Response with matching at_id
```

- `sunsea_send_at_with_format` @ `0x6558` in `/bin/dialer`, calling
  `sockmsg_send_common_msg(app_id=5, …)` through **`libmdlsockmsg.so`** (private vendor lib).
- Bus participants include `APP_ID_ATCMD`, **`APP_ID_ATCMD_TOOL`**, **`APP_ID_ATROUTER`**,
  `APP_ID_ATIND` — i.e. there is a *tool* consumer, not just the dialer.

## Why we cannot simply open a port

QManager's `atcli_smd11` shim relies on `AT_DEV` being a **raw character device** it can
`dd` into and out of. There is no such node. Writing to a guessed node would interleave with
the daemon's multiplexer.

## The reboot hazard (do not ignore)

`/bin/dialer` polls AT **once per second** (`AT+CSQ`, `AT+CEREG?`, `AT+CPSI?`, `AT+COPS?`,
`AT+CNWINFO?`, `AT+CGPADDR`, `AT+CGACT`, `AT+SPENGMD`). Its mutex is **per-process**, so it
does not protect the shared channel. Its failure path is:

> `Dialer reboot system cause AT send failed more than %d times`

**[I]** Injecting unsynchronised AT can therefore **reboot the router**, not just fail a
command. Any QManager AT transport must be either (a) the vendor's own serialised path, or
(b) off the AT channel entirely.

## `AT+CLAC` wedges the daemon (measured 2026-10-28)

The one command that is worse than "slow": `AT+CLAC` never terminates on this
unit and, once issued, `atcmd_daemon` stops answering **every** client. Verified
symptom: `/bin/atcmd 'AT'` blocks 40 s+ in `__skb_wait_for_more_packets`,
QManager's pollers all burn their 6 s `timeout`, and the call bridge logs
`AT broker quarantined: AT+CPAS exceeded 5s` / `ATH exceeded 8s` until it gives
up on call control. The dialer's own path keeps running (WAN, RSRP and devinfo
stayed live), so the wedge looks like "just QManager" until you try `atcmd`
by hand.

Fix (no reboot, dialer unaffected, ~1 s of AT downtime):

```sh
P=$(pgrep -f '^atcmd_daemon$'); kill -9 "$P"; sleep 0.3
setsid /etc/initscripts/start_atcmd_daemon start   # no unit supervises it
/bin/atcmd "AT"                                    # -> OK
```

Two corollaries: never issue `+CLAC` (its command list cannot be harvested this
way — enumerate the manual instead, see [04](04-simcom-at-mapping.md)), and always
bound `atcmd` with `timeout -s KILL`, because it ignores `SIGTERM` and a plain
`timeout` leaves the channel held. Antenna probes that hit this are in
[33](33-antenna-controllability.md).

## Options, ranked

### Option A — reuse the vendor AT entry point *(cheapest if it exists)*

Evidence there is one: the vendor UI's `main.js` carries `AT_CMD:{index:55,hideFlag:"0"}` —
an **enabled AT-command page** in this firmware — with a matching page name
`html/config/lteATConfig.html`, served by the single vendor CGI `/cgi-bin/http.cgi`.
So *something* on the device accepts an arbitrary AT string and returns the response, and it
is already serialised against the dialer.

Discover on device:
```sh
ls -l /bin /usr/sbin /usr/bin | grep -iE 'at|cmd'
grep -rl "lteATConfig" /  2>/dev/null | head
# then: what binary does the CGI call? trace it:
ls -l /proc/$(pidof -s TZApp || pidof -s httpd)/exe
```

If a CLI exists (`atcmd`, `at_tool`, `sendat`, `SIMCom_at`, …) the port is:
**`deploy/atcli_smd11` shim → call that CLI → print its response verbatim.** QManager then
runs unmodified. **This is the preferred path.**

### Option B — QMI over QRTR via `qmicli` *(proven on this exact unit)*

`DIAGNOSIS.md` records that a compatible ARM `qmicli` **plus its QRTR libraries were staged
on the router and used successfully** to drive Qualcomm PDC (loaded, activated and rolled
back MBN profiles by ID). `libqrtr.so.1` is already a dependency of `libolinterface.so.1.0.0`.

QMI gives, without touching the AT channel:
- `--dms-get-ids` (IMEI), `--dms-get-iccid`, `--dms-get-msisdn`, `--dms-get-model`,
  `--dms-get-firmware-preference`, `--dms-get-operating-mode`
- `--nas-get-serving-system` (registration, LAC/CI/TAC, roaming, RAT)
- `--nas-get-signal-info` / `--nas-get-signal-strength` (LTE/NR5G RSRP, RSRQ, SINR)
- `--nas-get-rf-band-info`, `--nas-network-scan`, `--nas-get-cell-location-info`
- `--nas-set-system-selection-preference` (mode + **LTE/NR band preference** = band locking)
- `--wds-get-profile-list`, `--wds-get-data-bearer-technology`, `--wds-get-packet-statistics`

Practical consequence: a **QMI-backed `qcmd` bridge** that answers the AT subset QManager
issues (`AT+CGMM/CGMR/CGSN/CIMI/CICCID/CPIN/COPS?/CEREG?/C5GREG?/CSQ/CESQ/CPSI/QENG/
CGCONTRDP/CGACT?`) would let all 87 CGIs — and `parse_at.sh` — run **unchanged**. That is the
safest way to get a working UI fast, and it never touches the dialer's channel.

Trade-off: it is an emulation layer, so responses are synthesised; anything we cannot source
honestly (CA per-CC rows, neighbours) must return a well-formed "unavailable" instead of a
plausible lie. QManager already has graceful-degradation patterns for exactly this
(`phy_metrics.sh:31-32`).

### Option C — speak `sockmsg` ourselves *(last resort)*

Write a small C client against `libmdlsockmsg.so` (`init_sockmsg`, `sockmsg_send_common_msg`)
with the request struct recovered from the disassembly (`magic 0xabcd`, `len 0x1014`,
`at_id` random, app id 5). Struct/type names come from `atcmd_daemon_msg_define.h`, which we
do not have. High effort, undocumented, and it still competes with the dialer on the same
serialised channel.

### Explicitly rejected

- Opening `/dev/ttyUSB*`/`/dev/smd*` — does not exist.
- Driving `engpc` (`/mnt/data/engpc.ini`, `AT+` over QXDM bridge) — it is the vendor's diag
  bridge; using it means restarting `engpc-init` and fighting the dialer for it.
- Polling `AT+COPS=?` / `AT+QSCAN`-style long commands on a shared channel — they block and
  are aborted by any other byte.

## Decision rule

> Try A for 30 minutes of device time. If no usable AT entry point exists, build B.
> Do not start C.

Either way, QManager's poll cadence must stay **≥ 3 s** and must never issue a long/blocking
command, because the dialer is depending on the same resource every second.
