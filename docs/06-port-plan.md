# 06 — Port plan

Target: QManager `greenpacket` running on the ZLT X16 ODU at `http://<x16-lan-ip>:8080/`
with real modem data from the SIM8260E.

Design principle: **reuse the GreenPacket recipe, change four things** — payload root
(`/usrdata` → `/data`), AT transport, AT dialect, and the feature set.

---

## Phase 0 — device access & recon *(BLOCKED — see 07)*

Reach: currently only **80/443** from our network position; 22/23 closed. Need LAN-side shell.

Recon script to run on the X16 (`docs/recon-x16.sh` — generate from this list):

```sh
uname -a; cat /proc/cpuinfo | grep -c processor
df -h; mount | grep -E ' / | /data | /etc '; cat /proc/partitions
ps -o pid,ppid,args 2>/dev/null | head -50 || ps w
netstat -lntp 2>/dev/null || ss -lntp
ls -l /bin /usr/bin /usr/sbin | head -100
busybox 2>&1 | head -3; busybox --list 2>/dev/null | tr '\n' ' '
ls -l /dev | grep -iE 'tty|smd|at|ipa|qrtr|mhi'
systemctl list-units --type=service --no-pager | head -40
ls -l /etc/systemd/system/multi-user.target.wants/
which curl wget jq python3 httpd busybox flock timeout qmicli openssl sms_tool socat
flock -w 1 /tmp/x true && echo "flock -w OK"
iptables -t mangle -L 2>/dev/null | head -5
lsmod 2>/dev/null | grep -i hl ; iptables -t mangle -A POSTROUTING -o lo -j TTL --ttl-set 64 && echo "xt_HL OK" && iptables -t mangle -D POSTROUTING -o lo -j TTL --ttl-set 64
```

Plus the **AT discovery** (decides Phase 4):
```sh
cat /cgi-bin/http.cgi 2>/dev/null | head -c 200   # is the CGI a script or a binary?
# find what serves the vendor UI and what it execs:
ps w | grep -iE 'http|cgi|TZApp|web'
ls -l /proc/*/exe 2>/dev/null | grep -iE 'httpd|TZ'
# AT entry point hunt:
ls -l /usr/bin /usr/sbin /bin | grep -iE 'at_|atcmd|sendat|simcom'
strings /cgi-bin/http.cgi 2>/dev/null | grep -iE 'atcmd|AT\+' | head
```

**Gate 0**: shell as root; `df -h /data` ≥ 150 MB free; `jq` presence known; AT entry point
answer known (exists / does not exist).

---

## Phase 1 — build the frontend *(can be done offline, no device needed)*

Host already has `bun 1.4.2`, `node 26`, `cargo 1.98`.

```sh
cd /tmp/qm
bun install --frozen-lockfile
bun run build            # -> out/   (static export, trailingSlash)
```

Stage the payload (adapting `deploy/README.md` steps 2–3d):

```sh
STAGE=/tmp/qm-stage
mkdir -p $STAGE/www $STAGE/lib $STAGE/bin
cp -a out/.                       $STAGE/www/
mkdir -p $STAGE/www/cgi-bin
cp -a scripts/www/cgi-bin/quecmanager   $STAGE/www/cgi-bin/
cp -a scripts/usr/lib/qmanager/.        $STAGE/lib/
cp -a scripts/usr/bin/.                 $STAGE/bin/
cp -a deploy/atcli_smd11 deploy/sudo    $STAGE/bin/
cp dependencies/sms_tool                $STAGE/bin/sms_tool.bin
cp deploy/sms_tool                      $STAGE/bin/sms_tool
curl -fsSL -o $STAGE/bin/jq  https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-armhf
curl -fsSL -o $STAGE/etc-cacert.pem      https://curl.se/ca/cacert.pem
```

**Gate 1a — binary compatibility. RESOLVED.** Performed on the host:
```
file bin/jq → ELF 32-bit LSB executable, ARM, EABI5, statically linked, for GNU/Linux 3.2.0
```
`jq-linux-armhf` (1.7.1) is **static** — no `GLIBC_*` symbols, no interpreter, so the
glibc 2.31 constraint does not apply. Any other binary we add (Go/Rust helpers) should be
built **static** for the same reason: `armv7-unknown-linux-musleabihf`, or `armv7-unknown-linux-gnueabihf`
with static linking.

**Gate 1b — exec bits. TRAP FOUND.** 85 of the 87 CGI scripts in the repo are stored
**non-executable**. busybox httpd will answer 404/403 instead of running them, and the failure
looks like a frontend bug. Always after staging:
```sh
find $STAGE/www/cgi-bin -type f -exec chmod 755 {} +
# verify: expect 0
find $STAGE/www/cgi-bin -type f ! -perm -u+x | wc -l
```

**Gate 1c**: `out/index.html` exists and every CGI path in the bundle starts with `/cgi-bin/`.

Measured payload (staged at `/tmp/qm-stage`, after a clean build):
```
www  14 MB   (static export)
bin  2.5 MB  (55 helpers + jq + shims + sms_tool)
lib  564 KB  (32 files)
     196 KB  CA bundle
     ~17 MB total
```

---

## Phase 2 — deploy to `/data`

Nothing outside `/data/qmanager`, `/etc/qmanager` and `/etc/systemd/system` is touched.

```sh
tar czf - -C $STAGE . | ssh root@<x16> 'mkdir -p /data/qmanager && tar xzf - -C /data/qmanager'
ssh root@<x16> 'mkdir -p /data/qmanager/etc && mv /data/qmanager/etc-cacert.pem /data/qmanager/etc/cacert.pem'
```

Normalise ownership/mode — **do not skip** (macOS tar stamps uid 501 and drops exec bits;
the failure looks like an application bug: `status=203/EXEC`, CGIs 404, `. _` sidecars):

```sh
ssh root@<x16> '
  find /data/qmanager -name "._*" -delete
  chown -R root:root /data/qmanager && chmod 755 /data/qmanager
  find /data/qmanager/bin /data/qmanager/www/cgi-bin -type f -exec chmod 755 {} +
  mkdir -p /etc/qmanager && chmod 777 /etc/qmanager'
```

Path fix (new script `deploy-x16/qm_pathfix_x16.sh`, derived from `deploy/qm_pathfix.sh`):

| From | To |
|---|---|
| `/usr/lib/qmanager` | `/data/qmanager/lib` |
| `/usr/bin/<qm helper>` | `/data/qmanager/bin/<helper>` |
| `/usrdata/qmanager` | `/data/qmanager` |
| `PATH="/opt/bin:/opt/sbin:…"` in `cgi_base.sh` | `PATH="/data/qmanager/bin:/usr/bin:/usr/sbin:/bin:/sbin"` |

Verify: zero files in `bin/`+`cgi-bin/` not owned by root or missing `u+x`; `grep -r
/usr/lib/qmanager /data/qmanager | wc -l` → 0.

**Gate 2**: `bash -n` clean on every CGI (`find … -name '*.sh' -exec sh -n {} +`).

---

## Phase 3 — serve on 8080

`deploy/qm_serve.sh` already parameterises `QM_PORT` (default 8080). Adapt paths
(`/usrdata/qmanager` → `/data/qmanager`) and re-point the boot mechanism.

- Server: `busybox httpd -p 8080 -h /data/qmanager/www`, run as **root** (CGI must write
  `/etc/qmanager` and issue modem I/O). busybox httpd only executes files under `/cgi-bin/`,
  which matches QManager's URL namespace.
- Unit `/etc/systemd/system/qmanager-httpd.service` — model it on the working
  `router-fix/zlt-wan-fix.service` pattern (unit in `/etc/systemd/system`, payload in
  `/data`, `After=TZApp.service`; **no `Requires=`** so a vendor restart does not take the UI
  down; `Restart=on-failure`).
- Do **not** deploy `qmanager-console.service` (ttyd also wants 8080).

**Gate 3**: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/` → 200;
`curl -s http://127.0.0.1:8080/cgi-bin/quecmanager/public/overview.sh` → JSON (not HTML);
setup wizard reachable; password set; login sets `qm_session`; vendor UI on :80 still works.

At this point **the UI is up but blind** — no modem data. That is expected and is the right
milestone: it proves the deployment half independently of the modem half.

---

## Phase 4 — modem data source *(the decision gate)*

Follow [05-the-at-problem.md](05-the-at-problem.md): **A** (vendor AT entry point) → **B**
(QMI/QRTR bridge) → **C** only if forced.

### 4A — vendor AT entry point

If Phase 0 found a CLI: rewrite `deploy/atcli_smd11` (x16 variant) to call it and print the
response verbatim, keeping `qcmd`'s contract (raw text on stdout, always exit 0).
Then run the **capture pass** below before any parser work.

### 4B — QMI bridge

Build `bin/atcli_smd11` as a translator: recognise the AT commands QManager actually issues,
answer them from `qmicli`, emit the response in the shape `parse_at.sh` expects, and return
`OK`/`ERROR` honestly. Bind it to the same `qcmd` lock so the two never interleave.

Mapping (read-only first): `CGMM`→`--dms-get-model`, `CGMR`→`--dms-get-revision`,
`CGSN`→`--dms-get-ids`, `CIMI`→`--dms-get-ids`, `CICCID`→`--dms-get-iccid`,
`CGSN/CNUM`→`--dms-get-msisdn`, `CPIN`→`--dms-uim-get-state`, `COPS?`→
`--nas-get-serving-system`, `CEREG?`/`C5GREG?`→`--nas-get-serving-system`, `CSQ`/`CESQ`→
`--nas-get-signal-info`, `QENG="servingcell"`→`--nas-get-serving-system` +
`--nas-get-rf-band-info` + `--nas-get-signal-info`, `CGCONTRDP`→`--wds-get-current-settings`,
`CGACT?`→`--wds-get-data-bearer-technology`.

**Capture pass — mandatory before writing any parser** (the repo already hit this class of
bug twice: `rg501q_cgcontrdp_unquoted_response`, `quectel_project_version_double_space_labels`):

```sh
for c in 'AT+CPSI?' 'AT+CESQ' 'AT+CSQ' 'AT+CEREG?' 'AT+C5GREG?' 'AT+COPS?' 'AT+CGCONTRDP=6' \
         'AT+CGCONTRDP=1' 'AT+CGACT?' 'AT+CGDCONT?' 'AT+CGSN' 'AT+CICCID' 'AT+CIMI' 'AT+CNUM' \
         'AT+CPIN?' 'AT+CGMM' 'AT+CGMR' 'AT+CSYSSEL?' 'AT+CCAINFO?' 'AT+CNWINFO?'; do
  echo "### $c"; qcmd "$c"; done > /data/qmanager/captures/at-$(date +%F).txt
```
Repeat 3× per command, per RAT (LTE / NR-NSA / NR-SA if available). Save to
`docs/captures/`.

**Gate 4**: `qcmd 'AT+CGMM'` returns a real model string; `/tmp/qmanager_status.json` fills
with sane values; **`/tmp/logs/DIALER.log` shows no new AT-failure lines** for 30 minutes.

---

## Phase 5 — poller & parsers

Order of work, cheapest-but-visible first (`scripts/usr/lib/qmanager/parse_at.sh` unless noted):

1. `resolve_network_iface()` — currently hardcodes `rmnet_ipa0`; X16 WAN is `rmnet_data0`.
   Get it wrong and the data counter freezes at a plausible wrong number **silently**.
2. `parse_version` → drop `AT+CVERSION`, use `AT+CGMR`/`AT+CGMM`.
3. `parse_carrier` → operator name from `+COPS:` (drop `+QSPN`).
4. ICCID: `AT+QCCID` → `AT+CICCID` (19 sites).
5. Temperature: keep the existing sysfs fallback (already written).
6. `parse_serving_cell` — **replace the ~300-line `+QENG:` awk with a `+CPSI:` parser**;
   remember values are dB×10 and TAC/CI are quoted.
7. APN path: `AT+QICSGP` → `AT+CGDCONT` + `AT+CGAUTH`; re-validate the
   `CGDCONT → COPS=2 → COPS=0 → CGCONTRDP` attach cycle timings; **use CID 6 as primary**.
8. Bands: `AT+QNWPREFCFG` bitmask ↔ `AT+CSYSSEL` colon list; `mode_pref` → `AT+CNMP` enum.
9. IMEI write: `AT+EGMR` → `AT+SIMEI` (keep the read path; gate the write).

**Gate 5**: dashboard tiles populate (carrier, RAT, band, RSRP/RSRQ/SINR, WAN IP, APN, temp,
uptime); `qmanager_poller` restart loop-free for 1 h; dialer log clean.

---

## Phase 6 — feature triage

| Keep (works, small fixes) | Degrade (honest "unavailable") | Drop |
|---|---|---|
| Dashboard, signal, ping/latency, traffic (rmnet/IPA names already match), APN, SMS, TTL/MTU, system logs, reboot, auth, language packs, cell info basics | CA info (`+CCAINFO?` undocumented), NR cell lock, PHY deep metrics, MBN page (`+CMCFG` only — real selection needs PDC/QMI) | Dual-SIM failover (`QUIMSLOT`), neighbour/cell scanner, frequency lock, tower lock + failover/schedule, IP passthrough (`ql_qmap`), Traffic-Engine DPI (unverified on this vendor stack) |

Dropping a feature is a UI change, not a hack: return a typed `unavailable` payload so the
panel renders "not supported on this device" instead of a spinner or a fake number.

**Gate 6**: no CGI returns 500; every degraded panel says why.

---

## Phase 7 — boot & hardening

- `systemctl enable qmanager-httpd qmanager-poller qmanager-ping` + `daemon-reload`.
  The X16 does **not** need the GreenPacket `qm_boot_hook.sh` (that workaround exists because
  PID 1 drops units from its boot transaction — no evidence of that here; verify by reboot).
- Add `qm_wait_modem.sh` equivalent: the poller caches identity once at start — gate it on a
  real `AT+CGMM`/QMI answer, or it bakes a boot-time junk model into the cache.
- Reboot test: `comm -13 <(before) <(after)` on `systemctl show -p ActiveEnterTimestamp`.
- Firewall: LAN-only is fine (vendor already blocks WAN 80/443); confirm 8080 is not exposed
  on `rmnet_data0`.
- Uninstall path mirrors `router-fix`: `systemctl disable --now`, `rm -f` units,
  `daemon-reload`, `rm -rf /data/qmanager /etc/qmanager`.

---

## Rollback

Every step is additive and reversible; nothing replaces a vendor file.
`rm -rf /data/qmanager /etc/qmanager` + remove the three units = pristine device.
The vendor UI (port 80) is never touched.

---

## Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| AT contention → **router reboot** by dialer | high | Phase 4B (QMI) preferred; ≥3 s cadence; no long commands; watch `DIALER.log` |
| `jq` binary needs newer glibc | total (142 files) | verify `GLIBC_*` ≤ 2.31 at Gate 1a; else ship a static build |
| `+CPSI?` format differs from the manual | signal page wrong | capture 3× per RAT before writing the parser |
| `CGCONTRDP` primary CID is not 1 | WAN/APN page empty | use CID 6, verify live |
| macOS tar uid/exec-bit stamping | silent 203/EXEC + 404s | the ownership/mode step in Phase 2 |
| 85/87 CGIs ship non-executable | UI 404s that look like frontend bugs | `chmod 755` over `cgi-bin` after every stage (Gate 1b) |
| busybox httpd missing | no server | fallback: vendor httpd with a second docroot, or ship a static tiny http server |
| `xt_HL` (`-j TTL`) absent from kernel | TTL page unimplementable | probe first; degrade the page |
