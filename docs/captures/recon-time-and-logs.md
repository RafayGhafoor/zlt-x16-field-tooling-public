# Recon — (A) System Settings › Time/Clock, (B) System Settings › Logs AT errors

Read-only recon, 2026-10-26 ~17:03–17:20 device time (uptime 3107 s → boot ≈ 16:11 PKT).
Transport: `ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 zlt-root`, everything wrapped in `timeout`.
Nothing was modified on the device.

---

## (A) Time / clock

### A1. Reproduced state (measured)

```
# date
Mon Oct 26 17:03:05 PKT 2026        # == host clock to the second (12:03:05 UTC)
# cat /etc/timezone
cat: can't open '/etc/timezone': No such file or directory
# ls -l /etc/localtime
-rw-r--r-- 1 root root 266 Oct 26 15:23 /etc/localtime
# head -c 4 /etc/localtime | od -c   ->  T Z i f
# cmp /etc/localtime /usr/share/zoneinfo/Asia/Karachi  -> SAME
# cat /etc/resolv.conf | head -3
nameserver 119.160.122.146
nameserver 119.160.80.146
# ps w | grep -i ntp
(only the grep itself)                        # <- no ntpd running
# ls -l /tmp/ntp.conf /tmp/.time_synced
ls: /tmp/ntp.conf: No such file or directory
-rw-r--r-- 1 root root 0 Oct 26 16:15 /tmp/.time_synced
# cat /etc/qmanager/qmanager.conf
    "timezone": "PKT-5",
    "zonename": "Asia/Karachi",
# cat /proc/driver/rtc | head -2
rtc_time : 08:11:04
rtc_date : 1970-01-01
# dmesg | grep -i rtc
[ 0.337632] rtc-pm8xxx ...: setting system clock to 1970-01-01T07:21:33 UTC (26493)
```

QManager GET `/cgi-bin/quecmanager/system/settings.sh` (auth `{"password":"<redacted-password>"}`):

```json
"timezone": "PKT-5", "zonename": "Asia/Karachi",
"effective_offset": "+0500", "effective_zone_abbr": "PKT",
"timezone_applied": true
```

### A2. What is actually broken — **syncing**, not reading and not applying

| Sub-behaviour | Verdict | Evidence |
|---|---|---|
| **Reading** the clock | **works** | `date` = host UTC ±0 s; `/proc/uptime` 3107 s. |
| **Applying** a timezone | **works** | `/etc/localtime` is a real TZif and is byte-identical to `/usr/share/zoneinfo/Asia/Karachi`; `TZ=Asia/Karachi date` → `PKT`; CGI reports `timezone_applied:true, effective_offset:"+0500"`. |
| **Syncing** time | **broken / unreliable** | No `ntpd` process; RTC dead (reads `1970-01-01`); clock is 1970 at boot (`dmesg`), so the wall clock is only correct *after* a one-shot NTP attempt that happened at 16:15 (≈4 min after boot, i.e. after WAN came up). Nothing retries or supervises it. |

Two firmware-level defects, both in the vendor boot script pair
`/etc/initscripts/ntp.sh` and `/etc/initscripts/start_ntp` (identical bodies):

1. **The "synced" flag is written before the sync, unconditionally.**
   `/etc/initscripts/ntp.sh:53-55`
   ```sh
   touch /tmp/.time_synced
   $NTP_START_UP_CMD
   ```
   `touch` precedes the `busybox ntpd -q`. `/tmp/.time_synced` therefore proves
   *"we tried"*, never *"we synced"* — which is why the earlier recon found a
   stale marker next to a box with no NTP daemon and a dead RTC.
2. **The server list is one China-pool host and there is no retry.**
   `mdlcfg -g USR_NTP_SERVER` → `cn.pool.ntp.org` (resolves here to 162.159.200.1);
   `USR_NTP_SW` = `1`. `busybox ntpd -q` is one-shot: if that single
   `-p` peer is unreachable at the moment `/etc/initscripts/start_ntp` runs
   (i.e. before the PDP context is up — which is exactly what the 1970 boot clock
   shows), it exits, nothing retries for the session, and the clock stays 1970
   until the next reboot's attempt or a manual `date -s`.
   `USR_NTP_TIMEZONE` = `UTC-4` also disagrees with the live `PKT` zone, but
   `ntpd_sync()` never reads it (`ntp.sh:19` reads it and drops it) — dead config,
   harmless *today*, a trap if someone later starts honouring it.
3. **`mdlcfg` exists**, so the earlier "`cfg` is not a command" observation was a
   different binary name: `/bin/mdlcfg` (144796 bytes, Jan 2024) is present and
   answers. The NTP path is not failing on a missing tool.
4. `/etc/timezone` is absent and nothing on the box needs it — localtime comes
   from `/etc/localtime` (and, per `qmanager_timezone_apply:47-55`, from the
   `TZ` env var exported by `cgi_base.sh` when no tzdata is installed). On *this*
   firmware `/usr/share/zoneinfo` **does** exist, so the POSIX-string fallback in
   `qmanager_timezone_apply` is not taken.

### A3. QManager side is not the cause — the UI cannot even show the defect

* `scripts/usr/lib/qmanager/system_config.sh:65-100` `sys_set_timezone()` writes
  `qmanager.conf` then calls `sudo -n /usr/bin/qmanager_timezone_apply "$zn" "$tz"`;
  helper `scripts/usr/bin/qmanager_timezone_apply` copies the TZif and verifies
  the `TZif` magic twice (`:76`, `:86`). Correct for this box.
* `system_config.sh:105-152` `sys_get_effective_tz()` compares live `date +%z`
  with the offset recomputed from the configured zone, so `timezone_applied`
  is genuine ground truth — it is `true` here, correctly.
* `components/system-settings/system-settings-card.tsx:383-400` only renders the
  warning when `timezone_applied === false`. **The card shows a zone picker and an
  "applied" badge — it never displays the device wall clock or a "last sync"
  timestamp**, so a 1970 clock or a failed NTP run is invisible in the UI. That
  is why the symptom reads as "Time Clock does not behave correctly" with nothing
  pointing at it.
* No QManager code references `ntp`/`time_synced` at all
  (`grep -rn "ntp\|time_synced" scripts lib components app` → only unrelated
  comments). QManager neither owns nor monitors time sync.

### A4. Fix plan (not implemented here)

1. `/etc/initscripts/start_ntp` (and `ntp.sh`): move `touch /tmp/.time_synced`
   to **after** a successful `ntpd -q`, and only when it returned 0 —
   `/etc/initscripts/start_ntp:44`. Otherwise write a failure marker.
2. Replace the single `USR_NTP_SERVER` peer with a reachable set
   (`pk.pool.ntp.org`, `time.google.com`, or the carrier NITZ), and retry:
   loop `busybox ntpd -q -p <server>` with a bounded attempt count after the
   data call is up, rather than once at boot.
3. Consider a QManager-owned guard (same shape as `zlt-smartdns.timer`) that
   checks `date +%Y` ≥ 2024 and re-runs the one-shot; log to
   `/data/log/qmanager-timesync.log`.
4. Surface sync state in the card: `settings.sh` GET could add
   `system_time` + `time_synced` so `system-settings-card.tsx` can show a
   warning when the clock is unset. Low risk, no boot dependency.
5. Do **not** touch `/bin/mdlcfg` values blindly: `USR_NTP_SW`/`USR_NTP_SERVER*`
   are vendor config read by other scripts.

### A5. Verification after fix

```sh
ssh zlt-root 'date -u; ps w | grep -c "[n]tpd"; ls -l /tmp/.time_synced'
# expect: UTC matches a known-good clock within seconds, marker absent until the
# one-shot actually succeeded
ssh zlt-root 'reboot'; sleep 150; ssh zlt-root 'date'   # not 1970, no manual step
```

### A6. Risks / unknowns

* **UNKNOWN**: which service actually corrected the clock at 16:15 — the `ntpd -q`
  from `start_ntp` (plausible: exactly one shot, no daemon left) or NITZ from the
  modem. Resolves with `/data/log`-style logging added to `start_ntp`, or
  `dmesg` captured immediately after a reboot. Either way the "no retry, flag
  written before the attempt" defect stands on its own.
* Any change to the boot hook must follow `AGENTS.md` §4 (units under
  `/etc/systemd/system` are invisible during boot; hook from `start_cfgd`/`StartTZApp`).
* Never restart the dialer/QCMAP while chasing this — a time fix must not touch
  the PDP context.

---

## (B) Logs view — AT errors

### B1. Reproduced

```sh
ssh zlt-root 'curl -s -c /tmp/cc1 -X POST -d "{\"password\":\"<redacted-password>\"}" \
   http://127.0.0.1:8080/cgi-bin/quecmanager/auth/login.sh >/dev/null
 curl -s -b /tmp/cc1 "http://127.0.0.1:8080/cgi-bin/quecmanager/system/logs.sh?lines=200"'
```

200 entries: **129 INFO, 54 ERROR, 17 WARN**. Distinct ERROR messages
(`grep -A5 '"level": "ERROR"' | grep '"message"' | sort | uniq -c`):

```
 12 "message": "ensure: engine not listening and restart failed — rule left off (state: exit-code 3 )"
 12 "message": "Command returned ERROR: AT+QRSRP;+QRSRQ;+QSINR"
  5 "message": "Command returned ERROR: AT+QNWLOCK=\"common/5g\""
  4 "message": "Tower lock state query failed (lte_rc=0 nr_rc=1 persist_rc=1) — reporting per-field read_ok=false, not fabricating state"
  4 "message": "Command returned ERROR: AT+QNWLOCK=\"save_ctrl\""
  3 "message": "Command returned ERROR: AT+QICSGP=1"
  3 "message": "Command returned ERROR: AT+QICSGP=2"
  3 "message": "Command returned ERROR: AT+QICSGP=3"
  3 "message": "Command returned ERROR: AT+QICSGP=6"
  2 "message": "Command returned ERROR: AT+QNWPREFCFG=\"lte_band\",1:3"
  2 "message": "Band lock failed (rc=1): AT+QNWPREFCFG=\"lte_band\",1:3"
  1 "message": "Command returned ERROR: AT+CGDCONT?;+CGSN;+QCCID;+CGPADDR;+QMAP=\"WWAN\";+QSPN"
```

Components emitting them (`"component"` field): `qcmd` (the AT error),
`cgi_apn`, `cgi_bands_lock`, `cgi_tower_status`, `poller`, `qmanager_dpi`.
`/tmp/qmanager.log` (live, 70 KB) shows the same at the same cadence:

```
[2026-10-26 17:03:47] WARN  [cgi_apn:7297] AT command failed: AT+QICSGP=2 (rc=1)
[2026-10-26 17:04:19] ERROR [qcmd:9293] Command returned ERROR: AT+QICSGP=1
[2026-10-26 17:05:14] ERROR [qcmd:12157] Command returned ERROR: AT+EGMR=1,7,"490154203237518"
```

`/tmp/qmanager_at_blacklist` **does not exist** — there is no runtime suppression
list on the device.

### B2. Who really rejects what

The chain is `CGI/poller → /data/qmanager/bin/qcmd → /data/qmanager/bin/atcli_smd11
(shell, 878 lines, the Quectel→SimCom dialect translator) → AT+CGDCONT/modems via /bin/atcmd`.

* `qcmd` has **no allowlist**: it flock-serialises, calls `atcli_smd11`, and turns
  any `*ERROR*` in the output into `qlog_error "Command returned ERROR: $COMMAND"`
  (`scripts/usr/bin/qcmd:189-193`; the deployed copy is the same text). So every
  `Command returned ERROR:` line is *the aggregate of the shim+modem answer*, and
  the shim itself is free to be the one answering `ERROR`.
* `atcli_smd11` **does** hardcode rejections and it **does** pass unknown commands
  through verbatim — `/data/qmanager/bin/atcli_smd11:822` and `:857-860`:
  ```sh
  AT+QNWLOCK*)                     printf 'ERROR\n' ;;            # :822
  AT+EGMR=1,*)                     printf 'ERROR\n' ;;  # never write IMEI  :842
  ...
  *)  at_raw "$_cmd" ;;               # anything untranslated goes to the modem  :859
  ```
* The `;`-compound splitter strips the `AT+` prefix off **every token after the
  first** — `/data/qmanager/bin/atcli_smd11:863-876`:
  ```sh
  case "$_rest" in
      *';'*) _tok=${_rest%%;*} ; _rest=${_rest#*;} ;;
  ```
  so `AT+QRSRP;+QRSRQ;+QSINR` becomes `run_one '+QRSRP'`, `'+QRSRQ'`, …
  Those never match the `AT+QRSRP|AT+QRSRP\?` arms (`:851-854`) and fall into
  `*) at_raw '+QRSRQ'` — i.e. **the shim sends a token without `AT+` to the modem,
  which answers ERROR.** Any multi-command chain in this codebase errors for its
  2nd..nth part. This is a shim bug, not a SIMCom limitation.

### B3. Classification

| AT command | Client (component) | Why ERROR on this box | Class |
|---|---|---|---|
| `AT+QRSRP;+QRSRQ;+QSINR` | `qmanager_poller` (`/data/qmanager/bin/qmanager_poller:1762`, every 5th cycle) | **Our shim's `;`-splitter drops `AT+`** from tokens 2..n (`atcli_smd11:863-876`) → `at_raw '+QRSRQ'` → modem `ERROR`. Secondary: `emit_antenna_native QRSRP` maps to `AT+CRSRP?` (`:216-218`), which this SIMCom firmware does not implement. | **(i) our shim** + (ii) loop |
| `AT+QNWLOCK="common/5g"` | `cgi_tower_status` (and poller tower state) | Line `:822` `AT+QNWLOCK*) printf 'ERROR\n'` — only `"common/4g"` is modelled (`:819-821`), 5G is deliberately not. | **(i) our shim, by design** |
| `AT+QNWLOCK="save_ctrl"` | `cgi_tower_status` | Same catch-all `:822`. | **(i) our shim, by design** |
| `AT+QICSGP=1/2/3/6` | `cgi_apn` (WAN-profile list) | No mapping anywhere in `atcli_smd11` (`grep QICSGP` → 0 hits) → passes through to the modem; Quectel `QICSGP` is PDP-context config, SIMCom uses `AT+CGDCONT`. **The modem answers ERROR.** The poller/CGI re-issues it on every APN page load / poll tick. | **(ii) poller/CGI looping on an unsupported command** (not our shim) |
| `AT+QNWPREFCFG="lte_band",1:3` | `cgi_bands_lock` (band-lock apply) | Reaches `AT+QNWPREFCFG=*` → `set_qnwprefcfg "$_cmd"` (`:834-836`), which rejects this Quectel band-list form; the CGI then logs `Band lock failed (rc=1)`. | **(i) shim translation gap** |
| `AT+CGDCONT?;+CGSN;+QCCID;+CGPADDR;+QMAP="WWAN";+QSPN` | ping/`qcmd` one-shot (single occurrence) | Same `;`-splitter bug as QRSRP; `+QMAP="WWAN"` is Quectel-only (`:855` maps `AT+QMAP*` → `OK`, but the stripped token `+QMAP="WWAN"` never reaches that arm). | **(i) our shim** |
| `AT+EGMR=1,7,"490154203237518"` | `qmanager_imei_check` | `:842` `AT+EGMR=1,*) printf 'ERROR\n'  # never write IMEI` | **(i) our shim, by design and correct** |
| `ensure: engine not listening and restart failed — rule left off (state: exit-code 3 )` | `qmanager_dpi` | Not AT at all — DPI/nftables engine. Noise in this view. | **(iii) unrelated vendor/service noise** |
| `Tower lock state query failed (lte_rc=0 nr_rc=1 persist_rc=1)` | `cgi_tower_status` | Correct-by-design reporting after the `QNWLOCK` rejections above; it is the *consequence*, not a separate fault. | (iii) follow-on noise |

### B4. What the Logs page does with them

`scripts/www/cgi-bin/quecmanager/system/logs.sh` is a **pure viewer** over
`/tmp/qmanager.log` (+`.1`,`.2`) — it parses lines, and filters by
`lines / level / component / search / include_rotated` (`logs.sh:1-30`,
`:41-51`). There is **no AT-specific filter and no suppression list**: an `ERROR`
line from `qcmd` is indistinguishable, to this CGI, from a real fault. So the user
sees ~54 ERROR rows on a box that is working, 26 of which are AT lines that will
never succeed. `qmanager_logread` is the same log, CLI-side
(`scripts/usr/bin/qmanager_logread:1-25`).

### B5. Fix plan (not implemented here)

1. **`atcli_smd11:863-876`** — keep the `AT+` prefix when re-running chain tokens:
   `_tok="AT+${_rest%%;*}"` (or run the whole chain in one `at_raw`). This alone
   kills the `QRSRP;QRSRQ;QSINR` and `CGDCONT?;CGSN;…` errors.
2. **`AT+QICSGP`**: add an arm that answers `OK` (or `ERROR` with a marker) and,
   better, teach `cgi_apn` to read contexts with `AT+CGDCONT?` on this firmware.
   Also stop re-issuing it on every poll.
3. **Logging level**: expected-unsupported commands must not log at `ERROR`.
   Add a "known-unsupported" set inside `atcli_smd11`/`qcmd` that emits
   `qlog_debug` (or `qlog_warn` with `unsupported=1`) instead of
   `Command returned ERROR:`. Keep `ERROR` for real failures.
4. **`QNWLOCK` 5g / `save_ctrl`**: either implement the 5G lock translation or have
   `cgi_tower_status` report "unsupported on this modem" and stop calling it.
5. **Logs view**: add an `unsupported` flag to the parsed entry and a filter so
   `ERROR` means ERROR. `logs.sh` already emits structured JSON per entry — add
   the field, do not post-filter in the UI.

### B6. How to verify

```sh
# 1. shim fix, single command, one at a time, always under timeout:
timeout 10 ssh zlt-root 'timeout 10 /data/qmanager/bin/qcmd "AT+QRSRP;+QRSRQ;+QSINR"'
# before: ERROR (exit 1)   after: +QRSRP/+QRSRQ lines or a clean OK, no "AT+"-less token
# 2. error volume in the view:
curl -s -b /tmp/cc1 "http://127.0.0.1:8080/.../system/logs.sh?level=ERROR&lines=100" | grep -c QICSGP
# expect 0 after the cgi_apn/poller change
# 3. the poller must not have started looping:
ssh zlt-root 'timeout 10 grep -c "Command returned ERROR" /tmp/qmanager.log'
```

### B7. Risks

* `atcli_smd11` is the single gate for **all** modem traffic — a bad edit wedges
  the one-request-at-a-time AT daemon and drops the WAN (see `docs/09-features.md`).
  Test one command at a time, never a loop, never `AT+CRSM`.
* Do not "fix" the `AT+EGMR=1,*` rejection: it is the IMEI-write guard.
* Demo/`cgi_apn` changes touch APN config; verify the data call survives.
* `/tmp/qmanager.log` is tmpfs and rotates at 2 files — the counts above are a
  moment in time (17:03–17:05), not a cumulative total.

---

## One-line summary

**(A)** Reading and applying the timezone both work end-to-end (`/etc/localtime`
is the right TZif, CGI says `timezone_applied:true`); **syncing** is what is broken —
the vendor `start_ntp`/`ntp.sh` writes `/tmp/.time_synced` *before* it runs a single
one-shot `busybox ntpd -q -p cn.pool.ntp.org`, the RTC is dead (1970), and there is
no retry, so the clock is 1970 at every boot until one unrepeatable attempt happens
to succeed. **(B)** The Logs noise is 26 AT ERRORs from 4 distinct causes, and only
`QICSGP` is a genuine unsupported-command loop against the modem — `QNWLOCK 5g`/
`save_ctrl`, `EGMR` and the two `;`-chain failures are our own `atcli_smd11`
answering `ERROR` (the chain one is a real bug: the splitter drops `AT+` from
tokens 2..n), and `qmanager_dpi` is unrelated noise.
