# QManager (branch `greenpacket`) — Build, Serving, and Runtime Contract

`/tmp/qm` is **not** stock upstream QManager. It is a fork of `RafayGhafoor/QManager-RM520N`
whose `greenpacket` branch already ports the app to a *second, non-Entware, read-only-rootfs
Quectel device* (GreenPacket O5A Pro / RG520N-EB). That port is the single most valuable thing in
this repo for the ZLT X16 work: it is a working precedent for exactly the class of change we need,
and it is documented in `deploy/README.md` + `AGENTS.md` + `memory.md`.

Two serving stacks coexist in-tree: the **upstream Entware/lighttpd/systemd** stack
(`scripts/`) and the **greenpacket-lite** stack (`deploy/`). Know which you are reading.

## Files Retrieved

1. `next.config.ts` (1-24) — static export config; the whole "server" story.
2. `package.json` (5-14) — `build` / `package` scripts; bun as the toolchain.
3. `build.sh` (44-120, 120-260, 260-300) — staging, dependency preflight, version stamping, tarball.
4. `deploy/qm_serve.sh` (1-140) — busybox-httpd server manager, port derivation, PID handling.
5. `deploy/qmanager-httpd.service` (1-40) — systemd unit for the above.
6. `scripts/usrdata/qmanager/lighttpd.conf` (1-64) — upstream lighttpd config: port 80, 443, CGI, proxy.
7. `scripts/etc/systemd/system/lighttpd.service` (1-20) — `/opt/sbin/lighttpd -D -f ...`.
8. `scripts/install_rm520n.sh` (33-60, 418-570, 983-1420, 1530-1760, 3581-3780) — upstream installer.
9. `qmanager-installer.sh` (24-50, 78-90) — self-bootstrapping downloader; hardcoded `/usrdata` platform check.
10. `scripts/usr/lib/qmanager/cgi_base.sh` (15-60, 85-95) — PATH, CA bundle, TZ, HTTP headers.
11. `scripts/usr/lib/qmanager/cgi_auth.sh` (20-40, 142-200, 542-563) — cookie/session auth.
12. `scripts/usr/lib/qmanager/platform.sh` (1-140) — init-system abstraction (`svc_*`).
13. `scripts/usr/lib/qmanager/hw_profile.sh` (1-200) — the *existing* multi-target machinery.
14. `scripts/usr/bin/qcmd` (1-70) — the single AT gatekeeper; `/dev/smd11`, flock, `atcli_smd11`.
15. `scripts/usr/bin/qmanager_poller` (1-80) — poller tiers, cache file, cadence.
16. `scripts/usr/www/cgi-bin/quecmanager/**` (87 `.sh`) — the entire HTTP API.
17. `deploy/README.md` (1-140, 180-344) — the greenpacket port recipe (read this first).
18. `deploy/qm_pathfix.sh` (1-100) — path relocation `/usr/lib/qmanager` → `/usrdata/qmanager/lib`.
19. `deploy/qm_boot_hook.sh` (1-90) — boot-transaction workaround via `/etc/init.d/turin_web.sh`.
20. `deploy/atcli_smd11`, `deploy/sms_tool`, `deploy/sudo` — shims replacing Entware/Quectel pieces.
21. `deploy/qmanager-{poller,ping,dpi,traffic,ippt,dns-edge}.service` — per-daemon units w/ PATH notes.
22. `native/qmanager_atd/src/main.rs` (1-45) — Rust AT broker (`qcmd` drop-in, unix socket).
23. `memory.md` (300-330), `AGENTS.md` (100-180) — device facts, hard rules, port map.

## 1. Build / packaging

**Frontend = a pure static export. There is no Node runtime on the device ever.**

```ts
// next.config.ts:2-6
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
```
`trailingSlash: true` matters: every route is `route/index.html`, so a docroot-based server needs no
rewrite rules. The commented-out `rewrites()` block (`next.config.ts:9-22`) is the only dev-time
proxy for `/cgi-bin/*` — proving the frontend calls the backend **same-origin, relative paths only**.

`package.json:8` `"build": "bun --bun next build"` → `out/`. `"package": "bun run icons:check && bash build.sh"`.

`build.sh` stages a release tarball:
- `build.sh:47-52` hard-fails unless `dependencies/{atcli_smd11,sms_tool,jq.ipk,dropbear_*.ipk}` exist.
- `build.sh:63-77` copies `out/` → `STAGING/out`, `scripts/*` → `STAGING/scripts`, deliberately skipping
  `install_rm520n.sh|uninstall_rm520n.sh|test`.
- `build.sh:80-96` reads `VERSION` from `package.json` and **seds it into `install_rm520n.sh`'s `VERSION=` line**
  (two-phase: `VERSION.pending` at preflight, finalized at the end).
- `build.sh:120-152` lints that every `CORE_SERVICES` unit exists in `scripts/etc/systemd/system/`
  (`lighttpd qmanager-firewall qmanager-setup qmanager-ping qmanager-poller qmanager-ttl qmanager-mtu
  qmanager-imei-check qmanager-watchcat qmanager-tower-failover qmanager-auto-update qmanager-dpi qmanager-dpi-ensure`).
- `build.sh:154-215` stages deps; `build.sh:216-224` builds the Go Discord bot via `build-discord-bot.sh`.
- `build.sh:226-232` `tar czf qmanager-build/qmanager.tar.gz -C qmanager-build qmanager_install` + `sha256sum.txt`.

`qmanager-installer.sh` is the curl|bash entry point: fetches the release tarball from
`dr-dolomite/QManager-RM520N` (`qmanager-installer.sh:26-28`) and **hard-refuses to run unless `/usrdata`
exists** (`qmanager-installer.sh:78-83`). That is the first Quectel-specific assumption an X16 image
will trip.

## 2. Serving — two stacks, pick one

### Upstream stack (Entware + lighttpd + systemd)

Web server: **lighttpd from Entware**, `/opt/sbin/lighttpd`, unit `scripts/etc/systemd/system/lighttpd.service:10`
(`ExecStart=/opt/sbin/lighttpd -D -f /usrdata/qmanager/lighttpd.conf`), with `ExecStartPre=/opt/sbin/lighttpd -tt -f ...` as a config test.

```conf
# scripts/usrdata/qmanager/lighttpd.conf:2,19-27,42-52,55-63
server.username  = "www-data"
server.groupname = "dialout"
server.port      = 80
server.document-root = "/usrdata/qmanager/www"
index-file.names     = ( "index.html" )
$SERVER["socket"] == "0.0.0.0:443" { ssl.engine = "enable" ... }
$HTTP["scheme"] == "http" { url.redirect = ("" => "https://${url.authority}${url.path}${qsa}") }
$HTTP["url"] =~ "/cgi-bin/" { cgi.assign = ( "" => "" ) }
$HTTP["url"] =~ "(^/console)" { proxy.server = ("" => ("" => ("host" => "127.0.0.1", "port" => 8080))) }
```
- **Document root** `/usrdata/qmanager/www`; **CGI root** `<docroot>/cgi-bin/quecmanager/`; `cgi.assign ("")=("")`
  means "shebang decides the interpreter, execute anything in cgi-bin".
- Default listen **80**, plus **443** with a self-signed cert at `/usrdata/qmanager/certs/server.{key,crt}`,
  and an unconditional HTTP→HTTPS redirect. So the effective UI URL upstream is `https://<ip>/`.
- No HTTP Basic auth: `lighttpd.conf:6` "QManager uses cookie-based session auth at the CGI level".

### greenpacket-lite stack (busybox httpd on 8080) — the one that actually ships on the fork

`deploy/qm_serve.sh:1-20` states the reasons verbatim: `lighttpd is not installed here and cannot be:
the rootfs is a read-only squashfs, so Entware (/opt) can never be bootstrapped`, and port 80 is the
vendor UI (`busybox httpd -f -p 80 -h /web/v2`).

```sh
# deploy/qm_serve.sh:22-30
QM_ROOT=/usrdata/qmanager
PORT="${QM_PORT:-8080}"
PIDFILE=/run/qmanager-httpd.pid
DOCROOT="$QM_ROOT/www"
PATH="$QM_ROOT/bin:/usr/bin:/bin:/sbin:/usr/sbin"; export PATH
```
- Start: `busybox httpd -p "$PORT" -h "$DOCROOT"` (`qm_serve.sh:93`), run **as root** (no `-u`) so CGI
  can issue AT and write `/etc/qmanager` (`qm_serve.sh:14-17`).
- No pidfile support in busybox httpd → process is found by `ps | grep -F "httpd -p $PORT -h $DOCROOT"`
  (`qm_serve.sh:57-63`).
- Unit `deploy/qmanager-httpd.service:8-18`: `Type=forking`, `PIDFile=/run/qmanager-httpd.pid`,
  `Environment=PATH=/usrdata/qmanager/bin:...`, `ExecStartPre=/usrdata/qmanager/bin/qm_fixperms.sh`.

**Port hardcodes — every occurrence (verified by grep over `scripts/ deploy/ *.sh *.md`):**

| Port | Location | Meaning |
|---|---|---|
| 80 | `scripts/usrdata/qmanager/lighttpd.conf:20` | upstream docroot port (`server.port`) |
| 443 | `scripts/usrdata/qmanager/lighttpd.conf:42` | TLS socket + `:50` redirect |
| 8080 | `deploy/qm_serve.sh:23` | **the only server port that varies** (`QM_PORT` override) |
| 8080 | `deploy/qmanager-httpd.service:2` | description string only |
| 8080 | `scripts/etc/systemd/system/qmanager-console.service:9` | **ttyd** `-i 127.0.0.1 -p 8080` — collides with the fork's UI |
| 8080 | `scripts/usrdata/qmanager/lighttpd.conf:63` | `/console` proxy target (same ttyd) |
| 989 | `scripts/usr/lib/qmanager/dpi_state.sh:70` `DPI_PORT="989"` | tpws listener + `--to-ports 989` REDIRECT (`:85,256-285`) |
| 80,443 | `dpi_state.sh:85,333-347`, `qmanager_dpi_run:197` | intercepted LAN ports (iptables match) |
| 80/8083/8090-8092/11080/18080 | `AGENTS.md:108-110` | ports owned by the vendor stack — never take |

No `listen 80` anywhere else; the port is not otherwise parameterised. `qm_serve.sh` is the only
place a port change is cheap.

## 3. Backend

**Inventory: 87 `.sh` CGI endpoints** under `scripts/www/cgi-bin/quecmanager/`, grouped in 15 areas:
`at_cmd(13) auth(5) bands(4) cellular(8) device(1) frequency(2) monitoring(3) network(11) profiles(8)
public(3) scenarios(5) settings(2) system(16) tower(5) vpn(1)`. Shared libraries: 30 files in
`scripts/usr/lib/qmanager/` (`cgi_base.sh cgi_auth.sh cgi_at.sh parse_at.sh platform.sh hw_profile.sh
dpi_state.sh ttl_state.sh ippt.sh qmi_read.sh phy_metrics.sh sim_registry.sh ...`); ~54 helper
executables in `scripts/usr/bin/` (`qcmd qmanager_poller qmanager_ping qmanager_dpi_run qmanager_setup
qmanager_update qmanager_health_check ...`).

**Frontend → backend contract.** Every hook hardcodes an absolute path under `/cgi-bin/quecmanager/`:
`hooks/use-auth.ts:5-9` (`auth/check.sh`, `auth/login.sh`, `auth/logout.sh`, `auth/password.sh`),
`hooks/use-band-locking.ts:35`, `hooks/use-sms.ts:23` (`cellular/sms.sh`), `hooks/use-cellular-settings.ts:48`,
`hooks/use-alerts.ts:23`, `lib/i18n/language-pack-client.ts:15`. So: **the URL namespace
`/cgi-bin/quecmanager/<area>/<endpoint>.sh` is the runtime contract**, no `/api`, no JSON-RPC, no
server-side render. Data files are read directly by the browser too: `/live-traffic.json`
(`deploy/qmanager-traffic.service:1-10`).

Each endpoint is a POSIX shell script that: sources `/usr/lib/qmanager/cgi_base.sh`, emits CGI headers
itself, and does its own method routing:

```sh
# scripts/www/cgi-bin/quecmanager/public/overview.sh:12-30
_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh
qlog_init "cgi_public_overview"
cgi_headers
cgi_handle_options
if [ "$REQUEST_METHOD" != "GET" ]; then cgi_method_not_allowed; exit 0; fi
```
`cgi_headers` (`cgi_base.sh:85-92`) writes `Content-Type: application/json`, `Cache-Control: no-store`,
and permissive CORS. Authentication is enforced *inside* the script via `require_auth`, which is called
from `cgi_base.sh` at load time unless `_SKIP_AUTH=1`.

**Auth / session.**
- Password: salted SHA-256 in `/etc/qmanager/auth.json` (`cgi_auth.sh:5-6,50-55`), `openssl dgst -sha256`.
- Session: token = 32 random bytes hex; **one file per session** under `/tmp/qmanager_sessions/<token>`
  containing the creation epoch (`cgi_auth.sh:7,159-198`). TTL 3600 s (`:24`). tmpfs ⇒ reboot logs everyone out.
- Cookies: `qm_session` (HttpOnly, SameSite=Strict) + `qm_logged_in=1` (JS-readable indicator);
  set/cleared in `cgi_auth.sh:142-152`, read in `hooks/use-auth.ts:20-24`, 401 → `/login/` redirect in
  `lib/auth-fetch.ts:9-19`.
- Rate limiting: `/tmp/qmanager_auth_attempts.json` + `.lock` (flock), 5 attempts, progressive ladder
  `30 120 300 900` s (`cgi_auth.sh:30-35`).
- Setup gate: `is_setup_required()` (`cgi_auth.sh:38-42`) — no `auth.json` ⇒ every endpoint returns
  `{"state":"setup_required"}` and the UI reroutes to `/setup/`.
- **Textbook auth is required on every authed request** — so `require_auth` runs ~1.5×/s on the dashboard
  (`cgi_auth.sh:108-113` explicitly optimises process count for this).

**Helper daemons** (all write tmpfs JSON, all read by CGIs; no IPC/RPC):

| Daemon | Unit | Purpose | State |
|---|---|---|---|
| `qmanager_poller` | `qmanager-poller.service` | The only AT consumer for status. Tiered: Tier 1 (`AT+QENG`, `AT+QCAINFO`) every cycle, Tier 1.5 (QRSRP/QRSRQ/QSINR) every 5, Tier 2 (~15: QTEMP/COPS/CPIN/QUIMSLOT/CGCONTRDP/QMAP) , Tier 3 PHY (~60 s, `ubus call modemd status`), boot-only identity | `/tmp/qmanager_status.json` (`qmanager_poller:70-72`); PHY archive `/usrdata/qmanager/metrics/YYYY-MM-DD.csv`; cadence ~3.7-4.0 s despite `POLL_INTERVAL=2` (`:12-14`) |
| `qmanager_ping` | `qmanager-ping.service` | internet reachability + latency; `DNS_LAN_RESOLVER=192.168.0.1` (`qmanager-ping.service:36`) | `/tmp/qmanager_ping.json`, `/tmp/qmanager_ping_history.json` |
| `qmanager_traffic` (Rust, `native/qmanager_traffic`) | `qmanager-traffic.service` | 1 Hz hardware octet counters via `ETHTOOL_GSTATS` ioctl; `/proc/net/dev` only fallback (IPA bypass) | `/tmp/qmanager_traffic.json`, hardlinked to docroot via symlink `www/live-traffic.json` |
| `qmanager_dpi_run` (+`tpws`) | `qmanager-dpi.service`, `-dpi-ensure.service/.timer` | TCP desync bypass on `bridge0` tcp/80,443 → `REDIRECT --to-ports 989`; QUIC handled by a separate `REJECT` | `dpi_state.sh:70-90`; binary `/usrdata/qmanager/bin/tpws` |
| `qmanager_dns_apply` / smartdns | `qmanager-dns.service`, `-dns-edge.timer`, `-dns-stats.timer` | resolver config + measured edge selection | `/tmp/qmanager_dns.json`, `qmanager_dns_edge.json` |
| `qmanager_atd` (Rust, opt-in) | `deploy/qmanager-atd.service` | AT broker owning the port, unix socket, same flock `/tmp/qmanager_at.lock`; `Before=qmanager-poller.service` | `/var/run/qmanager_atd.sock{,.proto}` |
| `qmanager_ippt_apply --boot` | `qmanager-ippt.service` | re-apply IP passthrough each boot (runtime-only setting) | `/etc/qmanager/ippt.json` |

Other `/tmp/qmanager_*.json` state: `events, event_state, health_check, cell_scan_result,
neighbour_scan_result, neighbours_live, signal_history, pci_state, profile_state, session,
discord_*, email_log, language_install, dpi_install, dpi_verify, sites_live`.

## 4. Runtime dependencies

**Hard requirements (each one is a break-the-whole-UI dependency):**

| Bin | Where it comes from | Used by |
|---|---|---|
| `jq` | Entware (`jq.ipk` bundled) `/opt/bin/jq`, symlinked to `/usr/bin/jq` (`install_rm520n.sh:1326-1327`); on the fork, a static ARMv7 binary in `/usrdata/qmanager/bin/jq` | **142 files** — every JSON response, every parse. Non-negotiable |
| `atcli_smd11` | Quectel reference binary (`dependencies/atcli_smd11`), talks to `/dev/smd11`; the fork substitutes `deploy/atcli_smd11`, a **shell shim** on `/dev/at_mdm0` | `qcmd` only (`qcmd:66-67`) |
| `sms_tool` | vendored obsy/sms_tool, `dependencies/sms_tool`; fork wraps it as `deploy/sms_tool` (defaults `-d /dev/smd7` + vendor radio lock) | 11 files (`cellular/sms.sh`, SMS forward, alerts) |
| `lighttpd` (+`mod-cgi,-openssl,-redirect,-proxy`) | Entware `/opt/sbin/lighttpd` (`install_rm520n.sh:1283-1301`) | the entire UI upstream; **absent on the fork** (busybox httpd instead) |
| `sudo` | Entware `/opt/bin/sudo`; fork uses `deploy/sudo` passthrough | CGI→root helper calls |
| `flock`, `timeout`, `openssl`, `curl`/`wget` | Entware or busybox applets | AT lock (29 files), `qm_timeout` wrapper (40 files), hashing, downloads |
| `iptables` / `ip6tables` | vendor `/usr/sbin` | 14 files (DPI, firewall, TTL, IPPT) |
| `ttyd` | fetched on demand | web console; **broken on the fork** (port 8080 collision) — `memory.md:185` |
| `tpws` | downloaded at runtime by `qmanager_dpi_install` | Traffic Engine |
| `smartdns`, `speedtest` (Ookla CLI), `qmicli`+`libqmi-glib.so.5`+`libqrtr-glib.so.0`, `dropbear`, `msmtp`, `tailscaled` | payload (`deploy/README.md:92-104`) | DNS, speedtest page, neighbour cells, SSH, email alerts, VPN |
| `ubus` | vendor | 2 files — `phy_metrics.sh` does `ubus call modemd status` |

**PATH handling is scattered and is one of the top porting hazards.**
- `cgi_base.sh:18` → `export PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"`.
- `deploy/qm_serve.sh:28` and every `deploy/*.service` use `PATH=/usrdata/qmanager/bin:/usr/bin:/bin:/sbin:/usr/sbin`.
  `deploy/qmanager-dns-edge.service:35` documents the failure mode: *"jq lives in /usrdata/qmanager/bin
  (the shim), NOT in the default PATH a timer inherits … without this line every JSON build fails and
  the unit still exits 0."*
- `deploy/qm_pathfix.sh:88-100` rewrites `export PATH="` in `cgi_base.sh`, `downloader.sh` and two
  `speedtest_*.sh` to prepend the new bin dir.
- `scripts/etc/profile.d/qmanager-path.sh` covers serial-console logins only (cosmetic).
- `install_rm520n.sh:203-208` probes `/opt/bin/timeout` behaviour (`-t SECS` vs positional) → `qm_timeout()`.
- `CURL_CA_BUNDLE` override at `cgi_base.sh:33-35` (device CA store is stale); `TZ` POSIX-string at
  `cgi_base.sh:47-58` (no tzdata, busybox ignores `/etc/TZ`).

## 5. Everything Quectel/RM520N/Entware/systemd-specific that must change

**A. AT transport / modem dialect (highest risk — this is the real port)**
1. `/dev/smd11` — **149 references** across `scripts/`. Anchor points: `qcmd:67` (`AT_DEVICE=/dev/smd11`),
   `qcmd:66` (`AT_CLI=/usr/bin/atcli_smd11`), `scripts/etc/udev/rules.d/99-qmanager-smd11.rules:12`
   (`KERNEL=="smd11", ACTION=="add", RUN+="/usr/lib/qmanager/qmanager_smd11_udev.sh"`),
   `scripts/etc/udev/scripts/qmanager_smd11_udev.sh`, and `qmanager_setup`, `qmanager_health_check`,
   `qmanager_cfun_fix`, `qmanager_sms_forward`, `phy_metrics.sh`, `cgi_at.sh`, `sms_alerts.sh`.
   The fork's answer is a shim that keeps the *name* `atcli_smd11` and changes the device
   (`deploy/atcli_smd11:33` `AT_DEV="${AT_DEV:-/dev/at_mdm0}"`). For SIMCom/SDX55-QCMAP we need the
   same shape but on whatever AT channel the SIMCom OSS dialer stack exposes — or, better, replace
   `atcli_smd11` with the Rust broker (`native/qmanager_atd`, `AT_DEV` env, `deploy/qmanager-atd.service:15-16`).
2. **`AT+Q*` vendor commands: 21 distinct, 35 files.** `AT+QNWCFG(52) AT+QNWPREFCFG(34) AT+QNWLOCK(23)
   AT+QUIMSLOT(21) AT+QICSGP(21) AT+QCAINFO(18) AT+QMAP(16) AT+QENG(14) AT+QTEMP(11) AT+QSCAN(11)
   AT+QMBNCFG(11) AT+QCCID(11) AT+QRSRP(10) AT+QNETRC(6) AT+QSINR(5) AT+QSIMDET(5) AT+QRSRQ(5) AT+QSIMCFG(4)`.
   SIMCom SIM8260E does **not** implement most of these (band lock, CA info, MBN config, QMAP, QUIMSLOT,
   QSCAN, QTEMP). Parsers live in `scripts/usr/lib/qmanager/parse_at.sh` (+ `phy_metrics.sh`,
   `tower_lock_mgr.sh`, `dpi_state.sh`) — these must be re-derived per command, not renamed.
   The fork's precedent is instructive: RG520N-EB lacks `AT+QTEMP`, `AT+QMAP="WWAN"`, `AT+QMAP="LANIP"`,
   `AT+QMAP="DHCPV4DNS"` and they simply source temperature from thermal zones and addressing from `ip`
   (`deploy/README.md:287-291`).
3. `/etc/quectel-project-version` — parsed for identity at `hw_profile.sh:41` (`QUECTEL_VERSION_FILE`),
   `install_rm520n.sh:447-500`, `qmanager_poller` (Tier 2). Contract: 5 column-aligned lines
   (`Project Name: / Project Rev : / Branch  Name: / Custom  Name: / Package Time:`), documented with
   `od -c` evidence in `hw_profile.sh:57-69`. A SIMCom firmware has no such file — `qm_hw_model()`
   returns `unknown`, which drops the tier to `fallback` (advisory only, so nothing breaks, but
   `install_rm520n.sh:447` warns and prompts).
4. `socat-at-bridge` conflict removal (`install_rm520n.sh:571-592`, `CONFLICT_PACKAGES="socat socat-at-bridge"`) —
   Quectel-stack-specific; irrelevant/harmful elsewhere.
5. SMS on `/dev/smd7` + vendor `radio-handler.sh` lock protocol (`deploy/sms_tool:1-45`, `GP_ATLOCK=/tmp/gp-radio.lock`) — GreenPacket-specific.
6. `AT+CGMM` identity gating in `deploy/qm_wait_modem.sh` (poller `ExecStartPre`) — model string is hardcoded per device.

**B. Entware / `/opt`**
7. `install_rm520n.sh:106` `OPKG=/opt/bin/opkg`; `:976-982` `qm_entware_complete()`; `:1130-1240` full
   Entware bootstrap from `http://bin.entware.net/armv7sf-k3.2/installer` (**arch hardcoded**);
   `:1141-1170` writes `opt.mount` (`/usrdata/opt` bind → `/opt`) and `start-opt-mount.service`;
   `:657-760` `harden_entware_unit_modes()`, `ensure_usrdata_wait_unit()`.
8. `:1283-1301` installs lighttpd + 4 module packages; `:1326-1332` symlinks `jq`/`curl` into `/usr/bin`.
9. `install_rm520n.sh:610-631` `neutralize_entware_lighttpd()` disables `/opt/etc/init.d/S80lighttpd`.
10. `/opt/bin/timeout` probe `:203-208`; `/opt/share/zoneinfo` + `zoneinfo-all` package `:771-800`
    (RM520N-GL's `/usr/share/zoneinfo` ships empty).
11. `cgi_base.sh:18` PATH prefix `/opt/bin:/opt/sbin` hardcoded; `platform.sh:29-33` sudo resolution
    `/opt/bin/sudo` → `/usr/bin/sudo`; `install_rm520n.sh:64-76` `detect_sudo()` → `/opt/etc/sudoers.d`.

**C. Filesystem layout / read-only root**
12. `install_rm520n.sh:46-58` — `QMANAGER_ROOT=/usrdata/qmanager`, `WWW_ROOT=/usrdata/qmanager/www`,
    `CGI_DIR=/usrdata/qmanager/www/cgi-bin/quecmanager`, `LIB_DIR=/usr/lib/qmanager`,
    `BIN_DIR=/usr/bin`, `SYSTEMD_DIR=/lib/systemd/system`, `WANTS_DIR=/lib/systemd/system/multi-user.target.wants`.
    `/usrdata` (275 refs) is the GreenPacket ubifs volume name.
13. `install_rm520n.sh:530-537` `mount -o remount,rw /` preflight; `platform.sh:78-84` `_svc_ensure_rw()`;
    `qmanager_setup:10-13`. All assume a remountable root.
14. `deploy/qm_pathfix.sh:44` rewrites `/usr/lib/qmanager` → `/usrdata/qmanager/lib` **and**
    `/lib/systemd/system` → `/etc/systemd/system`; `:1-12` explains the read-only squashfs.
15. `qmanager-installer.sh:79-81` `check_platform()` requires `/usrdata` to exist.

**D. systemd / boot**
16. `platform.sh:52` `_SYSTEMCTL="/bin/systemctl"`; `:46-77` `svc_start/stop/restart/enable` (all `systemctl`);
    `:99-140` `svc_enable` writes **`/lib/systemd/system/multi-user.target.wants` symlinks directly**, not
    `systemctl enable` (documented reason at `:60-70`). Any non-systemd init breaks this file wholesale.
17. 29 unit files in `scripts/etc/systemd/system/` + `.timer` units (`qmanager-auto-update.timer`,
    `-dpi-ensure.timer`, `-dns-edge.timer`, `-dns-stats.timer`) → `.timer`/`.mount`/`WantedBy=` semantics.
18. `scripts/etc/init.d/qmanager` is a **leftover OpenWRT/procd script** (`#!/bin/sh /etc/rc.common`,
    `USE_PROCD=1`, `START=99`) — dead on this image, but shows the abstraction's ancestry.
19. `deploy/qm_boot_hook.sh:1-40` — the fork's boot workaround: PID 1 builds its transaction before the
    rw overlay exists, so `systemctl enable` is a lie; the hook *inserts* `start_service_async <unit>`
    lines into `/etc/init.d/turin_web.sh` (anchor: `systemctl daemon-reload`), idempotent, backed up once.
    **Any device without that exact init script needs an equivalent, different mechanism.**
20. `deploy/*.service` all set `StandardOutput=null` because *"systemd-journald is masked on this firmware"*
    (`qmanager-poller.service:12-16`) — logging goes to `/tmp/qmanager.log` via `qlog.sh`.

**E. Other device-specific assumptions**
21. `dpi_state.sh:70-71` `DPI_PORT="989"`, `DPI_LAN_IF="bridge0"`; `qmanager_firewall:18` `TRUSTED="lo bridge0 eth0"`;
    `qmanager_poller:1365` probes `bridge0 br-lan br0`. X16 LAN bridge name will differ.
22. `deploy/qmanager-ping.service:36` `DNS_LAN_RESOLVER=192.168.0.1` (hardcoded LAN IP).
23. Entware-vs-busybox divergence already patched in `qm_timeout()` (`install_rm520n.sh:230-274`) and
    documented in `.claude/agent-memory/busybox-portability-checker/` — treat busybox 1.3x as a target.
24. Architecture: everything is ARMv7 (`armv7sf-k3.2`, `armv7-unknown-linux-musleabihf`,
    `jq-linux-armhf`, `ookla-speedtest-*-linux-armhf`). `native/qmanager_atd/src/main.rs:1` claims
    "static aarch64-musl" while `deploy/README.md:82-86` pins armv7 — resolve this before cross-building.

## 6. Existing multi-target / portability machinery

There **is** a real abstraction layer, but it is identity-only — it does not abstract the AT dialect,
the web server, or the init system.

**a) `scripts/usr/lib/qmanager/hw_profile.sh` (493 lines) — the target profile system.**
Two axes deliberately never collapsed (`:6-13`): `MODEL` (`Project Name:`) governs form factor and
peripherals; `SoC` (`Branch  Name:`) governs counter orientation, IPA quirks, udev.
Public API: `qm_hw_model()` `:118`, `qm_hw_soc()` `:127`, `qm_hw_fw_fingerprint()` `:135`,
`qm_hw_form_factor()` `:197`, `qm_hw_variant()` `:206`, `qm_hw_tier()` `:160`, `qm_hw_write_profile()` `:257`,
`qm_hw_profile_needs_write()` `:452`, `qm_hw_self_heal()` `:472`.
Tier table (`:150-190`) is the **extension point**:
```sh
case "$model" in
    RM551E*) printf '%s\n' "incompatible" ;;
    RM520N*) printf '%s\n' "official" ;;
    RG501Q*) printf '%s\n' "community" ;;
esac
case "$soc" in SDX6X|SDX55) printf '%s\n' "community" ;; esac
printf '%s\n' "fallback"
```
Note **`SDX55` is already in the table** — SIM8260E is SDX55-class, so an X16 profile lands `community`
via the SoC arm today. `qm_hw_variant()` maps to `variants/<slug>/` overlay dirs (`:206-213`), which is
the designed place for per-target assets. Output is `/etc/qmanager/platform.json`
(`schema/model/soc/form_factor/tier/fw_fingerprint/caps`), written by the installer at preflight
(`install_rm520n.sh:518-556`) and self-healed every boot by `qmanager_setup`. `hw_profile.sh:14-20`
states the profile is **advisory, never a security boundary** — do not gate auth on it.

**b) `scripts/usr/lib/qmanager/platform.sh` (327 lines)** — the *init-system* abstraction
(`svc_start/stop/restart/enable/disable/reset_failed`, `run_iptables`, `pid_alive`). Header comment
`hw_profile.sh:4-8` explicitly warns that this file is "the INIT-SYSTEM abstraction left over from the
OpenWRT-to-systemd port", i.e. this is the seam to re-implement for a QCMAP/openwrt-ish init.

**c) `install_rm520n.sh` model arms** (`:447-500`): `RM551E*` hard die, `RM520N*` official,
`RG501Q*` community info-only, empty → warn, `*` → interactive confirm with `/dev/tty` fallback and
non-interactive auto-proceed for OTA. `--force` skips detection (`:441-445`).

**d) `deploy/` directory as a whole** — the proven "adapt, do not fork" pattern: shims
(`atcli_smd11`, `sudo`, `sms_tool`), a path rewriter (`qm_pathfix.sh`), a boot hook (`qm_boot_hook.sh`),
a modem-readiness gate (`qm_wait_modem.sh`, poller `ExecStartPre` with a 150 s budget), and per-daemon
`deploy/*.service` overrides whose headers itemise each upstream difference. `deploy/README.md:7-20`
is the canonical "why the stock installer cannot be used" table — **this is the template for the X16 port.**

**e) Downloader abstraction** — `scripts/usr/lib/qmanager/downloader.sh` + inline twin in
`qmanager-installer.sh:88-140`: curl preferred, wget accepted as a first-class fallback, TLS verified
by the transfer itself.

**f) Not present (gaps for us):** no `target`/`profile` build flag in `build.sh` or `package.json`;
no per-variant tarball; no web-server abstraction; no AT-dialect abstraction (parsers are
unconditional); `rg501/globe/greenpacket` appear only in docs and prose, never in a config switch.
`memory.md:309-330` records that Entware *is* achievable via an overlayfs of `/` and that the
intended end-state is "upstream package set + lighttpd on 8080" — i.e. the fork regards its
busybox-httpd stack as temporary.

## Architecture (one line)

Browser loads a Next.js static export from a CGI-capable web server; every interaction is a
`fetch()` to a shebang'd shell script under `/cgi-bin/quecmanager/`; the script authenticates from
`/tmp/qmanager_sessions/<token>`, reads pre-baked tmpfs JSON (written by root daemons) or issues AT
through `qcmd`→`atcli_smd11` (flock-serialised, exactly one AT owner at a time), and answers with `jq`
output. Nothing is server-rendered; there is no application server, no database, and no Node runtime
on the device.

## Start Here

`deploy/README.md` (lines 1-140) — it is simultaneously the best description of the *upstream*
runtime contract and a complete, field-proven recipe for re-targeting QManager at a non-Entware,
read-only-root, different-AT-port device. It is the closest existing analogue to the ZLT X16 problem.
Then `scripts/usr/lib/qmanager/hw_profile.sh` for the profile extension point, and
`scripts/usrdata/qmanager/lighttpd.conf` + `deploy/qm_serve.sh` for the two serving shapes.
