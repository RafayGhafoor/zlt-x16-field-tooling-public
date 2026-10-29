# Working brief — fixing broken QManager features on the ZLT X16

Read this before touching anything. It is the shared context for every agent
working on this device.

## The two devices

| Nickname | SSH | Role |
|---|---|---|
| **X16** | `ssh zlt-x16-root` (= `zlt-root`, `zlt-x16`, all → `root@192.168.3.1:22`) | the **broken** one we fix |
| **GreenPacket O5A** | `ssh -p 2222 greenpacket` (→ `192.168.0.1`) | the **working** reference. Same SDX65 class, same QManager, different modem fw |

GreenPacket QManager root: `/usrdata/qmanager/`
X16 QManager root: `/data/qmanager/`

Everything QManager runs on the X16 lives in `/data/qmanager`; the source of
truth for the payload is the local tree `/tmp/qm` (a full QManager checkout:
`/tmp/qm/scripts/usr/bin/*` → `/data/qmanager/bin/*`,
`/tmp/qm/scripts/www/cgi-bin/quecmanager/*` → `/data/qmanager/www/cgi-bin/quecmanager/*`).

## Transport rules (do not relearn these)

* **`scp` does not work** — dropbear has no sftp-server. Push with
  `ssh host 'cat > /path' < localfile`. Pull with
  `ssh host 'cd dir && tar cf - .' | tar xf - -C localdir`.
* **Every ssh call must retry.** The link drops constantly and a cold connect
  takes up to ~20 s. Use the wrapper below, not bare `ssh`.
* No `rsync`, no `ip`/`ifconfig` in PATH (use `/bin/busybox.nosuid ifconfig`,
  `/proc/net/route`), no python, no `getent`. `curl`, `wget`, `flock`,
  `timeout`, `jq` (at `/data/qmanager/bin/jq`), `busybox` exist.
* Treat a non-zero remote exit as a *command* result and `ssh` exit 255 as a
  *transport* failure. Do not conflate them (this bites greenpacket, whose
  probe commands legitimately exit 1).

Ready-made wrappers on this workstation:

```sh
# X16 — retries 6x, 20 s connect timeout
/tmp/zltwork/rssh '<remote command>'
# GreenPacket — retries, distinguishes rc!=255 from ssh failure
/tmp/zltwork/rgp '<remote command>'
# fresh QManager auth token (writes /tmp/zltwork/token)
/tmp/zltwork/mint
# QManager API call as an authenticated user; re-mints on 401
/tmp/zltwork/qmapi GET  /tower/status.sh
/tmp/zltwork/qmapi POST /tower/schedule.sh '{"enabled":true,...}'
```

If `/tmp/zltwork` is missing (new shell/machine), recreate them — the source is
inline in the capture README and in each task.

## Talking to the QManager CGI API

Every CGI on port 8080 requires an authenticated session cookie
(`qm_session=<64 hex>`), except `public/*.sh` and `auth/*.sh`. Sessions are
files in `/tmp/qmanager_sessions/<token>` holding a unix timestamp; TTL 1 h.
Mint one with root SSH:

```sh
T=$(head -c 32 /dev/urandom | openssl dgst -sha256 -hex | awk '{print $NF}')
mkdir -p /tmp/qmanager_sessions && date +%s > /tmp/qmanager_sessions/$T
# then: curl -b "qm_session=$T" http://192.168.3.1:8080/cgi-bin/quecmanager/<path>
```

The UI password is `<redacted-password>` (`/etc/qmanager/auth.json`), but minting is faster
and does not consume rate-limit budget. Never mint into a *shared* token file
while another agent is mid-run; use your own token variable.

## AT access — the one way that is safe

```
qcmd "AT+CMD"      # /data/qmanager/bin/qcmd — flocks /tmp/qmanager_at.lock,
                   # calls atcli_smd11, passes stdout, exits 1 on ERROR
/bin/atcmd "AT+CMD"  # vendor client; use under `timeout 15`, no lock of ours
```

**Hard rules, learned from an outage (docs/09-features.md):**

1. `atcmd_daemon` serves **one request at a time with no timeout**. A command the
   modem never answers wedges every later client, including `/bin/dialer`, and
   can drop the WAN. Always wrap raw `/bin/atcmd` in `timeout 15`.
2. Prefer `qcmd` — it serialises through the shared flock.
3. Do **not** run a burst of parallel AT commands from several agents at once.
   Serialise: one AT probe at a time, with a sleep between.
4. If AT is wedged: `killall -9 atcmd_daemon; /etc/initscripts/start_atcmd_daemon start`
   (the dialer re-dials within a minute). Leave that as the last resort.
5. Never restart `dialer`, `QCMAP`, or anything owning the PDP context.
6. Never touch modem firmware, MBN/PDC profiles, or `/bin/dialer`.

## Filesystem rules

| Path | State |
|---|---|
| `/`, `/firmware` | read-only ubifs — never write |
| `/etc`, `/data` | writable + persistent (same volume) |
| `/tmp`, `/run` | tmpfs, lost on reboot |

Back up anything you overwrite to `/data/zlt-backups/<YYYYMMDD>/<module>/`.

## QManager deploy on the X16

The unit files are `/etc/systemd/system/qmanager-{httpd,poller,ping,traffic}.service`
and `/etc/initscripts/start_qmanager` (boot hook, called from `/etc/initscripts/StartTZApp`).
`systemctl enable` alone is **not** enough on this firmware — see docs/09.

`/data/qmanager/www` is a **Next.js static export**; the API lives under
`/data/qmanager/www/cgi-bin/quecmanager/` and is served by
`busybox httpd -p 8080 -h /data/qmanager/www`.

After replacing a CGI script the file must stay mode `0755` and `root:root`.
`/data/qmanager/bin/qm_fixperms.sh` exists if perms drift.

## Definition of done for any fix here

1. Reproduced the failure with a concrete request + response (not a guess).
2. Root cause named in one sentence, with the evidence that proves it.
3. Fixed in the **source tree** (`/tmp/qm` and, where it belongs, this repo's
   `deploy-x16/`), not only patched live on the device.
4. Deployed to the device and verified with the same request that failed.
5. Host-side unit test added that fails before the fix and passes after, with
   the modem replies captured as a fixture (no device needed to run it).
6. Rollback described (what to restore, from where).

## What is known broken right now (2026-10-26 capture)

See `README.md` in this directory for the full evidence. Summary:

| Feature | Symptom | Established root cause |
|---|---|---|
| Neighbour cell scan | `{"status":"complete","results":[]}` | `atcli_smd11` maps **all** `AT+QENG*` to the serving-cell translator, hiding the native `AT+QENG="neighbourcell"` which returns 12 real rows |
| Speedtest | `{"available": false}` | no Ookla `speedtest` binary installed; GreenPacket has an ARMv7 musl static build that will run here |
| Tower schedule | `no_lock_targets` | `AT+QNWLOCK` unsupported by SIM8260E, so `tower/status.sh` reads `lte_read_ok:false` and there is never a lock target to schedule |
