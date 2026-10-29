# Recon brief — shared environment facts for parallel investigators

Read this before you touch anything. It is the same for every investigator.

## The two systems

| | What | Where |
|---|---|---|
| **Stock UI** | Vendor "simcom_war" web app (the customer's reference: it shows 5G, live metrics, fast SMS) | device, `http://127.0.0.1/` (port 80) |
| **QManager** | GreenPacket Next.js UI ported to this box (our UI) | device, `http://127.0.0.1:8080/` (password `<redacted-password>`) |

## Local trees

| Tree | Path | Notes |
|---|---|---|
| This repo | `/Users/emumba/Downloads/projects/zlt-x16` | docs, `deploy-x16/` payload, `router-fix/`. Follow `AGENTS.md`. |
| **QManager source** | `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager` | The real source. Next.js `app/`, `components/`, `lib/`; CGI shell in `scripts/www/cgi-bin/quecmanager/**`; helpers in `scripts/usr/lib/qmanager/`, `scripts/usr/bin/`; prebuilt binaries in `dependencies/` (`qmi/`, `sms_tool`, `smartdns`, `atcli_smd11`). |
| Staged copy | `/tmp/qm` | A build staging copy, no git. Prefer the greenpacket tree. |

On the device the deployed result is:
`/data/qmanager/{www,bin,lib,etc}` + `/etc/systemd/system/qmanager-*.service`.

Build/deploy (you are **read-only** in this phase — do not run it):
`cd deploy-x16 && QM_SRC=<tree> ./install.sh --build` then `./install.sh`.

## Device access

```sh
ssh zlt-root                       # root@192.168.3.1, key auth
```

**Rules that are not optional:**

- The link drops roughly one connection in three. Give every ssh call
  `-o ConnectTimeout=10 -o ServerAliveInterval=5` and be ready to retry.
  A failed call is usually the link, not the answer.
- `scp` does **not** work (no sftp-server). Pull with `ssh host 'tar cf - .'`,
  push with `ssh host 'cat > /path' < file`.
- No `ip`/`ifconfig`/`getent`/`jq`/python in PATH on the device. Busybox is at
  `/bin/busybox.nosuid`. There *is* `curl`, `wget`, `timeout`, `flock`.
- `/` and `/firmware` are read-only ubifs. `/etc` and `/data` are writable and
  persistent. `/tmp` is tmpfs.

**You are read-only on the device in this phase.** Probe, capture, measure — do
not install, edit, restart services, or change state. If a probe would change
state, do not run it; describe it in the fix plan instead.

## AT commands — the safety rule that has already caused an outage

There is no AT tty. AT is IPC to `atcmd_daemon` via `/bin/atcmd`, and the daemon
serves **one request at a time with no timeout**. A command the modem never
answers wedges every later client including `/bin/dialer`, and the router drops
the WAN (this happened; see `docs/09-features.md`).

Therefore:

- Prefer `/data/qmanager/bin/qcmd 'AT+...'` — the allowlisted dialect shim.
  A command outside the allowlist answers `ERROR` without touching the daemon.
- Wrap **every** call: `timeout 10 /data/qmanager/bin/qcmd 'AT+CGMM'`.
- Never send `AT+CRSM` (never answered on this firmware).
- Keep it to a handful of commands, one at a time. No loops over a command list.
- `/bin/atcmd` directly is a last resort, single command, under `timeout`.

## Probing the stock UI

It answers on `127.0.0.1` from the device itself. Use `curl` there — do not try
to reach port 80 through the LAN unless you must.

Its assets live on the device under the vendor web root; find it with
`ls /var/www /web /usr/share/*www* 2>/dev/null` and the httpd config. The JS is
minified but the request paths in it are readable and are the authoritative
answer to "how does the vendor get this value".

Useful first moves:

```sh
ssh zlt-root 'timeout 10 curl -s http://127.0.0.1/ | head -50'          # index
ssh zlt-root 'ps w | grep -iE "httpd|web|lighttpd|nginx"'                # which server
ssh zlt-root 'ls -la /etc/nginx /etc/lighttpd* /var/www 2>/dev/null'     # web root
```

## What a good deliverable contains

Every investigation ends with a written report at the path you were given,
containing:

1. **Reproduced symptom** — the exact request/command you ran and what came back.
2. **Root cause** — with `file:line` in the QManager source and/or the device
   file/log that proves it. Not a hypothesis: the line that is wrong.
3. **How the stock UI does it** — the endpoint/AT/QMI/db it uses, with evidence.
4. **Fix plan** — the precise files to change and what to change in them. Enough
   that a different agent can implement it without re-investigating.
5. **How to verify** — the command and the expected output after the fix.
6. **Risks** — what could break, and what must not be touched.

Do not speculate in the report. If something is unknown, write `UNKNOWN` and say
what would resolve it.
