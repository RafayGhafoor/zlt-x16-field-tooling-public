# Recon — three QManager UI defects (Ethernet negotiation, Video Optimizer toggle, Tailscale install)

Device: `zlt-root@192.168.3.1` (`sdxlemur`, ARMv7, kernel 5.4.210), probed read-only on
2026-10-26 ~15:29–15:36 PKT. QManager payload root is `/data/qmanager`.

Sources of truth used:

| What | Path |
|---|---|
| QManager source (Next.js + CGI) | `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager` |
| X16 deployment module | `/Users/emumba/Downloads/projects/zlt-x16/deploy-x16` |
| Vendor UI (stock) | device `/tzwww` (mini_httpd :80), QManager = busybox httpd :8080 root `/data/qmanager/www` |

Verdict in one line each:

* **(A) Ethernet / Negotiation** — the value *is* obtainable (`/usr/sbin/ethtool eth0` →
  `Auto-negotiation: on`), but `ethernet.sh` greps the **capability** lines first and its
  `sed` is case-sensitive, so the parse always yields `Unknown`. One-line fix.
* **(B) Video Optimizer toggle** — `tpws` is installed and runnable, but
  **`qmanager-dpi.service` / `-ensure` were never deployed** by `deploy-x16`, so
  `svc_restart qmanager-dpi` fails and the CGI answers `engine_start_failed` *after*
  writing `enabled=1`. Fix = ship the three units (+ seed the hostlist).
* **(C) Install Tailscale** — the installer's inner script does `cd /usrdata`, and
  **`/usrdata` does not exist on the X16** (`/data` is the writable volume). Proven by the
  device's own failure marker + log. Not a network/arch/opkg problem: the tarball URL
  answers **HTTP 200, 30 597 557 bytes** from the device.

---

## (A) Ethernet status — "Negotiation" always `Unknown`

### 1. Reproduced symptom

The CGI cannot be called unauthenticated (`401 unauthorized`), so it was executed
directly on the device with the session check skipped (read-only, GET only):

```
ssh zlt-root 'cd /data/qmanager/www/cgi-bin/quecmanager/network && \
  _SKIP_AUTH=1 REQUEST_METHOD=GET QUERY_STRING= sh ./ethernet.sh'
```

```json
{
  "success": true,
  "link_status": "up",
  "speed": "1000Mb/s",
  "duplex": "full",
  "auto_negotiation": "Unknown",      <-- the defect
  "speed_limit": "auto",
  "supports_2500": true,
  "interface_present": true
}
```

The tile is labelled "Negotiation" and renders
`t("ethernet.tiles.negotiation.value_unknown")` = **"Unknown"** for any value other than
`on`/`off` (`components/local-network/ethernet/link-state-strip.tsx:277-283`, rendered at
`:356-359`; key table in `public/locales/en/common.json > ethernet.tiles.negotiation`).
So what the operator sees is a tile reading "Unknown" under the label "Negotiation" —
which reads as "not shown".

### 2. Root cause — exact line

`scripts/www/cgi-bin/quecmanager/network/ethernet.sh:82-87` (deployed copy is identical at
the same lines):

```sh
# --- Auto-negotiation ---
auto_neg_raw=$(printf '%s\n' "$ethtool_out" | grep -i "Auto-negotiation:" | head -1 | sed 's/.*Auto-negotiation:[[:space:]]*//')
case "$auto_neg_raw" in
    on|On|ON)   auto_negotiation="on" ;;
    off|Off|OFF) auto_negotiation="off" ;;
    *)          auto_negotiation="Unknown" ;;
esac
```

Two independent mistakes on one line:

1. `grep -i "Auto-negotiation:"` matches **four** lines in this PHY's `ethtool` output, and
   `head -1` picks the first — a *capability* line, not the setting:
   ```
   $ ethtool eth0 | grep -ic "Auto-negotiation:"     ->  4
   $ ethtool eth0 | grep -i "Auto-negotiation:" | head -1
   	Supports auto-negotiation: Yes
   ```
2. The `sed` is **case-sensitive** (`.*Auto-negotiation:`), so it does not strip the
   lowercase `auto-negotiation:` text — the whole raw line survives, and step 3 falls
   through to `Unknown`:

   ```
   $ ethtool eth0 | grep -i "Auto-negotiation:" | head -1 | sed 's/.*Auto-negotiation:[[:space:]]*//'
   	Supports auto-negotiation: Yes
   ```

   (And even if it *had* stripped, `Yes` is not in the `on|off` case list.)

Note the same `grep -i … | head -1 | sed` idiom is used for `Speed:` and `Duplex:` above it
(`:73-80`) but those are harmless there: `Speed`/`Duplex` have no capability-line
lookalikes, and both values come from sysfs first anyway.

### 3. What the device can actually supply — measured

```
eth0 -> .../0000:01:00.0/net/eth0            # PCIe-attached Realtek-class NIC (r8125)
eth0 operstate=up  speed=1000  duplex=full  carrier=1
/usr/sbin/ethtool   present, 301300 bytes, 2023-04-10 (vendor binary, works)
/sys/class/net/eth0/{speed,duplex,carrier,operstate}  present
/sys/class/net/eth0/  has NO autoneg/  attribute (checked full listing)
```

`ethtool eth0` on this box (excerpt, complete port config available):

```
Supported link modes: 10baseT/Half ... 1000baseT/Full 2500baseT/Full
Supports auto-negotiation: Yes
Advertised auto-negotiation: Yes
Link partner advertised auto-negotiation: Yes
Speed: 1000Mb/s      Duplex: Full      Port: Twisted Pair
Auto-negotiation: on
Link detected: yes
```

**Answer to "is the value obtainable at all, and from where": yes — `ethtool(8)` only.**
There is no sysfs attribute for it (unlike `speed`/`duplex`), and there is no switch/swconfig
layer (`ethtool` `Port: Twisted Pair`, single PCIe MAC, `eth0` is enslaved to `bridge0`
via `upper_bridge0`, no `swconfig`/DSA). `ethtool` is present at `/usr/sbin/ethtool`; if it
were ever absent the tile would have to say so honestly rather than print "Unknown".

### 4. How the stock vendor UI does it

* Page: `/tzwww/html/info/deviceInfo.html`; logic `/tzwww/js/info/deviceInfo.js`.
* It renders **one** Ethernet figure, labelled in `/tzwww/js/language/en.js` as
  `DOC.lbl.negotiattonRate = "Network port negotiation rate"`.
* Fetch path (`deviceInfo.js`, `getData`):
  `Page.postJSON({ json: { cmd: RequestCmd.DEVICE_INFO }, success: ... })` with
  `RequestCmd.DEVICE_INFO = 207` (`/tzwww/js/main.js`), i.e.
  `POST /cgi-bin/http.cgi` envelope `{method, cmd:207, sessionId}`.
* Mapping: `vm_deviceInfo.negotiattonRate = e.negotiatton_rate ? e.negotiatton_rate + " Mbps" : loading`.

So the vendor's "negotiation rate" is the negotiated **rate in Mb/s** (what our page shows in
the separate "Negotiated rate" tile, 1000 Mb/s here) — the vendor exposes **no**
autonegotiation on/off field at all. Our tile is a superset.

`UNKNOWN`: the numeric value the vendor UI prints on *this* box (it needs a vendor session —
`http.cgi` answers `{"success":false,"cmd":-1,"message":"SessionId parameter is missing"}`
without a login, and no vendor credentials were used). Resolution: log into `http://192.168.3.1/`
and read the device-info page; expected `1000 Mbps` because `/sys/class/net/eth0/speed` = 1000.

### 5. Fix plan

`scripts/www/cgi-bin/quecmanager/network/ethernet.sh`, replace lines 82-88 with an **anchored**
match plus a tolerant mapping (a `yes`/`no` spelling is what some drivers report):

```sh
# --- Auto-negotiation ---
# Anchored: this PHY's ethtool reports three capability lines ("Supports
# auto-negotiation: Yes", "Advertised auto-negotiation: Yes", "Link partner
# advertised auto-negotiation: Yes") BEFORE the settings line, and a
# case-insensitive unanchored grep took the first of those. Match only a line
# that starts with the key, and strip case-insensitively.
auto_neg_raw=$(printf '%s\n' "$ethtool_out" \
    | grep -m1 -i '^[[:space:]]*auto-negotiation:' \
    | sed -n 's/^[^:]*:[[:space:]]*//p' \
    | tr -d '\r' | tr -d '[:space:]')
case "$auto_neg_raw" in
    on|ON|On|yes|YES|Yes)   auto_negotiation="on" ;;
    off|OFF|Off|no|NO|No)   auto_negotiation="off" ;;
    *)                      auto_negotiation="Unknown" ;;
esac
```

Verified read-only on the device (same pipeline, run as a probe):
`fixed_parse=[on] -> mapped=on`.

Note the sed `s/.*Auto-negotiation:…//` must not be reused verbatim: it is the
case-sensitivity that loses the value.

### 6. How to verify

```sh
ssh zlt-root 'cd /data/qmanager/www/cgi-bin/quecmanager/network && \
  _SKIP_AUTH=1 REQUEST_METHOD=GET sh ./ethernet.sh' | grep auto_negotiation
# expected:  "auto_negotiation": "on",      (link up, autoneg enabled)
```

Cross-check against the source of truth: `ssh zlt-root '/usr/sbin/ethtool eth0 | grep "^.Auto-negotiation:"'`
→ `	Auto-negotiation: on`. Then unplug/replug (or `ethtool -s eth0 autoneg off` on a bench
unit) and confirm the field follows — do **not** do that on the live unit.

### 7. Risks

* The regex is the only change; no risk to the `speed_limit` POST path.
* Do not "improve" this by dropping the `Unknown` branch — a driver that reports neither
  `on` nor `off` must still be reported as unknown rather than silently rendered as "on".
* `supports_2500: true` is real (`2500baseT/Full` advertised); the speed-limit dropdown will
  offer 2500. Untested on hardware — a 2500 apply on a 1 GbE peer bounces the link.

---

## (B) Traffic Engine → Video Optimizer: toggle does not turn it on

### 1. Reproduced symptom

```
ssh zlt-root 'cd /data/qmanager/www/cgi-bin/quecmanager/network && \
  _SKIP_AUTH=1 REQUEST_METHOD=GET sh ./video_optimizer.sh'
```
```json
{"success":true,"enabled":true,"status":"stopped","uptime":"—",
 "packets_processed":0,"domains_loaded":0,"binary_installed":true,
 "kernel_module_loaded":false,"force_tcp":false,"force_tcp_active":false}
```

Then the exact write the UI sends (`saveEnabled(true)` →
`POST {"action":"save","enabled":true}`):

```
$ _SKIP_AUTH=1 REQUEST_METHOD=POST CONTENT_LENGTH=27 sh ./video_optimizer.sh < body.json
{
  "success": false,
  "error": "engine_start_failed",
  "detail": "settings saved but the engine did not start"
}
```

The UI path: `hooks/use-video-optimizer.ts` `saveEnabled()` → `json.success === false` →
`setError(detail)` → returns `false` → `components/local-network/traffic-engine/traffic-engine.tsx:242`
`toast.error("Couldn't change the bypass mode")`. Nothing is fetched again on the failure
branch, so the row snaps back to its previous selection on the next 2 s poll or stays
selected-but-dead; either way *the engine never runs*.

**Not** the cause (checked and cleared): the binary **is** deployed and **does** run —
`/data/qmanager/bin/tpws --version` → `github version v72.13 (87e0586…)`, ELF 32-bit ARM
EABI5 (`0x28`), `chmod +x`, and `dpi_binary_installed` returns 0. The X16 also has
`/dev/net/tun` (`c 10,200`) and `iptables` (`/usr/sbin/iptables -> xtables-legacy-multi`).
`docs/09-features.md:172` ("tpws is not deployed") is **stale** and should be corrected.

### 2. Root cause — exact lines

`scripts/www/cgi-bin/quecmanager/network/video_optimizer.sh:262-279` (Video Optimizer) and
`:325-341` (Full Bypass) — both do the same thing:

```sh
qm_config_set video_optimizer enabled "$EN_INT"     # :271  config written FIRST
...
svc_reset_failed qmanager-dpi
if ! svc_restart qmanager-dpi; then                 # :276
    cgi_error "engine_start_failed" "settings saved but the engine did not start"
```

`svc_restart` (`scripts/usr/lib/qmanager/platform.sh:64`) is
`systemctl restart qmanager-dpi.service`. On the device:

```
$ systemctl cat qmanager-dpi   ->  "No files found for qmanager-dpi.service."
$ ls /etc/systemd/system | grep -i dpi   ->  (nothing)
```

`qmanager-dpi.service` simply **was not deployed**. `deploy-x16/install.sh:60`:

```sh
UNITS="qmanager-httpd qmanager-poller qmanager-ping qmanager-traffic"
```

and `deploy-x16/start_qmanager` starts exactly that list plus `qmanager-guard.timer`. The
upstream units exist but were never added to the X16 module:

* `greenpacket-o5a-qmanager/scripts/etc/systemd/system/qmanager-dpi.service`
* `…/qmanager-dpi-ensure.service`, `…/qmanager-dpi-ensure.timer`
* (also `deploy/qmanager-dpi.service`, `deploy/qmanager-dpi-ensure.{service,timer}` — the
  deployment-flavoured copies that already document this exact failure in their header:
  *"the Traffic Engine could be installed and enabled and still never run … engine_start_failed
  … because systemd had no unit to start."*)

Second, independent gap: `domains_loaded: 0` and
`ls /etc/qmanager/video_domains.txt /etc/qmanager/video_domains_default.txt` → **both
missing**. `qmanager_setup:240-266` seeds the factory hostlist (and the `_default` copy)
but `qmanager_setup` is **never invoked** on the X16 (`grep -rn qmanager_setup deploy-x16/`
matches only the `qm_pathfix_x16.sh` file list). `dpi_build_args` passes
`--hostlist=/etc/qmanager/video_domains.txt`, so even with the unit in place, Video
Optimizer mode would start against a non-existent hostlist.

Third thing that is *not* a blocker but is a latent trap: `dpi_bind_addr()`
(`dpi_state.sh`) shells out to bare `ip`, which is only reachable because the unit and
`cgi_base.sh` both put `/sbin` on `PATH`. Measured: with
`PATH=/data/qmanager/bin:/usr/bin:/usr/sbin:/bin:/sbin`, `dpi_bind_addr` → `192.168.3.1`
and `dpi_build_args` →
`--port=989 --bind-addr=192.168.3.1 --filter-l7=tls,http --split-pos=1,midsld,sniext+1 --disorder=tls --hostlist=/etc/qmanager/video_domains.txt`.
With the login shell's default `PATH=/usr/bin:/bin` it returns **empty** (`/bin/sh: ip:
not found`) and the engine would refuse to start with no useful error. `/sbin/ip` exists
(`-> ip.iproute2`) and works when invoked through the symlink.

### 3. How the stock vendor UI does it

Not applicable — the stock firmware has no DPI/video-optimizer page (`/tzwww/js` has no
`tpws`/`zapret`/DPI request command). This feature is QManager-only; there is no vendor
behaviour to copy.

### 4. Fix plan (make the toggle work honestly)

1. **Ship the units.** Add the deployment copies to `deploy-x16/` and to the module's unit
   list:
   * `deploy-x16/qmanager-dpi.service`, `qmanager-dpi-ensure.service`,
     `qmanager-dpi-ensure.timer` — copies of `greenpacket-o5a-qmanager/deploy/*` with paths
     already rewritten to `/data/qmanager/…`, `WantedBy` kept, and
     `ConditionPathExists=/data/qmanager/bin/tpws`.
   * `deploy-x16/install.sh`: extend `UNITS` (line 60) or add a `DPI_UNITS` group and push
     them with the existing `push`/`chmod 644`/`systemctl enable` block (`:280-296`);
     extend the `--check` list (`:164-169`) and the `--uninstall` removal (`:196-207`).
   * `deploy-x16/start_qmanager`: append the two services to `UNITS` **and** start
     `qmanager-dpi-ensure.timer` alongside `qmanager-guard.timer` — `/etc` mounts late, so a
     `multi-user.target.wants` symlink alone is not enough on this firmware (AGENTS.md §4).
     Gate the start on `[ -x /data/qmanager/bin/tpws ]` so the hook stays correct on a device
     where the binary was removed by the UI's own uninstall.
   * Optionally add `qmanager-dpi` to the healer's unit list so `qmanager-guard` puts back an
     engine that something else stopped (same failure class the guard already covers).
2. **Seed the hostlist.** Push `scripts/www/…`-independent data file
   `/etc/qmanager/video_domains.txt` + `…_default.txt` (content as in
   `qmanager_setup:240-256`), `chown www-data`, `chmod 644`; or call
   `qmanager_setup` (its `qm_config_init` + hostlist seed are idempotent) once from
   `install.sh`.
3. **Keep the failure honest.** With the units present, `engine_start_failed` becomes a real
   error again. Also make the CGI not persist intent it could not act on: move
   `qm_config_set(video_optimizer|full_bypass, enabled, 1)` to *after* a successful
   `svc_restart` (or roll it back on failure), so a failed enable does not leave
   `enabled:1 / status:stopped` — the state the UI currently renders as "on but dead".
4. **Alternative (if the units are deliberately out of scope):** make it report
   *unsupported* instead of flipping back. In `emit_status()`, add
   `"engine_supported": false` when `/etc/systemd/system/qmanager-dpi.service` is absent,
   and in the `save`/`save_full_bypass` branches return
   `cgi_error "unsupported" "the Traffic Engine is not available on this firmware"` **before**
   `qm_config_set`. The UI then disables the mode rows and shows the reason, instead of a
   toggle that reverts.

### 5. How to verify (after the fix)

```sh
ssh zlt-root 'systemctl is-active qmanager-dpi qmanager-dpi-ensure.timer'          # active/active
ssh zlt-root 'pgrep -af "tpws" ; iptables -t nat -S PREROUTING | grep 989'
ssh zlt-root 'cd /data/qmanager/www/cgi-bin/quecmanager/network && \
  _SKIP_AUTH=1 REQUEST_METHOD=GET sh ./video_optimizer.sh'
# expected: "status":"running", "kernel_module_loaded":true, "domains_loaded":13
```
Then in the UI: Bypass mode → *Video Optimizer* → success toast, chip reads **Running**, and
`packets_processed` increments while browsing. Also verify after a **reboot** (the `/etc`
late-mount ordering is the reason this needs the hook, not just `systemctl enable`).

### 6. Risks

* Starting the engine inserts a `nat PREROUTING` REDIRECT for `bridge0 tcp 80,443`. If tpws
  is not actually listening, **every LAN client's HTTP/HTTPS is blackholed** — this is why
  the unit binds the rule to `ExecStartPost`/`ExecStopPost`. Verify with a client *before*
  leaving the device.
* Do not test by enabling from a hand-run `sh` outside the unit's `PATH` (see the `ip`
  trap above) — you will get an engine that reports `stopped` with no error.
* QCMAP flushes iptables on every re-dial; without the ensure loop the rule silently
  disappears (this is the whole point of `qmanager-dpi-ensure`).
* Do not touch the QUIC force-TCP rule while diagnosing — it is independent and working.

---

## (C) `http://192.168.3.1:8080/monitoring/tailscale/` — "Install Tailscale" fails

### 1. Reproduced symptom

Read-only probes only; **no install was run by me**. The device already carries the marker
and log of the last attempt (2026-10-26 15:23 PKT), which is the failure to explain:

```
$ _SKIP_AUTH=1 REQUEST_METHOD=GET sh /data/qmanager/www/cgi-bin/quecmanager/vpn/tailscale.sh
{"success": true, "installed": false,
 "install_hint": "Install via the button above or SSH: sudo qmanager_tailscale_mgr install"}

$ cat /tmp/qmanager_tailscale_install.json
{"success":false,"status":"error","message":"Cannot cd /usrdata"}

$ cat /tmp/qmanager_tailscale_install.log
=== qmanager_tailscale_mgr — install started ===
Version: 1.92.5
Arch:    arm
URL:     https://pkgs.tailscale.com/stable/tailscale_1.92.5_arm.tgz
Target:  /data/tailscale

Creating directories...
Downloading tailscale_1.92.5_arm.tgz...
/tmp/qmanager_tailscale_install_inner.sh: line 85: cd: /usrdata: No such file or directory

$ systemctl status qmanager_tailscale_install.service
Active: failed (Result: exit-code) since Mon 2026-10-26 15:23:21 PKT
Process: ExecStart=/bin/bash /tmp/qmanager_tailscale_install_inner.sh (code=exited, status=1/FAILURE)
```

The UI does surface this: `hooks/use-tailscale.ts:396-404` polls
`{"action":"install_status"}` every 2 s and stops on `status === "error"`, so the card ends
on "The install didn't finish" with that message. That *is* the "Install Tailscale does not
work" the user reports.

### 2. Root cause — exact lines

`scripts/usr/bin/qmanager_tailscale_mgr` (deployed copy `/data/qmanager/bin/qmanager_tailscale_mgr`),
inside the inner-install heredoc that runs as `qmanager_tailscale_install.service`:

```sh
:170   cd /usrdata || { write_status '{"success":false,"status":"error","message":"Cannot cd /usrdata"}'; exit 1; }
:195   cd "/usrdata/$TAILSCALE_EXTRACT_DIR" || exit 1
:198       cd /usrdata || true
:204   cd /usrdata || exit 1
```

**`/usrdata` does not exist on the ZLT X16.** The writable volume is `/data`:

```
$ ls -d /usrdata                       -> No such file or directory
$ cat /proc/mounts | grep -E ' / | /data '
ubi0:rootfs  /     ubifs rw,...
/dev/ubi2_0  /data ubifs rw,...
/dev/ubi2_0  /etc  ubifs rw,...
```

`deploy-x16/qm_pathfix_x16.sh:39` rewrites only **`/usrdata/qmanager`**:

```sh
-e s|/usrdata/qmanager|$QM_ROOT|g       # $QM_ROOT=/data/qmanager
```

which is why the deployed copy is *partly* relocated (`TAILSCALE_DIR="/data/tailscale"`,
`/data/root/bin`, `QM_BUNDLED_UNIT="/data/qmanager/lib/…"`, `cd "/data/$TAILSCALE_EXTRACT_DIR"`)
while the three bare `cd /usrdata` sites — which have no `/qmanager` suffix — survived.
The install therefore dies **one statement before the download**: `curl` never runs,
`/data/tailscale/tailscale` is never created, and `is_installed()` stays false forever.

### 3. What is *not* the cause (each measured)

| Suspected | Measured |
|---|---|
| No internet / DNS | `curl -sI https://pkgs.tailscale.com/stable/tailscale_1.92.5_arm.tgz` → **HTTP/2 200**, `content-length: 30597557`; `nslookup pkgs.tailscale.com` resolves via 119.160.122.146 |
| No package manager | correct, `opkg`/`apk`/`ipkg` absent — but irrelevant: the design is a curl'd tarball, not a package install |
| No armv7 build | the `_arm` tarball is Go/GOARM (armv6-softfloat) and runs on armv7l; nothing built locally |
| read-only `/` | `/` is mounted **rw** and `[ -w /usr/bin ]` is true; `/data`, `/etc/systemd/system` writable; `/dev/net/tun` exists (`c 10,200`) |
| privileges | busybox httpd on :8080 runs as **root** (`busybox httpd -p 8080 -h /data/qmanager/www`), `platform.sh:25` sets `_SUDO=""` for root, and there is no `/etc/sudoers.d/qmanager`. No sudo involved |
| binary already present | no: `/data/tailscale/` holds only an empty `systemd/` dir (created by `ensure_units` at deploy time); no `tailscale`/`tailscaled` anywhere |
| vendor firmware ships one | no — `/usr/bin/tailscale`, `/usr/sbin/tailscale`, `/data/qmanager/bin/tailscale*` all absent; `/tzwww` has no tailscale asset |

Secondary gap found while checking the install path: the bundled units the helper prefers
are **not staged** on this device —
`ls /data/qmanager/lib/tailscaled.service /data/qmanager/lib/tailscaled.defaults` → both
missing (`deploy-x16/install.sh` never pushes `scripts/etc/systemd/system/tailscaled.*` into
`$QM_ROOT/lib`). The helper falls back to its inline `UNITEOF` (which *is* relocated to
`/data/tailscale/…`), so this degrades rather than breaks — but the fallback unit is
`Type=notify` with `After=NetworkManager.service systemd-resolved.service` (neither exists
here) and must be checked once the path bug is fixed.

### 4. How the stock vendor UI does it

N/A — the vendor UI has no Tailscale/opkg surface (`/tzwww/js/language/en.js` has no
tailscale strings). Feature is QManager-only.

### 5. Fix plan

1. `deploy-x16/qm_pathfix_x16.sh` — add a bare-path rule **before** the `/usrdata/qmanager`
   one (order matters: the longer prefix must win, so keep `/usrdata/qmanager` first and add
   the general one after it):
   ```sh
   -e s|/usrdata/qmanager|$QM_ROOT|g
   -e s|/usrdata|$QM_ROOT_PARENT|g      # QM_ROOT_PARENT=/data
   ```
   A blanket `s|/usrdata|/data|g` is correct **for this module only** because nothing on the
   X16 has a legitimate `/usrdata`.
2. Fix the source too, so a rebuild does not regress:
   `greenpacket-o5a-qmanager/scripts/usr/bin/qmanager_tailscale_mgr:170,195,198,204` →
   `cd /data` / `cd "/data/$TAILSCALE_EXTRACT_DIR"` (and the `HOME`/`PATH`/`/usrdata/root`
   sites at `:91-92,145-146,272-273` — a `/usrdata/root/bin/tailscale` symlink is pointless
   here; drop it or point it at `/data/root/bin`).
3. Stage the bundled units:
   `deploy-x16/install.sh` — push `scripts/etc/systemd/system/tailscaled.{service,defaults}`
   to `$QM_ROOT/lib/` so `ensure_units` has something to copy, and re-run
   `$QM_ROOT/bin/qmanager_tailscale_mgr ensure_units` at install time (it is already
   idempotent; it ran once and produced the empty `/data/tailscale/systemd`).
4. Keep the failure legible: the marker/`install_status` plumbing already reports exactly
   what went wrong — do not change it. After the fix, the same log will show
   `Downloading… Extracting… Starting tailscaled…`.
5. Optional honesty guard: if the helper cannot `cd` its working directory it should report
   a *reason* (`"Cannot cd /data — volume missing"`) rather than a path name an operator
   cannot act on.

### 6. How to verify (after the fix)

Read-only inspection first (proves the path is now usable without installing anything):

```sh
ssh zlt-root 'grep -c "^cd /usrdata" /data/qmanager/bin/qmanager_tailscale_mgr'   # expected 0
ssh zlt-root '[ -d /data ] && echo ok && [ -w /data ] && echo writable'
```

Then, when an install is actually sanctioned (30 MB download, `tailscaled` starts and inserts
`tailscale0` — **not** part of this recon):

```sh
# UI: Install Tailscale -> the card's log tail ends with
#   "=== Tailscale v1.92.5 installed successfully ==="
ssh zlt-root 'ls -l /data/tailscale/tailscale /data/tailscale/tailscaled \
              /etc/systemd/system/tailscaled.service; systemctl is-active tailscaled'
ssh zlt-root '/data/tailscale/tailscale version; ls -l /dev/net/tun'
```

### 7. Risks

* **Never** pass `--accept-routes` (the CGI documents this: it disconnects the device from the
  network and needs a physical reboot). The `connect` path already avoids it.
* Installing creates `/etc/systemd/system/tailscaled.service` + a
  `multi-user.target.wants` symlink on this boot-late `/etc` volume; verify after a reboot,
  and remember the boot-ordering constraint in AGENTS.md §4 (a wants-symlink alone did not
  start units on this firmware — that is what `start_qmanager` exists for).
* `tailscaled` + the `tailscale0` interface changes firewall trust (`qmanager-firewall`
  restarts itself at the end of the install). Do it when a WAN blip is acceptable.
* A DoS-ish risk if `curl -O` is retried blindly: the helper uses bare `curl -O` with **no
  timeout**; on a flaky link this can hang the oneshot unit indefinitely (the `install_status`
  poller has a 30 s worker-alive guard, the downloader does not).

---

## Cross-cutting notes for whoever implements

* Rebuild path: `cd deploy-x16 && QM_SRC=<tree> ./install.sh --build && ./install.sh`
  (`qm_pathfix_x16.sh` runs **on the device** at `install.sh:270`, so path fixes land per
  deploy — but any file it does not match survives, which is exactly how (C) happened).
* All three defects are visible from the host with **no auth** by running the CGI with
  `_SKIP_AUTH=1 REQUEST_METHOD=…` on the device — use that for regression checks instead of
  logging into the UI.
* `docs/09-features.md:172` is wrong now (`tpws` **is** deployed, v72.13) and should be fixed
  with (B).
* Device state changes caused by this recon: **none that persist.** The only write-like
  action was re-playing the UI's own failing `{"action":"save","enabled":true}` POST for (B),
  which re-wrote `video_optimizer.enabled` to the value it **already had** (`1`) and
  `full_bypass.enabled` to `0` (already `0`); no unit was started or stopped. Everything else
  was `GET`/`ls`/`cat`/`ethtool`/`curl -I`.
