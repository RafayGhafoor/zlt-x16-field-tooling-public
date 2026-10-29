# Recon — IMEI settings page: what gates the identity write

Investigation: why QManager's "IMEI Settings" page cannot change the device
identity, and what the minimal safe change is. Read-only on the device; no AT
command that changes modem state was sent (the one probe below is short-circuited
by the shim before `/bin/atcmd`).

Evidence base:
- QManager source: `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager`
- payload: `/Users/emumba/Downloads/projects/zlt-x16/deploy-x16/atcli_smd11`
- device (read-only): `zlt-root`, current IMEI `<imei-redacted>`

---

## 1. Reproduced symptom

The page is fully wired for writes. The write dies one layer below the CGI:

```sh
# device, read-only probe — the shim refuses this before touching atcmd_daemon
timeout 10 /data/qmanager/bin/qcmd "AT+EGMR=1,7,\"490154203237518\""
# -> ERROR: command_failed
# -> rc=1
```

`qcmd` sees the shim's bare `ERROR`, maps it to `command_failed`, prints nothing
on stdout and exits 1. In `imei.sh` that is exactly the `egmr_failed` path:

```
rc=1, result=""  ->  egmr_ok="false"  ->  cgi_error "egmr_failed" "Failed to write IMEI to modem"
```

So the GUI's error is technically correct but the cause is not the CGI and not
the UI — it is the AT dialect shim's allowlist.

---

## 2. Root cause — `file:line`

The gate is **`deploy-x16/atcli_smd11`**, in two places (both must change):

1. `deploy-x16/atcli_smd11:848-849` — the dialect table:
   ```sh
   AT+EGMR=0,7)                           at_raw 'AT+CGSN' ;;
   AT+EGMR=1,*)                           printf 'ERROR\n' ;;   # never write IMEI
   ```
2. `deploy-x16/atcli_smd11:88-96` — `is_safe_cmd()`, which `at_raw()` consults
   before anything can reach `atcmd_daemon`:
   ```sh
   'AT+CNMP='*|'AT+CFUN=0'|'AT+CFUN=1'|'AT+CFUN=4')
       return 0 ;;
   *)  return 1 ;;
   ```
   `AT+SIMEI=` is not in this list, so even a translated write would be refused.
   The header comment at `atcli_smd11:83` states the intent explicitly
   ("Deliberately NOT allowed: … AT+EGMR write").

The same two-line refusal is deployed on the device:
`/data/qmanager/bin/atcli_smd11:848-849` (verified by grep; identical line
numbers). `deploy-x16/install.sh:187,284,337` is what pushes
`deploy-x16/atcli_smd11` to `/data/qmanager/bin/atcli_smd11`, so that file is
the one to fix — not the older copy in the QManager tree.

### What the layers above the shim already allow

Nothing above the shim blocks a write. There is no hidden/disabled UI, no CGI
allowlist rejection, and no read-only page:

| Layer | File:line | Behaviour today |
|---|---|---|
| Sidebar (page is reachable) | `components/app-sidebar.tsx:111` | `imei_settings` → `/cellular/settings/imei-settings` |
| Page shell | `app/cellular/settings/imei-settings/page.tsx:1-7` | renders `<IMEISettings />` |
| Write card | `components/cellular/settings/imei-settings/imei-settings-card.tsx:128-135` | input seeded with current IMEI; `canWrite = isComplete && isLuhnValid && hasChanged && !isSaving` — i.e. **enabled** for any valid, changed 15-digit Luhn-valid number (`validateImei` from `lib/imei-utils.ts:47-62`) |
| Submit | `imei-settings-card.tsx:157-171` | `onSave(imei)`, then a reboot-now/later dialog |
| Hook | `hooks/use-imei-settings.ts:114-160` | POST `{action:"set_imei", imei}` to the CGI |
| CGI | `scripts/www/cgi-bin/quecmanager/cellular/imei.sh:88-135` | validates 15 digits (`cgi_at.sh:256-260`), compares against the poller cache, then `qcmd "AT+EGMR=1,7,\"${NEW_IMEI}\""` at line 121 and requires a line-exact `OK` before reporting `reboot_required:true` |
| Gatekeeper | `scripts/usr/bin/qcmd:186-199` | passes the command to `atcli_smd11`; maps `*ERROR*` to exit 1 |
| **Shim (gate)** | **`deploy-x16/atcli_smd11:848-849`, `:88-96`** | **answers `ERROR`, never reaches the modem** |

Two other write sites use the same Quectel command and therefore inherit the
same gate (and the same future translation):

- `scripts/usr/bin/qmanager_imei_check:113` — boot-time backup-IMEI fallback,
  then `reboot`.
- `scripts/usr/bin/qmanager_profile_apply:1006,1024` — custom-profile apply,
  writes IMEI then `AT+CFUN=1,1`.

Read path is unaffected: `AT+EGMR=0,7` → `AT+CGSN` (`atcli_smd11:848`) and
`constants/at-commands.ts:42` (`imei_show`).

---

## 3. What the SIMCom translation is

QManager speaks Quectel `AT+EGMR=1,7,"<15 digits>"`. The SIM8260E implements the
SIMCom native identity command:

- read: `AT+SIMEI?` → `+SIMEI: <imei>` (this is what the vendor dialer uses —
  `firmware-analysis/dialer.strings:2953-2954`)
- write: `AT+SIMEI=<15 digits>` (no quotes)

Evidence in this repo: `docs/03-quectel-surface.md:22`,
`docs/04-simcom-at-mapping.md:31,53,65`, `docs/06-port-plan.md:223`,
`docs/raw/scout-04-simcom-at-mapping.md:33,125`. Tier: **MANUAL + DEVICE strings**
for the command family; the *write* argument form is documented but has **not
been exercised on this unit**. `AT+SIMEI?` is DEVICE-proven; `AT+SIMEI=` should be
confirmed with one controlled write behind the rails below before the page is
considered production-ready.

Note `+SIMEI` is in the "do not expose" list in the existing docs precisely
because it writes persistent modem state. That is why the gate exists; the task
is to move the gate from "no write" to "validated, confirmed, backed-up write".

---

## 4. How the stock vendor UI exposes it

**It does not have an IMEI settings page.** The vendor web root is `/tzwww`
(`/tzwww/html`, `/tzwww/js`, `/tzwww/cgi-bin/http.cgi`). Facts from the device:

- No IMEI page: `ls -R /tzwww/html | grep -i imei` → empty. Directories are
  `advance config dashboard info manage parentControl sms sys tools update voice vpn`;
  `info/deviceInfo.html`, `advance/simChange.html`, `advance/unlock.html` exist,
  but no identity editor.
- `RequestCmd` (`/tzwww/js/main.js`, the object at the top of the file) has **no
  identity-write command**. IMEI appears only on read paths:
  - `RequestCmd.DEVICE_VERSION_INFO:43` — `getModule()` reads `Page.imei = n.imei`
  - `RequestCmd.DEVICE_INFO:207` — `deviceInfo.js` renders `e.module_imei`
  - `home.js` dashboard column `DOC.device.imei`
- The only way to change identity from the vendor UI is the **hidden AT console**:
  `/tzwww/html/manage/sysAt.html` → `/tzwww/js/manage/sysAt.js` posts
  `Base64(atCmd)` with `cmd: RequestCmd.SEND_AT:270` to `http.cgi`. The menu
  entry is gated in `/tzwww/js/home.js`:
  ```js
  "1"==sessionStorage.level && c.push(new MenuBody("SEND_AT", MENU.sys.at))
  ```
  i.e. only an "engineer level 1" session sees it. There is no dedicated,
  validated identity form anywhere in `/tzwww`; the vendor ships the raw AT
  passthrough instead.

Conclusion: the vendor does not provide a model to copy for the page; its dialer
only reads identity (`AT+SIMEI?`). Our page's UX (validate + backup + reboot) is
ahead of the vendor's.

---

## 5. Fix plan

### 5.1 The minimal change — one file, two hunks

File: `deploy-x16/atcli_smd11` (the payload `install.sh` pushes to
`/data/qmanager/bin/atcli_smd11`).

**Hunk A — translate instead of refuse (`:848-849`):**

Keep the read mapping. Replace the write refusal with a validated translation:

```sh
AT+EGMR=0,7)                           at_raw 'AT+CGSN' ;;
AT+EGMR=1,7,"*)                        run_simei_write "${_cmd#AT+EGMR=1,7,\"}"
```

and add a helper above `run_one()`:

```sh
# AT+EGMR=1,7,"<imei>" (Quectel) -> AT+SIMEI=<imei> (SIMCom).
# The only command in this shim that writes persistent modem state, so it is
# validated here as well as in the CGI: exactly 15 ASCII digits, nothing else.
run_simei_write() {
    _imei=$1
    _imei=${_imei%\"}                       # strip the closing quote
    case "$_imei" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            at_raw "AT+SIMEI=$_imei" ;;
        *)  printf 'ERROR\n' ;;
    esac
}
```

**Hunk B — allow the translated command through `is_safe_cmd()`
(`:88-96`):** add `'AT+SIMEI='[0-9]*` to the case list. This is the second gate:
without it `at_raw` prints `ERROR` and the write never reaches the daemon.

Nothing else is strictly required: `imei.sh`, the hook and the card already send
`AT+EGMR=1,7`, validate 15 digits, require `OK`, and set `reboot_required`.
`qmanager_imei_check` and `qmanager_profile_apply` get the same fix for free.

Optional (not required for the write to work): send `AT+SIMEI?` in the read
branch instead of `AT+CGSN`, if the poller is ever changed to prefer `+SIMEI`.
`AT+CGSN` already returns the same number and is DEVICE-proven — leave it.

Update the header comment at `atcli_smd11:83` and the two tests in
`tests/unit_atcli_smd11.sh:449-453` that currently assert "IMEI write is
refused": they must instead assert the translated `AT+SIMEI=` reaches the fake
`ATCMD`, and that malformed/not-15-digit forms are refused. Add a case for
`AT+SIMEI=...` to the allowlist safety test.

If the QManager repo's `deploy/atcli_smd11` is still built anywhere, mirror the
same two hunks there; for this device the authoritative copy is
`deploy-x16/atcli_smd11` (`install.sh:187`).

### 5.2 Safety rails that must land with it

A raw identity write brickable-by-network is not a button; the following should
be part of the same feature, in this order:

1. **Value validation (both ends).**
   - Shim: exactly 15 digits (above) — the last line of defence, independent of
     how `at_raw` was reached.
   - CGI already checks shape (`imei.sh:96`, `cgi_at.sh:256`) and the card
     already enforces Luhn (`imei-settings-card.tsx:128-135`,
     `lib/imei-utils.ts:47`). Keep both; do not replace the Luhn check with the
     shim's shape check.
2. **Confirmation step.** The card currently writes on the first click and only
   shows the reboot dialog *after* success. Add an `AlertDialog` before
   `onSave(imei)` ("this writes modem NVM; restore value X; reboot required"),
   matching the backup card's toggle-confirmation pattern
   (`backup-imei-card.tsx:handleToggle`). The write is irreversible without the
   saved old value.
3. **Backup of the current value.** Before the write, read the current IMEI
   (`qcmd AT+CGSN`, already used by the CGI's "already set" comparison) and
   persist it to `/etc/qmanager/imei_backup.json` (the existing file at
   `imei.sh:31`, schema `{enabled,imei}`) or a new
   `/data/qmanager/imei-history.json` with timestamp. Today `save_backup` only
   stores a value the user typed; it does not necessarily hold the pre-write
   identity. Without this there is no rollback.
4. **Refuse while a data call is active.** On this unit the WAN is up
   (`/proc/net/route`: default route on `rmnet_data0`; `wan_ipv4`
   `10.147.118.97`). Writing NVM requires a modem reboot (`imei.sh` returns
   `reboot_required:true`; `qmanager_profile_apply` does `AT+CFUN=1,1`), which
   drops the WAN and every LAN client. Gate the POST on "no default route on
   `rmnet_data*`" (read `/proc/net/route`, no AT needed) or on
   `AT+CGACT?` showing the PDP down; return a distinct `data_call_active` error
   with "disconnect WAN first". At minimum the confirmation must say the WAN
   drops.
5. **One-shot + audit.** Log the old and new IMEI to `/data/log/` (the shim has
   no logger; log from `imei.sh` via `qlog_info`, and keep the existing
   `/etc/qmanager/imei_check_pending` behaviour), and refuse a second write
   while a previous write's reboot is still pending (`imei_check_pending` /
   the sessionStorage banner is UI-only and can be bypassed by a direct POST).
6. **Existing protections stay.** `qcmd`'s flock serialises against the poller's
   1 Hz AT traffic; `at_raw`'s 6 s timeout + blacklist (`atcli_smd11:100-140`)
   is what keeps a wedged `AT+SIMEI=` from queueing the dialer behind it. If the
   first real `AT+SIMEI=` times out, it is blacklisted for the rest of the boot
   and no retry can wedge the daemon. Do not bypass `at_raw` for this command.

### 5.3 What must not be touched

- Do not open the write to arbitrary AT: still no `AT+CNV=`, `AT+CNVR=`,
  `AT+CRSM`, `AT+QMBNCFG`, `AT+QSCAN`, `AT+COPS=?`. Only the exact
  `AT+EGMR=1,7,"<15 digits>"` → `AT+SIMEI=<15 digits>` translation.
- Do not enable the QManager AT console's `SEND_AT` path to reach `SIMEI`; the
  shim's allowlist must keep every other writer out.
- Do not touch `/tzwww`, the vendor dialer, or `/bin/dialer`. The vendor UI's
  hidden `SEND_AT` console is vendor-owned and out of scope.
- Do not restart `atcmd_daemon` or QCMAP to "make it work"; that is the
  documented WAN-outage path in `AGENTS.md` §4.

---

## 6. How to verify (after the fix)

Host unit test first (no device):

```sh
cd /Users/emumba/Downloads/projects/zlt-x16
sh tests/unit_atcli_smd11.sh
# expect: translated write reaches the fake ATC as AT+SIMEI=490154203237518;
#         malformed forms still answer ERROR; all old allowlist tests pass
```

On the device, with the WAN deliberately disconnected (rail 4):

```sh
# 1. shim accepts and translates (should reach the modem):
timeout 10 /data/qmanager/bin/qcmd 'AT+EGMR=1,7,"490154203237518"'
# expect: OK   (and a reboot_required response from the CGI)

# 2. read-back after reboot:
timeout 10 /data/qmanager/bin/qcmd 'AT+CGSN'
# expect: 490154203237518 (bare 15-digit line)

# 3. restore:
timeout 10 /data/qmanager/bin/qcmd 'AT+EGMR=1,7,"<imei-redacted>"'
timeout 10 /data/qmanager/bin/qcmd 'AT+CGSN'
# expect: <imei-redacted>
```

Then the UI path: `http://<x16>:8080/cellular/settings/imei-settings` → enter a
Luhn-valid 15-digit number → confirm → expect `reboot_required:true`, a saved
backup of the old value, and the deferred-reboot banner. Verify the WAN returns
after the reboot (`/proc/net/route` default route on `rmnet_data0`, internet and
LAN client reachable per `AGENTS.md` §6).

---

## 7. Risks / open questions

- **`AT+SIMEI=` write form is not yet proven on this unit.** `AT+SIMEI?` is in
  `dialer.strings` (DEVICE), the write argument form is MANUAL-only. A single
  controlled write must be done before shipping, because a wrong form may be
  silently ignored or, worse, accepted with a different encoding. If it returns
  `ERROR`, the fallback is `AT+EGMR=1,7` (unlikely to work on SIMCom) — then the
  page must stay read-only. Resolve by one write under `timeout 10`.
- **Reboot coupling.** `imei.sh` only writes and asks the user to reboot;
  `qmanager_profile_apply` does `AT+CFUN=1,1` inline. On a 1-core box with a
  fragile PDP context, the inline reboot path is riskier. Keep the page's
  write-only + explicit-reboot flow; do not copy the profile-apply approach.
- **Legal/regulatory.** Changing IMEI is restricted in many jurisdictions; the
  page already carries a permanent notice banner
  (`imei-settings.tsx` `core_settings.imei.legal`). Not a code risk, but the
  confirmation copy must keep it visible.
- **Two sources of the shim.** `deploy-x16/atcli_smd11` (deployed) and
  `greenpacket-o5a-qmanager/deploy/atcli_smd11` (older, no `EGMR` handling at
  all) have diverged. Fix the `deploy-x16` copy; if the QManager tree's copy is
  ever built, mirror the change or it will silently re-open/close the gate
  depending on build order.
- **Backup file ownership.** `/etc/qmanager/imei_backup.json` is written by the
  CGI (www-data) but read by the boot daemon (root); a new history file needs
  the same mode/permission treatment or the boot check cannot read it.
- **UNKNOWN:** whether the SIM8260E persists `AT+SIMEI=` across a full power
  cycle or only across a modem restart, and whether it enforces its own Luhn /
  TAC checks. That determines whether rail 3 (backup) is mandatory or merely
  prudent. Resolve with the single controlled write above plus one cold reboot.
