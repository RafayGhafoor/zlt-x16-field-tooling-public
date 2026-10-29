# 39 — The `sockmsg` bus: every app id, every socket, the message layout

**Date:** 2026-10-29 · **Device:** X16, `zlt-root` · **Subject:**
`/lib/libmdlsockmsg.so` (72 916 B, BuildID `4aed89b1…`, **not stripped, DWARF
present**) — the IPC library every vendor daemon on this box links against.

This is the layer under [38](38-atcmd-daemon-internals.md): the daemon's
"app id 5 / app id 6" and the "0x1014-byte message" are this library's public
structs, and the library's DWARF still carries them **with the vendor's own field
names**. Everything marked **[E]** below is read out of the binary (symbols,
`.debug_info`, decompilation); **[M]** is measured on the running unit.

Decompiled, annotated: `firmware-analysis/libmdlsockmsg.decomp{,.annotated}.c`.
Tool: [`../scripts/decompile/`](../scripts/decompile/).

---

## 1. Provenance (from `.debug_info`)

```
/home/tzsoft/sunsea-x62/tozed/tzproc/mdllibs/libsockmsg/sockmsg.h
/home/tzsoft/sunsea-x62/tozed/tzproc/mdllibs/libsockmsg/{sockmsg.c,sockmsg_atcmd.c,sockmsg_industry.c}
```

So: vendor **Tozed** ("tz"), product codename **sunsea-x62**, built on Qualcomm's
SDX62/SDX65 LE12 stack. (The SIMCom SDK library in [40](40-simcom-sdk-interface.md)
carries the sibling path `/home/zxs/SDX65_LE12/AP_KZ_230313/…` — same build tree,
2023-03-13.) The "industry" in `sockmsg_industry.c` is the carrier-customised
variant.

## 2. The message, with the vendor's field names

From `DW_TAG_structure_type tSOCK_MSG` (byte_size **4116 = 0x1014**, declared
`sockmsg.h:0x8d`) **[E]**:

```c
typedef enum { MSG_TYPE_COMMON = 0, MSG_TYPE_BROADCAST = 1 } eMSG_TYPE;

typedef struct {                    /* tSOCK_MSG, 0x1014 bytes */
    int       id;         /* 0x0000  message id            */
    eMSG_TYPE type;       /* 0x0004  0 = unicast, 1 = broadcast */
    int       len;        /* 0x0008  0x1004 request, 0x1000 reply */
    char      data[4096]; /* 0x000c  payload               */
    eAPP_ID   srcId;      /* 0x100c  set by the library    */
    eAPP_ID   dstId;      /* 0x1010  set by the library    */
} tSOCK_MSG;
typedef tSOCK_MSG tMSG;                       /* sockmsg.h:0x94 */
typedef int (*msg_callback_pfn)(tMSG *);      /* sockmsg.h:0x98 */
```

`srcId`/`dstId` are **written by the library**, not the caller — `sockmsg_send_common_msg()`
stamps them before the write, which is why [38](38-atcmd-daemon-internals.md) §2
found them at fixed offsets from the sender's side.

### The AT payload inside `data`

Both ends agree, and the library's own `sockmsg_server_send()` spells it out
**[E]** (`tMsg.data[0] = -0x33; tMsg.data[1] = -0x55` = `0xABCD` little-endian,
`data[4] = rand() % 59999`, `data[8] = …`, `data[0xc] = strlen(atcmd)`,
`data[0x10] = atcmd`):

| `data` offset | abs | field | live value |
|---|---|---|---|
| `+0x00` | `0x00c` | `u32 magic` | `0x0000ABCD` |
| `+0x04` | `0x010` | `int at_id` | `/bin/atcmd` sends `0`; the library's helper randomises mod 59999; the daemon echoes it |
| `+0x08` | `0x014` | `int timeout_second` | `/bin/atcmd` sends **15**; the daemon clamps 3…60 |
| `+0x0c` | `0x018` | `int atcmd_len` | `strlen(cmd)` |
| `+0x10` | `0x01c` | `char atcmd[]` | the command, no trailing `\r` needed |

`id` chooses the **reply transport**, which is the non-obvious part:

| `id` | who sends it | where the answer goes |
|---|---|---|
| `0xea60` (60000) | `/bin/atcmd` (the CLI) | a **raw unix socket** at the fixed path `/tmp/.tmpsock/atcmd` — not the bus |
| anything else (the library helper uses `0xabcd`) | daemons | the bus, to `srcId`, via `sockmsg_send_common_msg()` |

So `atcmd_daemon`'s two reply paths are one `switch`: CLI clients get a
connect-and-write to a well-known path (5 × 100 ms retries), bus clients get a
normal `tMSG`. That is why `/bin/atcmd` must bind first and why two concurrent
`atcmd` runs collide on that path (both were observed in [34](34-at-shim-cost.md);
the unlink-then-bind is in the client, the retry budget in the daemon).

## 3. Every app id on the box

`eAPP_ID` from DWARF (authoritative names/values, `APP_ID_MAX = 55`) crossed with
`app_items[]` in `.rodata` at `0x2008` (55 × `tAPP_ITEM{int appId; char name[100];}`,
stride `0x68`) — **the string is the socket filename**, so this table is the
address book **[E]**:

| id | `eAPP_ID` | socket name `/tmp/.sockmsg/<name>` |
|---:|---|---|
| 0 | `APP_ID_COMMON1` | `common1` |
| 1 | `APP_ID_COMMON2` | `common2` |
| 2 | `APP_ID_BROADCAST` | `broadcast` |
| 3 | `APP_ID_GROUPS` | `groups` |
| 4 | `APP_ID_DIALER` | `dialer` |
| 5 | `APP_ID_ATCMD` | `atcmd_daemon` |
| 6 | `APP_ID_ATIND` | `atind` |
| 7 | `APP_ID_HTTP_CGI` | `http_cgi` |
| 8 | `APP_ID_LED_DAEMON` | `ledctrl_daemon` |
| 9 | `APP_ID_CONFIGTOOLS` | `configtools` |
| 10 | `APP_ID_MACINFOTEST` | `msg_sender` |
| 11 | `APP_ID_IDU_CMD` | `idu_cmd` |
| 12 | `APP_ID_NETCWMPD` | `netcwmpd` |
| 13 | `APP_ID_GPIOD` | `gpiod` |
| 14 | `APP_ID_SOCKMSG_SEND` | `sockmsg_send` |
| 15 | `APP_ID_ATCMD_TOOL` | `atcmd_tool` |
| 16 | `APP_ID_UPGRADE` | `upgrade` |
| 17 | `APP_ID_EXTERNAL` | `external` |
| 18 | `APP_ID_EXTERNAL_TZ_MGR` | `external_tz_mgr` |
| 19 | `APP_ID_FIREWALLTOOL` | `firewalltool` |
| 20 | `APP_ID_FLOWCONTROL` | `flowcontrol` |
| 21 | `APP_ID_WAN_MONITOR` | `wanmonitor` |
| 22 | `APP_ID_LAN_MGR` | `lan_mgr` |
| 23 | `APP_ID_NET_MONITOR` | `net_monitor` |
| 24 | `APP_ID_WAN_MGR` | `wan_mgr` |
| 25 | `APP_ID_TZ_PHONE` | `tz_phone` |
| 26 | `APP_ID_BUTTON_EVENT` | `button_event` |
| 27 | `APP_ID_TZ_SMS_MGR` | `tz_sms_mgr` |
| 28 | `APP_ID_ANTENNASW` | `antennasw` |
| 29 | `APP_ID_FOTA` | `fota` |
| 30 | `APP_ID_PHONEBOOK` | `phonebook` |
| 31 | `APP_ID_TEMPERATURECTRL` | `temperature_ctrl` |
| 32 | `APP_ID_DEV_MGR` | `dev_mgr` |
| 33 | `APP_ID_TZ_LISTEN` | `tz_listen` |
| 34 | `APP_ID_CRON` | `cron_controller` |
| 35 | `APP_ID_VPN_MGR` | `vpn_mgr` |
| 36 | `APP_ID_TZUPDATE` | `tzupdate` |
| 37 | `APP_ID_POWER_MGR` | `power_mgr` |
| 38 | `APP_ID_TZKW_CMD` | `tzkw_cmd` |
| 39 | `APP_ID_UIS_PLATFORM` | `uis_platform` |
| 40 | `APP_ID_ANTENNA_TUNER` | `antenna_tuner` |
| 41 | `APP_ID_BT_CTRL` | `bt_ctrl` |
| 42 | `APP_ID_ATROUTER` | `atrouter` |
| 43 | `APP_ID_SMC` | `smc` |
| 44 | `APP_ID_CTIOT_MQTT` | `ctiot_mqtt` |
| 45 | `APP_ID_USB_MGR` | `usb_mgr` |
| 46 | `APP_ID_CHARGE_MGR` | `charge_mgr` |
| 47 | `APP_ID_GUI_MIFI` | `gui_mifi` |
| 48 | `APP_ID_ONECYBER_MQTT` | `onecyber_mqtt` |
| 49 | `APP_ID_JT808` | `jt808_app` |
| 50 | `APP_ID_TMCOMM` | `tmcomm` |
| 51 | `APP_ID_MPROC` | `mproc` |
| 52 | `APP_ID_LOGC` | `logc` |
| 53 | `APP_ID_VOIPCLIENT` | `voipclient` |
| 54 | `APP_ID_LPA_MGR` | `lpa_mgr` |
| 55 | `APP_ID_MAX` | — (sentinel; `init_sockmsg` rejects `>= 55`) |

Two of these matter to us immediately: **`APP_ID_ATCMD_TOOL` (15)** and
**`APP_ID_ATROUTER` (42)** are real, separate AT consumers — the "tool" and
"router" the daemon's `get_app_name_by_id()` calls were seen logging. And
`APP_ID_TZ_SMS_MGR` (27) is the SMS manager of [38](38-atcmd-daemon-internals.md) §4.2.

Note the two places where the enum name and the socket name disagree
(`10 MACINFOTEST`/`msg_sender`, `49 JT808`/`jt808_app`): the name table, not the
enum, decides the path.

## 4. The sockets on disk

`get_sock_full_path_by_filename(base, name, buf, size)` — **[E]**:

1. `mkdir(base, 0777)` if missing (default base `"/tmp"`);
2. `mkdir(base + "/.sockmsg/", 0777)`;
3. path = `base/.sockmsg/<app name>`; if it does not exist, create an **empty
   1-byte regular file** there (`write_file_data(path, "w+", 1, "f")`) so a
   sender's `access()` check succeeds even when the app is not running;
4. `strcpy_s(buf, size, path)`.

`init_sockmsg(appId, msg_cb, base_dir)` then does the usual dance on that path:
`unlink` → `socket(AF_UNIX, SOCK_STREAM)` → `bind` (`SUN_LEN` 110) → `listen(1)` →
`pthread_create(sockmsg_srv_thread)`. Exactly one pending connection; the server
thread `select()`s, `accept()`s, reads, and dispatches to your callback.

Measured state **[M]** — the placeholder-file trick is visible: apps that are not
running are 1-byte files, running ones are sockets.

```
$ ls -la /tmp/.sockmsg/
-rw-r--r-- 1 root root 1 ... antenna_tuner      <- placeholder, not running
srwxr-xr-x 1 root root 0 ... atcmd_daemon        <- running
srwxr-xr-x 1 root root 0 ... configtools         <- running
srwxr-xr-x 1 root root 0 ... dialer              <- running
...
```

**55 entries, no permissions: `drwxr-xr-x root root` with 0666-ish sockets.** Any
local process can `connect()` to any app's socket and speak `tMSG` — there is no
credential, no peer check, and `libmdlsockmsg` validates nothing (§6).

## 5. The API, and which parts are actually used

| Export | Semantics **[E]** |
|---|---|
| `init_sockmsg(appId, cb, base_dir)` | full duplex: bind + `listen(1)` + server thread, `cb(tMSG*)` per message |
| `init_sockmsg_one_way(appId, base_dir)` | registers the app id and base dir **only** — no socket, no thread. Push-only clients |
| `sockmsg_send_common_msg(dstId, pMsg)` | stamps `dstId` and this app's id into `srcId`, sends `0x1014` bytes |
| `proxy_sockmsg_send_common_msg(srcId, dstId, pMsg)` | same, but the caller forges `srcId` (used by `atind` fan-out) |
| `sockmsg_send_broadcast_msg(srcId, pMsg)` | **not a broadcast socket**: loops ids 0…54, skips its own, sends 54 unicasts 1 ms apart, returns the success count |
| `sockmsg_send_common_msg_group(dstId, pMsg, msg_num)` | `msg_num` messages to one dst |
| `libsockmsg_send_data_to_app_by_sock_path(path, data, size)` | lowest level: non-blocking `connect()` with **11 retries × 150 µs**, `write()`, `close()`. Reports short writes |
| `socket_set_recvtimeout(sock, ms)` | `SO_RCVTIMEO`; the only timeout primitive |
| `get_app_name_by_id(id)` | linear scan of `app_items`, 55 entries |
| `get_sock_full_path_by_filename(...)` | §4 |

**Dead on this firmware:** `sockmsg_send_single_atcmd(appId, timeout_s, cmd,
recv, recv_size)` and `sockmsg_send_single_dev_mgr(...)` — a synchronous
request/response helper with its own reply socket — are exported but **no binary
imports either** (checked every `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin` on the
unit **[M]**). Their enums survive in the DWARF:

```c
eAT_ID:        AT_ID_ATIND=0, AT_ID_AT=1, AT_ID_SPIMEI=2, AT_ID_CGCONTRDP=3
eATCMD_RESULT: OK=0, ERROR_MAGIC=1, ERROR_SIZE=2, ERROR_CODE=3, TIMEOUT=4
```

`AT_ID_SPIMEI` / `AT_ID_CGCONTRDP` show the vendor intended a typed AT call
surface ("write the IMEI", "read the PDP context") rather than a text pass-through;
what shipped is text. Nothing on the box uses the typed path.

`init_sockmsg_one_way` **is** used, by `configtools`, `dialer`, `flow_ctrl`,
`netcwmpd`, `sockmsg_send`, `tz_upgrade_client`, `tzupdate` **[M]** — i.e. the
daemons that only push.

## 6. What the library does *not* do

Worth stating plainly, because it defines the trust model of the whole box:

- **no authentication, no peer credential check** (`SO_PEERCRED` is not imported);
- **no validation** of `id`, `type`, `len` or `data` — the magic/`len == 0x1004`
  checks in `atcmd_daemon` ([38](38-atcmd-daemon-internals.md) §2) are that
  daemon's own, not the bus's;
- `len` is **not** used to bound the read; the receiver always gets `0x1014` bytes
  (`recv`/`read` of the full struct), so `len` is advisory;
- `listen(1)` + one accepting thread per app: a second concurrent sender blocks
  until the first is accepted (this is the mechanism behind
  [34](34-at-shim-cost.md)'s "serialisation is mandatory" — it is not politeness,
  it is a backlog of one);
- the broadcast loop **includes the pseudo-apps** `common1`, `common2`,
  `broadcast`, `groups`, which never have a listener.

For us the practical conclusions are: (a) `atcmd`'s fixed reply path is the only
way to get an AT answer, so AT calls must be serialised by *us*; (b) anything
running as any uid can inject `tMSG`s into `atcmd_daemon`, `dialer`,
`firewalltool` or `configtools`; (c) there is no versioning — the struct layout is
compiled into 40 binaries, so a mismatch is silent.

## 7. Reproduce

```sh
scripts/decompile/decompile.sh firmware-analysis/libmdlsockmsg.so libmdlsockmsg

# the app table, straight out of .rodata
python3 - <<'EOF'
import sys, struct; sys.path.insert(0,'scripts/decompile')
from annotate import Elf
e = Elf('firmware-analysis/libmdlsockmsg.so')
for i in range(56):
    off = 0x2008 + i*0x68
    print(i, struct.unpack('<I', e.read(off,4))[0], e.cstr(off+4, 0x64))
EOF

# the vendor's own struct/enum definitions
dwarfdump -i firmware-analysis/libmdlsockmsg.so | grep -A40 'DW_AT_name *tSOCK_MSG$'
dwarfdump -i firmware-analysis/libmdlsockmsg.so | grep -E 'DW_AT_name +APP_ID_' -A1
```
