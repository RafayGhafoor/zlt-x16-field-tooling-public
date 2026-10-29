# RECON — SMS: why QManager is slow and blank, and the vendor store that answers

**Device:** ZLT X16 `192.168.3.1` (sdxlemur, ARMv7 1 core, kernel 5.4.210), uptime 6 h 44 m.
**Date of capture:** 2026-10-26, 15:28–15:45 device time (UTC+5).
**Mode:** read-only. No service was stopped, no file outside `/tmp` was written, no
QManager/device configuration was changed. Two AT commands were issued under
`timeout` (see §3) plus one `AT+CMGF=1` (transient, not persisted). Probe scripts
written under `/tmp` (tmpfs) were deleted afterwards. A QManager web session was
created for measurement (`POST /cgi-bin/quecmanager/auth/login.sh`, 1 h TTL).
**Caveat that colours every number below:** the box was under 100 % CPU with load
average 4.7 → 12.1 the whole time, because *other parallel recon agents were
running `grep -rl` over `/bin /usr /firmware /data`* (visible in `top`). Timing
was therefore taken in two windows (load ~4.7 and load ~12) and both are reported.

---

## 1. Reproduced symptom

```
$ ssh zlt-root   # QManager session cookie obtained first
$ /usr/bin/time -f "wall=%e" curl -s -m 120 -b "$C" \
    http://127.0.0.1:8080/cgi-bin/quecmanager/cellular/sms.sh
```

| run | load | wall |
|---|---|---|
| 1 | 4.7 | **7.42 s** |
| 2 | 4.7 | **6.08 s** |
| 3 | 4.7 | **13.35 s** |
| 4 | 4.7 | **7.39 s** |
| 5 | 4.7 | **10.03 s** |
| 6 | 12.0 | **12.03 s** |
| 7 | 12.0 | **10.72 s** |
| 8 | 12.1 | **15.14 s** |

Body, all eight runs identical (222 bytes):

```json
{
  "success": true,
  "source": "modem",
  "messages": [],
  "storage": { "used": 0, "total": 265,
               "me": { "used": 0, "total": 255 },
               "sm": { "used": 0, "total": 10 } }
}
```

So: **6–15 s per page load and zero messages**, while the stock UI on
`127.0.0.1:80` lists 17 messages *with bodies* instantly.

---

## 2. Why QManager is slow (measured, structural — load-independent)

The X16 deployment replaces the upstream `sms_tool` binary with a shell shim
(`deploy-x16/sms_tool`, installed as `/data/qmanager/bin/sms_tool`) whose
`recv` action does **no AT at all** and prints `{"msg":[]}`. The CGI, however,
still runs its full storage-routing dance around it. Per GET
(`scripts/www/cgi-bin/quecmanager/cellular/sms.sh`, deployed copy
`/data/qmanager/www/cgi-bin/quecmanager/cellular/sms.sh`):

| # | What | Evidence |
|---|---|---|
| 1 | tries the O5A sqlite store `/data/turin/mifi_config.sqlite` → absent, `sqlite3` absent → falls through | `sms.sh:78-79`, `169-190`, `480`; `ls -la /data/turin/…` → *No such file*, `command -v sqlite3` → none |
| 2 | `sms_locked at 'AT+CPMS="ME","ME","ME"'` (real AT) | `sms.sh:504` |
| 3 | `sms_locked -s ME recv -j` (shim: no AT, instant) | `sms.sh:508` |
| 4 | `sms_locked -s SM recv -j` (shim: no AT, instant) | `sms.sh:528` |
| 5 | `sms_locked -s ME status` (real AT `AT+CPMS=`) | `sms.sh:600` |
| 6 | `sms_locked -s SM status` (real AT `AT+CPMS=`) | `sms.sh:606` |
| 7 | `sms_locked at 'AT+CPMS="ME","ME","ME"'` again (real AT) | `sms.sh:618` |
| — | ~13 `jq` forks building/validating JSON | `sms.sh:480-620` |

Each of steps 2–7 goes through `sms_locked()` → `flock_wait()`
(`sms.sh:91-111`, `113-135`), which polls `flock -x -n` on
`/tmp/qmanager_at.lock` **with a `sleep 1` between attempts**. That is the
load-independent cost: one collision costs a whole second, six times over.

Measured components:

| Measurement | Command | Result |
|---|---|---|
| one real AT round-trip | `/usr/bin/time /data/qmanager/bin/sms_tool at 'AT+CPMS="ME","ME","ME"'` | **0.36 / 0.37 / 0.31 s** |
| same, status form | `sms_tool -s ME status` / `-s SM status` | **0.38 s / 0.30 s** |
| shim `recv` (no AT) | `sms_tool -s ME recv -j` | **0.17 / 0.13 / 0.10 s** |
| AT lock occupancy | 200 × `flock -x -n /tmp/qmanager_at.lock -c true` at 0.15 s spacing | **held 78/200 samples = 39 %**; a *blocking* acquire waited only 0.15 s |
| jq startup | `/usr/bin/time /data/qmanager/bin/jq -n '{a:1}'` | **0.04–0.26 s** |
| the AT holding pattern | `qmanager-poller.service` = `POLL_PERIOD=5`, header says a cycle is 3.7–4.0 s | `Environment=QM_AT_MIN_INTERVAL=3`, `POLL_PERIOD` default 5 |

Budget: ~1.3 s of real AT + 0.6–3 s of jq forks + *N* × 1 s of `flock_wait`
sleeps (N = how many of the six acquisitions collided with a poller burst,
0–6) + shell parse of a 36 KB script, on a 1-core box whose load was 4.7–12.
That is the 6–15 s. **None of it produces a message**, because the shim's
`recv` is a constant `{"msg":[]}`.

The storage tile is also wrong for the same reason: `used: 0` comes from
`AT+CPMS`, and the modem's slots really are empty — the messages were moved to
the vendor store (see §4). The user therefore sees "0 messages" *after* a
6–15 s wait.

---

## 3. Is "every AT read path gives +CMS ERROR" true? — **partly. The claim is right in effect, wrong in detail.**

Commands issued, one at a time, each under `timeout` (this is the entire AT
footprint of this investigation):

```
$ timeout 10 /data/qmanager/bin/qcmd 'AT+CPMS?'
+CPMS: "SM",0,10,"SM",0,10,"SM",0,10
OK
rc=0

$ timeout 10 /data/qmanager/bin/qcmd 'AT+CMGF?'
ERROR: command_failed            rc=1

$ timeout 10 /data/qmanager/bin/sms_tool at 'AT+CMGL="ALL"'      # via /bin/atcmd + atcmd_daemon
atcmd_receive:
ERROR

$ timeout 10 /data/qmanager/bin/qcmd 'AT+CMGF=1'
OK                               # the SET is accepted

$ timeout 12 /data/qmanager/bin/qcmd 'AT+CMGL="ALL"'
ERROR: command_failed

$ timeout 12 /data/qmanager/bin/qcmd 'AT+CMGR=1'
ERROR: command_failed
```

Findings:

1. **Reads do fail on both transports** — the AT broker (`/bin/atcmd` →
   `atcmd_daemon`, and `qcmd` → `atcli_smd11` → `/dev/smd11`). Confirmed.
2. **No `+CMS ERROR` is ever returned.** The reply is a bare `ERROR`, and in
   `qcmd`'s case not even that: `atcli_smd11` prints nothing usable and the
   wrapper reports `command_failed`. So `docs/09-features.md:165` ("answer
   `+CMS ERROR` in both text and PDU modes") overstates the evidence — there is
   no final-result code to cite.
3. **`AT+CMGF=1` succeeds**, so "text mode is refused" is not the mechanism
   either; the read verbs themselves are refused.
4. **Today there is nothing to read even if they worked:** `AT+CPMS?` reports
   **0 used** in both ME and SM (totals 255 / 10), while 17 messages exist on
   disk (§4). The vendor moves each received message out of the modem.
5. `AT+CPMS?` now also reports mem1/mem2/mem3 = **SM**, not ME (the CGI's
   self-heal sets ME, something else sets it back) — a side observation, not the
   root cause.

**Conclusion:** QManager must not try to read SMS from the modem. The data lives
in the vendor's own store, and there is a fast, unauthenticated way to read it.

---

## 4. How the vendor does it — the whole chain, with evidence

### 4.1 Topology (all confirmed on the device)

```
stock web UI :80  (mini_httpd, dir=/tzwww, cgipat=cgi-bin/*)
   /tzwww/js/sms/smsInbox.js  --POST JSON-->  /tzwww/cgi-bin/http.cgi
                                                     |
                                       /lib/libmdlsockmsg.so  (sockmsg "common_msg")
                                                     |
                              unix STREAM socket  /tmp/.sockmsg/tz_sms_mgr   (inode 20801)
                                                     |
                                            /bin/sms_mgr  (PID 1377, fd 5 = that socket)
                                                     |
                                    /data/sms/{read_index, sms_read/<slot>, unread_sms}
```

Evidence per link:

* **httpd / web root / CGI**: `/tmp/mini_httpd.conf` =
  `user=root port=80 dir=/tzwww cgipat=cgi-bin/* pidfile=/tmp/mini_httpd.pid`;
  `/proc/1159/cwd -> /tzwww`; `netstat -lntp` shows `:::80 1159/mini_httpd`;
  the only CGI is `/tzwww/cgi-bin/http.cgi` (468 680 B, plus `http.cgi.bak`).
* **endpoint**: `/tzwww/js/main.js` — `defaultSetting:{url:Url.DEFAULT_CGI,…}`
  and `Url.DEFAULT_CGI = "cgi-bin/http.cgi"`; `Page.postJSON` does
  `$.ajax({url:…,type:"POST",data:JSON.stringify(json)})`.
* **the SMS requests** (`/tzwww/js/sms/smsInbox.js`, single minified line):

  ```js
  // list (polled every 2 s by mounted(): setInterval(getSmsList, 2000))
  Page.postJSON({json:{cmd:RequestCmd.SMS_INFO, page_num:this.currentPage, subcmd:0}, …})
  //   response: {sms_total, receive_full, send_full, sms_list:"<b64>,<b64>,…"}
  //   each entry: Base64.decode(x).split(" ")
  //     -> [0]index [1]flag [2]sender($→space) [3]date [4]time [5..]text
  // mark read / read-all
  Page.postJSON({json:{cmd:RequestCmd.SMS_INFO, method:JSONMethod.POST, index:e.index}})   // or "READ ALL"
  // delete (outbox uses subcmd:1)
  Page.postJSON({json:{cmd:RequestCmd.SMS_DELETE, method:JSONMethod.POST, index:…, subcmd:0}})
  ```
  Command numbers from `main.js`: `SMS_INFO:12`, `SMS_SEND:13`,
  `SMS_DELETE:14`, `SMS_SETTING:16` (outbox = same cmds with `subcmd:1`,
  `/tzwww/js/sms/smsOutbox.js`).
  Auth: `GET_NEXT_LOGIN_TIME:232` → token, then `LOGIN:100` with
  `passwd = sha256(token + sha256(passwd))` + `sessionId` (`/tzwww/js/login.js`).
* **the bus**: `netstat -lnxp` → `unix 2 [ACC] STREAM LISTENING 20801 1377/sms_mgr /tmp/.sockmsg/tz_sms_mgr`;
  `ls -l /proc/1377/fd` → `5 -> socket:[20801]`, `4 -> /tmp/logs/TZ_SMS_MGR.log`;
  `/proc/1377/exe -> /bin/sms_mgr` (274 080 B, not stripped, with debug info).
  Every vendor app has a socket of this shape (`/tmp/.sockmsg/atcmd_daemon`,
  `…/dialer`, `…/lan_mgr`, `…/tz_phone`, …).
* **the library**: `/lib/libmdlsockmsg.so` exports `init_sockmsg`,
  `init_sockmsg_one_way`, `sockmsg_send_common_msg`,
  `sockmsg_send_common_msg_group`, `sockmsg_send_broadcast_msg`,
  `sockmsg_send_single_atcmd`, `proxy_sockmsg_send_common_msg`, and carries the
  `eAPP_ID` enum (`APP_ID_TZ_SMS_MGR`, `APP_ID_HTTP_CGI`, `APP_ID_ATCMD`, …)
  and `MSG_TYPE_COMMON` / `MSG_TYPE_BROADCAST`.
* **the app id**: `APP_ID_TZ_SMS_MGR = 0x1b = 27` — read out of `/bin/sms_mgr`'s
  DWARF (`DW_AT_name("APP_ID_TZ_SMS_MGR") / DW_AT_const_value(0x1b)`,
  declared in `…/libsockmsg/sockmsg.h:128`).
* **the message ids**: `/bin/sms_mgr`'s `tz_sms_mgr_handler` dispatches on a
  switch that compares against `0x5500` and `0x5501 … 0x5507` (ARM
  `movw r2,#0x550n; cmp`). Eight ids = the eight operations whose strings are
  compiled in: `TZ_SMS_MGR_MSG_ID_{SEND_SMS, READ_SMS, DELETE_RECEIVE_SMS,
  DELETE_SEND_SMS, SAVE_DRAFT_SMS, DELETE_DRAFT_SMS, GENERATE_SMS,
  FLOW_CONTROL_SMS}`. **The exact id↔operation mapping is UNKNOWN** — it needs
  the `sockmsg.h` enum (or a relocation-aware disassembly; the log strings are
  reached through `.data.rel.ro` pointers, so plain `strings`/`-d` does not
  link them).
* **a ready-made CLI client**: `/bin/sockmsg_send` (21 604 B) —
  usage `sockmsg_send -d <destAppId> -m <msgId> [-t secs] [-D]`
  (`getopt "Dhm:s:d:t:"`, prints `src:%d, dest:%d, msg:%d`).

### 4.2 The store on disk — this is the answer

```
/data/sms/read_index            43 B: " 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 "   (allocated slots)
/data/sms/sms_read/<slot>       one file per received message (17 present)
/data/sms/unread_sms            2 B : "14"  (== number of rows with flag 0 — verified)
/data/sms/sms_send              ABSENT (no sent messages)
/data/sms/sms_draft             ABSENT
```

File content == exactly the string the web UI base64-decodes, one message per
file (`<slot> <flag> <sender> <date> <time> <body…>`, `$` = space in the sender,
`flag` 0 = **unread**, 1 = **read**):

```
$ cat /data/sms/sms_read/17
17 0 JAZZ$5G 2026-10-26 12:24:05   Number band ya out of coverage ho to bhi SMS deliver ho sakta hai. *6070# dial karein aur Smart SMS hasil karein @Rs1.40/day.
$ cat /data/sms/sms_read/10
10 0 ZONG 2025-10-28 12:50:26 tes,Stay at Home Internet Data (6AM To 6PM) 10.00 GB
```

Who writes it: `/bin/sms_mgr` contains the path strings next to its own source
files (`/data/sms/sms_read`, `/data/sms/read_index`, `/data/sms/unread_sms`,
`/data/sms/send_index`, `tz_sms_mgr_read.c`, `tz_sms_mgr_read_recvive_sms`,
`read already receive sms failed`), and its log shows the write in progress:

```
$ cat /tmp/logs/TZ_SMS_MGR.log
…
2026-10-26 09:23:45.869983 [syslog] [tz_sms_mgr] tz_sms_mgr_receive_sms_by_sunsea: start write data to file
2026-10-26 12:24:07.287893 [syslog] [tz_sms_mgr] tz_sms_mgr_receive_sms_by_sunsea: cascade seq 157 sms not receive finish, has 1 message not receive
2026-10-26 12:24:11.290894 [syslog] [tz_sms_mgr] tz_sms_mgr_receive_sms_by_sunsea: start write data to file
```
— which is slot 17's arrival (`… 2026-10-26 12:24:05 …`) to the second.
The same log shows it does its own AT work (`sms_mgr send at error`,
`get at_respone at_id not same as request`, `recv new sms by cmti, not cmt`) —
i.e. it, not QManager, is the AT client that owns SMS, and it tells the daemon
which of the modem's slots to keep.

`http.cgi` does **not** read the store itself: `grep -ac "/data/sms"` is **0**
for `/tzwww/cgi-bin/http.cgi` and **0** for `/lib/libcmdlib.so`, but **32** for
`/bin/sms_mgr`. The CGI asks `sms_mgr` over the socket.

### 4.3 What the store actually contains (live, 2026-10-26 15:35)

17 messages, **14 unread / 3 read**, 2025-10-27 → 2026-10-26, bodies intact
(including Urdu text in slots 5/6 and a body with a trailing newline group).
Three of them do not follow the common grammar — worth knowing before writing a
parser:

| slots | flag | shape |
|---|---|---|
| 1–6, 9–12, 16, 17 (14 rows) | 0 = **unread** | `<idx> <flag> <sender> <YYYY-MM-DD> <HH:MM:SS> <body>` |
| 7, 8 | 1 = read | same grammar, ordinary texts ("Aap ne Weekly Stay at Home…", "Your PIN code for MyZong…") |
| **13, 14, 15** | 1, 0, 0 | **no sender field**: `<idx> <flag> <YYYY-MM-DD>$<HH:MM:SS> <body>` — date and time joined by `$` in one token, body multi-line |

Slots 13–15 are internal diagnostic dumps (their bodies contain
`current_max_ul_qam:`, `R_all_band:7000…`, and even embedded date strings), so
they are almost certainly generated by another vendor component. They must not
crash the parser, and they must not be mistaken for a sender-with-space.

Verified working parser (busybox awk 1.31 on the device, run read-only):

```sh
awk '{ buf[FILENAME] = (FILENAME in buf) ? buf[FILENAME] "\n" $0 : $0 }
END { for (f in buf) { s = buf[f]
        idx = s; sub(/ .*/, "", idx); ram = substr(s, length(idx) + 2)
        flag = ram; sub(/ .*/, "", flag); ram = substr(ram, length(flag) + 2)
        sp = index(ram, " "); tok = substr(ram, 1, sp - 1)
        if (tok ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\$[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) {
            sender = ""; dt = tok; body = substr(ram, sp + 1)
        } else {
            sender = tok; rest = substr(ram, sp + 1)
            sp2 = index(rest, " "); d = substr(rest, 1, sp2 - 1); rest2 = substr(rest, sp2 + 1)
            sp3 = index(rest2, " ")
            if (sp3 > 0) { t = substr(rest2, 1, sp3 - 1); body = substr(rest2, sp3 + 1) } else { t = rest2; body = "" }
            dt = d " " t
        }
        gsub(/\$/, " ", sender)
        print idx "|" flag "|" sender "|" dt "|" substr(body, 1, 30)
} }' /data/sms/sms_read/*
```

Output (abridged, exactly as produced): `17|0|JAZZ 5G|2026-10-26 12:24:05|  Number band ya out of covera`,
`13|1||2026-09-01$08:17:33|and:\ncurrent_max_ul_qam:\ncurre`,
`1|0|Jazz x Rox|2025-10-27 11:05:33|Get real rewards with the ROX `.

> **busybox awk trap found the hard way:** a 6-argument `printf "%s|idx=%s|…"` in
> busybox 1.31 emits a spurious extra line (it splits the format at the second
> `%s`). Use `print` with string concatenation, not `printf`, in the CGI.

Cost of reading the whole store on this box: `cat /data/sms/sms_read/* | wc -c`
= **0.10 s** (1 fork), the awk pass above = **0.05–0.10 s**. Compare with 6–15 s.

### 4.4 What I could not confirm

* The vendor CGI's own JSON body: every `POST cgi-bin/http.cgi` I tried
  (`cmd:12` SMS_INFO with `sessionId:""`, and `cmd:80`) returned `HTTP/1.0 200`,
  `Content-type: application/json`, and an **empty body**. A valid `sessionId`
  is required to go further, and obtaining one means a login (a wrong password
  locks the account for 180 s — a state change I was told not to make). So the
  claim "the stock UI is served from `/data/sms`" rests on four independent
  facts rather than on the vendor response itself: the file format is
  byte-identical to what `smsInbox.js` parses, `sms_mgr` is the writer, the modem
  holds 0 messages so nothing else could supply 17, and `http.cgi` never touches
  `/data/sms`. **Resolving it would take:** `cmd:232` → token → `cmd:100` LOGIN
  with the known admin password, then `POST cmd:12` and compare `sms_total`/the
  `sms_list` base64 rows against `ls /data/sms/sms_read`.
* The exact `TZ_SMS_MGR_MSG_ID_*` numbers (§4.1).

---

## 5. Fix plan

Principle: **stop asking the modem; read the device's own store** — the same
design already locked for the O5A Pro in
`greenpacket-o5a-qmanager/docs/specs/sms-vendor-store.md`, with a new backend.
Nothing about the modem path changes for devices that have no store.

### 5.1 Backend — `scripts/www/cgi-bin/quecmanager/cellular/sms.sh`

Deployed by `deploy-x16/install.sh:117-118` (`cp -a $QM_SRC/scripts/www/cgi-bin/quecmanager`)
to `/data/qmanager/www/cgi-bin/quecmanager/cellular/sms.sh`, so the change is
made **in the QManager tree** and pushed with the existing payload.

1. **New config block** next to `STORE_DB`/`SQLITE3_BIN` (`sms.sh:74-85`):

   ```sh
   SMS_FILE_STORE="/data/sms/sms_read"      # one file per received message
   SMS_FILE_INDEX="/data/sms/read_index"    # allocated slot list
   SMS_FILE_UNREAD="/data/sms/unread_sms"   # unread counter
   SMS_STORE_BACKUP_DIR="/data/qmanager/data/sms-store-backups"
   ```

2. **New function `file_store_inbox_json()`**, same contract as
   `store_inbox_json()` (`sms.sh:169-190`): prints the message array and returns
   **0 when the store answered — including an empty store (`[]`)** — 1 only when
   the store cannot answer at all (no dir, unreadable). Call it from the GET
   branch at `sms.sh:480`, *before* `store_inbox_json`, or make the two
   backends a single `store_inbox_json` that tries sqlite then files.
   Implementation: the verified awk pass in §4.3, emitting one line per message
   (`idx \t flag \t sender \t date \t time \t body` with `\n`→`\\n`, `\t`→`\\t`,
   `\\`→`\\\\` escapes applied to the body *last*), piped through
   `jq -R -s` to build the array. One awk fork, one jq fork.

3. **Field mapping** (QManager's shape, cf. `STORE_JQ` at `sms.sh:148-167`):

   | store | message |
   |---|---|
   | slot number | `indexes: [slot]`, `storage: "STORE"` |
   | `sender` (`$`→space, **sender only**, never the body) | `sender` |
   | `YYYY-MM-DD` + `HH:MM:SS` | `timestamp` **converted to `MM/DD/YY HH:MM:SS`** (`parseSmsTimestamp()` returns 0 otherwise); a date that does not match the pattern is passed through verbatim |
   | body (verbatim, newlines and leading spaces preserved, no trailing-newline trimming) | `content` |
   | `flag` | `read: (flag == "0" ? false : true)` — **inverted vs intuition, exactly like the O5A `readed`** |

4. **Envelope**: `source:"store"`, `storage:{used:N, total:0, store:{used:N}}`,
   `me`/`sm` omitted (there is no per-memory split and the store has no capacity).

5. **Ordering**: newest first on the parsed timestamp (the `sms_read/*` glob is
   lexicographic, i.e. `1,10,11,…,2`; never rely on it).

6. **Fallback rule**: absent/unreadable store → today's modem path untouched.
   An **empty** store is a legitimate empty inbox, *not* a fallback trigger.

7. **`action=delete` with `storage:"STORE"`** (POST branch, `sms.sh:718-760`):
   validate that each id is a bare integer, back up
   `/data/sms/sms_read/<id>` to `$SMS_STORE_BACKUP_DIR` (keep newest 3),
   `rm` the file, then rewrite `read_index` **atomically** (write
   `/data/sms/.read_index.$$` then `mv` over it) minus those ids, and recompute
   `unread_sms` as the count of remaining files whose `flag` is `0`.
   `delete_all` = the same for every slot plus the backup.
   Do **not** reach for `AT+CMGD` for store rows — it targets modem slots,
   not the store, and can wipe slots `sms_mgr` expects.
8. **Mark-read (optional, recommend stage 2)**: the vendor's own verb is
   `READ_SMS`; QManager's current behaviour is browser-local (`localStorage`,
   `hooks/use-sms-read-state.ts`). Keep that for v1 and only *read* `flag`, so
   two writers never fight over the vendor's counter.
9. **App layer** (small, mirrors the O5A change): `types/sms.ts` already has
   `STORE`; `components/cellular/sms/summary-tiles.tsx` wording, locale keys —
   all already landed for the O5A work, so if that spec is in the tree this is
   backend-only. Verify by grepping `STORE` in `types/sms.ts`.

Do **not** change: `hooks/use-sms.ts:23` (`CGI_ENDPOINT`), the poller, `qcmd`,
`atcli_smd11`, `AT+CPMS` routing for other features, or the vendor's `/bin/sms_mgr`.

### 5.2 Why not the socket instead

`sockmsg_send -d 27 -m <TZ_SMS_MGR_MSG_ID_READ_SMS>` is the "proper" way to ask
the owner (`APP_ID_TZ_SMS_MGR = 27`, socket `/tmp/.sockmsg/tz_sms_mgr`), and it
is the only route if the store is ever removed. But: the msg ids are only known
to be `0x5500–0x5507`, the payload struct is not documented here, and a
malformed `common_msg` goes straight into the process that owns SMS on this
device. The files are the same data, need no auth, no struct, and cost 0.15 s.
Use the socket only if the store proves unreliable. (`sockmsg_send` is present on
the device and works as a shell client, so this stays a one-line experiment.)

---

## 6. How to verify

```sh
# 0) baseline, before the change (records the symptom)
C=$(curl -s -i -X POST -H 'Content-Type: application/json' -d '{"password":"<redacted-password>"}' \
     http://127.0.0.1:8080/cgi-bin/quecmanager/auth/login.sh | sed -n 's/.*qm_session=\([a-f0-9]*\).*/\1/p')
time curl -s -b "qm_session=$C" http://127.0.0.1:8080/cgi-bin/quecmanager/cellular/sms.sh | head -c 200
# expects: ~6-15 s, "source":"modem", "messages":[]

# 1) after the change
time curl -s -b "qm_session=$C" http://127.0.0.1:8080/cgi-bin/quecmanager/cellular/sms.sh \
  | jq '{source, n:(.messages|length), used:.storage.used, first:.messages[0]}'
# expects: wall < 1 s; source="store"; n = 17; used = 17;
#         first.sender="JAZZ 5G"; first.timestamp="10/26/26 12:24:05";
#         first.content starts "  Number band ya out of coverage"; first.storage="STORE"
#         first.read == false   (flag 0 = unread)

# 2) the counts must equal the device's own numbers
ls /data/sms/sms_read | wc -l      # 17
cat /data/sms/unread_sms           # 14  -> unreadCount in the page must be 14
cat /data/sms/read_index           # slots; every slot must appear exactly once

# 3) no AT on the hot path (the lock must stay untouched by a GET)
flock -x -n /tmp/qmanager_at.lock -c 'echo lock-free'   # before and after a GET
grep -c sms_tool /var/log/... 2>/dev/null || true       # or: qlog 'source: store' line

# 4) fallback still works
#    (on a scratch copy only) point SMS_FILE_STORE at a non-existent dir
#    -> source":"modem", unchanged response shape.

# 5) delete (when implemented)
#    POST {action:"delete", storage:"STORE", indexes:[17]} -> success
#    ls /data/sms/sms_read/17 -> gone; read_index no longer lists 17;
#    unread_sms recomputed; a backup exists in $SMS_STORE_BACKUP_DIR.
```

Expected page behaviour afterwards: the inbox shows the same 17 messages with
the same text as `http://127.0.0.1/#sms`, tiles read 17 / 14 unread, and the page
loads in well under a second.

---

## 7. Risks / do-not-touch

| Risk | Mitigation |
|---|---|
| **`/data/sms` has no lock we can see** — `sms_mgr` holds no lock file under `/data/sms` (no `flock`/`*.lock` strings in `/bin/sms_mgr`; its own mutexes are pthreads), so a file can be mid-write or half-renamed while we read | GET is read-only; skip any file whose first two fields do not parse; never `wait`/retry in a loop (a partial row is a skipped row, not a hang). Re-check `ls` consistency between `read_index` and the directory and prefer the directory |
| **Two writers on delete** | backup + atomic `mv` of `read_index`; delete only slots that came from the store; scope `delete_all`. If the vendor UI later shows a ghost row, the backup is the rollback |
| **Whether `sms_mgr` caches the list in RAM** is UNKNOWN (it has a `push_sms_into_queue` with a "queue is full" guard) — deleting a file may not immediately change the stock UI's list | accept for v1; verify by opening `#sms` after a store delete, and if it lags, switch deletes to `TZ_SMS_MGR_MSG_ID_DELETE_RECEIVE_SMS` |
| **Malformed rows** (slots 13/14/15: no sender, `date$time`, multi-line body) crash a naive parser | the §4.3 grammar handles all three; drop nothing silently — pass an unparsable row through with `sender:""` |
| **`$` handling** — the store escapes *sender* spaces as `$`, bodies keep real spaces and may legitimately contain `$` | replace `$`→space in the sender field only (this is what `smsInbox.js` does) |
| **busybox awk `printf` quirk** (extra line) | use `print` concatenation |
| **Timestamp format**: store is `YYYY-MM-DD HH:MM:SS`, QManager is `MM/DD/YY HH:MM:SS` | convert in the CGI, never in the browser; `parseSmsTimestamp()` returns 0 on unknown shape |
| **Never** touch: `/bin/sms_mgr`, `/tzwww/**`, `mini_httpd`, `atcmd_daemon`, `AT+CMGD` on store-backed rows, `/data/sms` on a *GET* | the SMS manager is the only reason SMS on this box works at all |
| Doc drift to correct in the same commit | `docs/09-features.md:165` (no `+CMS ERROR` is returned; storage is 0 used because the vendor consumes it), `deploy-x16/README.md:29`, `deploy-x16/sms_tool` header (lines 14-25: "recv not possible" is true of the *modem*, but the device store is readable and must be named there) |

---

## 8. File map (exact)

| Path | Lines | Why |
|---|---|---|
| `greenpacket-o5a-qmanager/scripts/www/cgi-bin/quecmanager/cellular/sms.sh` | 74-85, 91-111, 113-135, 148-167, 169-190, 193-240, 475-500, 504-620, 652-… | the file to change: config, `flock_wait`, `sms_locked`, `STORE_JQ`, `store_inbox_json`, `store_delete_ids`, GET/POST branches |
| `greenpacket-o5a-qmanager/docs/specs/sms-vendor-store.md` | all | the already-locked design this change reuses (same shape, new backend); §"Out of Scope" already refuses the outbox/read-write scope |
| `zlt-x16/deploy-x16/install.sh` | 117-118, 164, 314 | how `sms.sh` and `bin/*` reach the device |
| `zlt-x16/deploy-x16/sms_tool` | 1-46, `recv)` case | the shim whose `recv` is a constant `{"msg":[]}` — update its header once the store answers |
| `zlt-x16/docs/09-features.md` | 165 | the "every AT read path gives +CMS ERROR" claim, and `APP_ID_TZ_SMS_MGR` mention — both need correcting |
| `zlt-x16/deploy-x16/README.md` | 29 | same claim in the module README |
| `/data/qmanager/www/cgi-bin/quecmanager/cellular/sms.sh` (device) | 74-79, 480, 500-620 | deployed copy; source of the measured 6-15 s |
| `/tzwww/js/sms/smsInbox.js`, `/tzwww/js/sms/smsOutbox.js`, `/tzwww/js/main.js`, `/tzwww/js/login.js` (device) | 1 (minified) | the vendor request contract (`SMS_INFO:12`, `SMS_DELETE:14`, `subcmd`, `sms_list` base64 grammar) |
| `/tzwww/cgi-bin/http.cgi` (device) | — | the single vendor CGI; does **not** read `/data/sms` (grep count 0) |
| `/bin/sms_mgr` (device) | strings + DWARF | the owner: writes `/data/sms/*`, listens on `/tmp/.sockmsg/tz_sms_mgr`, `APP_ID_TZ_SMS_MGR=27` |
| `/data/sms/{read_index,sms_read/<n>,unread_sms}` (device) | — | the store itself; 17 messages, 14 unread |
| `/tmp/logs/TZ_SMS_MGR.log` (device) | 1-8 | write-to-file proof |
| `/tmp/mini_httpd.conf` (device) | — | web root `/tzwww`, cgipat, port 80 |
| `/tmp/.sockmsg/tz_sms_mgr` (device) | — | the IPC socket |
