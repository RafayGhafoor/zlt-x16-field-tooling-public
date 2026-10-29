# deploy-x16/smartdns — the SmartDNS resolver behind `/local-network/smartdns`

Enables QManager's SmartDNS page on the **ZLT X16**: smartdns-rs 0.13.1 running on
`127.0.0.1:5353`, dnsmasq on the LAN forwarding to it, and the three timers the page
needs (edge selection, stats history, wiring guard).

```
LAN client ─▶ dnsmasq 192.168.3.1:53 ──strict-order──▶ smartdns 127.0.0.1:5353 ──▶ DoH pool
                    (DHCP, leases,                          (cache 8192,
                     front cache 2000)                       serve-expired, groups)
                 │
                 └── falls through to the carrier resolvers (/tmp/resolv.conf)
```

The vendored resolver, the 87 CGIs and the Next.js page are **unchanged QManager
code** — the page and its four `smartdns*`/`dns_test` CGIs already shipped with
`deploy-x16` and answered `enabled:false`, config `null`, because nothing existed
behind them. This module is the device side. Three things on this firmware differ
from the GreenPacket O5A the feature was written on, and each one is absorbed here
rather than worked around at the UI.

## Install

```sh
cd deploy-x16/smartdns
./install.sh              # deploy, start via the boot path, verify
./install.sh --check      # verify only: helper status + the page's own CGI payload
./install.sh --uninstall  # remove, restore the vendor dnsmasq behaviour
```

`ZLT_HOST` (default `zlt-root`), `ZLT_TRIES` (default 10), `QM_SRC` (default
`/tmp/qm`), `SMARTDNS_SRC` and `QM_PASS` are honoured. The resolver binary is taken
from the QManager tree (`$QM_SRC/dependencies/smartdns/smartdns`, sha256-checked) —
it is not duplicated in this repo. QManager must already be deployed
(`deploy-x16/install.sh`) or there is nothing to enable.

## Contents

| File | Purpose |
|---|---|
| `install.sh` | Host-side: push, enable, wire the boot hook, start, verify. Idempotent; backups to `/data/zlt-backups/<date>/smartdns/`. |
| `smartdns.conf` | Seed config for `/data/qmanager/etc/smartdns.conf` (the only writer afterwards is `qmanager_dns_apply`). Directives are the O5A's, unchanged — the *latency map* is per-network and is re-measured by the edge timer. |
| `zlt-smartdns.sh` | **The adaptation layer.** `boot` (start units/timers), `wire` (dnsmasq), `verify`, `status`, `start/stop`, `unwire`, `hook-install/hook-remove`. |
| `qmanager-dns.service` | The resolver. |
| `qmanager-dns-stats.{service,timer}` | 5-minute dnsmasq-counter sampler → `/tmp/qmanager_dns_stats_history.json`, the page's history chart. |
| `qmanager-dns-edge.{service,timer}` | 30-minute measured edge refresh (`qmanager_dns_apply apply-edge`). |
| `zlt-smartdns.{service,timer}` | 1-minute guard: re-applies the dnsmasq wiring, and starts dnsmasq if it is dead. |
| `NOTICE.md` | Licence/provenance for the GPL-3.0 resolver binary. |

## The three X16 differences, and what each cost to learn

### 1. Units under `/etc/systemd/system` get no boot job

Same trap as `deploy-x16/README.md` and `router-fix/ipacm/`: `/etc` is a separate
ubi volume mounted ~10 s in, after systemd has loaded its graph. `systemctl enable`
therefore cannot make the resolver start at boot. `install.sh` adds two lines to
`/etc/initscripts/StartTZApp` (`zlt-smartdns.sh hook-install`, vendor copy backed up
to `StartTZApp.pre-smartdns`) and the hook starts the unit and the three timers.

`systemctl is-enabled` still matters: `boot` only starts the resolver when the unit
is enabled, so **`systemctl disable qmanager-dns.service` is the way to make "off"
survive a reboot** — the page's toggle is a runtime switch only (upstream design).

**Verified on a real reboot 2026-10-26** (boot_id `7ffdff28…` → `f832fba7…`):
`qmanager-dns.service` `ExecMainStartTimestampMonotonic` = **57.0 s** against a
137 s boot, all three timers `active`, wiring applied at 06:55:31 and dnsmasq
answering on the LAN at 06:55:37 — no manual step.

### 2. dnsmasq's config is in `/tmp` and nothing supervises dnsmasq

The vendor runs `dnsmasq -C /tmp/dnsmasq.conf -x /tmp/dnsmasq.pid`, `keep-in-foreground`,
parented by `TZApp.service`. That file is **generated per boot** (`start_cfgd`'s
`ModifyDnsmasqConf` is dead code on this build) and *nothing restarts dnsmasq if it
dies* — measured: `killall dnsmasq` left LAN DNS dead indefinitely, `lan_mgr` did not
respawn it.

So `wire`:
- appends `strict-order`, `server=127.0.0.1#5353`, `cache-size=2000` (dnsmasq's front
  cache was the 150 default) and `log-facility=/tmp/dnsmasq.log` between
  `# BEGIN/END ZLT-SMARTDNS v1` markers;
- keeps the vendor's own file at `/tmp/dnsmasq.conf.vendor` for `--uninstall`;
- validates the **candidate** with `dnsmasq --test` and asserts its own directives
  survived assembly, before the live daemon is touched;
- restarts dnsmasq only when the file actually changed, and starts it back;
- runs every minute from `zlt-smartdns.timer` as a guard, because the file and the
  daemon both belong to the vendor: a regeneration or a dead daemon is repaired
  within a minute, and a healthy system sees one `netstat` + one `awk` + one `cmp`.

#### Two bugs found while building this — do not reintroduce either

| Bug | Symptom | Rule |
|---|---|---|
| Non-canonical assembly: strip block, re-append with an `echo` separator | the file grew one blank line per run, `cmp` never matched, and dnsmasq was **killed and restarted every 60 s** — a DNS blip a minute | strip trailing blank lines too, so the second run is a no-op |
| Default `KillMode=control-group` on the oneshot guard | dnsmasq logged `exiting on receipt of SIGTERM` one second after starting: systemd tore down the unit's cgroup on exit, leaving the LAN without DNS | `KillMode=process` on `zlt-smartdns.service` |

Post-reboot proof that neither is back: one dnsmasq start since boot, `SIGTERM`
count 0, config md5 and dnsmasq pid identical across two guard runs 75 s apart.

### 3. There is no `/var/log/syslog`

`/var/log` → `/var/volatile/log`, and that directory **does not exist**, so the
busybox `syslogd` that is running writes nowhere. QManager's `smartdns_stats.sh`
and the sampler read dnsmasq's `SIGUSR1` dump from `/var/log/syslog` by that exact
path. Rather than switch on system-wide logging (a write load this box does not
have today), `wire` points dnsmasq's `log-facility` at `/tmp/dnsmasq.log` and makes
`/var/log/syslog` a symlink to it. `cap_log` trims it to 64 kB past 256 kB, so a
diagnostic file cannot eat the shared tmpfs.

Effect: `cache.hit_rate_pct`, `forwarding.queries_forwarded` and the history ring
all populate instead of reporting `null` forever.

## The carrier comparison (`--carrier`)

The page answers "is the pool faster than the ISP's resolver?" only if the ISP's
resolver is in the table. `qmanager_dns_test` now calls
`qmanager_dns_edge_probe --carrier`, which appends the operator's own resolvers as
extra rows, marked `is_carrier:true`, and returns a `carrier` block naming the
addresses and the resolv.conf they came from.

- **Auto-picked**: `/tmp/resolv.conf` → `/run/resolv.conf` → `/etc/resolv.conf`,
  first hit wins, duplicates dropped, loopback skipped. The addresses change per SIM
  and per network — a hardcoded pair measured a resolver this router does not use.
- **Never a candidate**: carrier rows are excluded from `recommendation.good` /
  `dropped` unconditionally, and the edge timer never passes `--carrier`. Pool
  membership can never grow a plain UDP/53 entry.
- No frontend change was needed: the tester table renders `short` / `ips` /
  `rtt_ms` / `class` generically, so carrier rows appear as `carrier 39.39.39.39`.

Measured on this unit 2026-10-26 (`youtube.com`, all ten rows in the tester):

| row | rtt | class |
|---|---|---|
| dns.quad9.net | 93 ms | near |
| carrier 182.176.100.89 | 93 ms | near |
| doh.opendns.com | 110 ms | near |
| dns.google | 112 ms | near |
| carrier 39.39.39.39 | 142 ms | near |
| unfiltered.adguard-dns.com | 281 ms | far |
| sky.rethinkdns.com | 320 ms | far |
| dns.nextdns.io | 343 ms | far |
| 1.1.1.1 | 384 ms | far |
| cloudflare-dns.com | 398 ms | far |

That table is the argument for the feature and against trusting it blindly: the
carrier is *not* the problem here, and two pool members are worse than it. The edge
algorithm drops those two (they are the `far` class) and keeps the near four.

The performance card's `carrier_ms` / `lan_ms` speed-up is a **different**
measurement, taken by `qmanager_ping` (opt-in `DNS_LAN_RESOLVER` in
`deploy-x16/qmanager-ping.service`) — it compares one warm name through the carrier
and through the LAN resolver, not per-provider answers.

## Verification

```sh
cd deploy-x16/smartdns && ./install.sh --check
```

Prints the helper's `status` (binary, config, unit, listener, pid/rss, timers,
dnsmasq wiring, samples) followed by the page's own CGI payloads via a real login:

```json
{"enabled":true,"running":true,"pid":3062,"rss_kb":5544,"config_size":11907,
 "provider_count":8,"blocked_count":5,"error_count":2,"edge_members":3}
{"cache":58.8,"forwarded":7,"speedup":4.2,"pool":8,"history_samples":2}
```

Health checks used here, in order of how much they lie:

```sh
/data/qmanager/bin/zlt-smartdns.sh status          # everything, incl. the two shim facts
netstat -lnu | grep 127.0.0.1:5353                 # exactly one listener
dig +short @192.168.3.1 youtube.com                # 142.251.x (near), not 192.178.x (far)
dig +short @192.168.3.1 guardsquare.com            # SOA only — a blocked rule survived dnsmasq
grep -E 'strict-order|^server=127' /tmp/dnsmasq.conf
```

Toggle behaviour (verified): `disable` stops the resolver and the LAN **keeps
answering** through the carrier tier (that is what `strict-order` is for); `enable`
brings it back and the next answer is the near-class IP again.

## Known gaps

- **The pool's latency map is per-network.** The seed config carries the O5A's
  measurements; the first edge refresh on this unit (5 min after boot, then every
  30 min) re-measures it. Until then Google-family names use the unpartitioned race.
- **The edge refresh restarts the resolver** (`qmanager_dns_apply apply-edge`), so
  there is a ~2 s window every 30 min where dnsmasq falls through to the carrier.
  Recorded, not hidden: it is upstream behaviour and the fallback is why it is safe.
- **Boot costs one dnsmasq restart**: the vendor's dnsmasq starts before this hook
  can patch the config, so the wiring is applied by restarting it (~3 s at uptime
  57 s, before clients are attached).
- A `dnsmasq` restart drops DHCP service for about a second. Leases are on disk
  (`/tmp/dnsmasq.leases`), so nothing is lost.
- SmartDNS's own counters do not exist (0.13.1 exports none): every figure on the
  page is derived, and the payload says so per field.
- Not covered by `tests/smoke_endpoints.sh`'s semantic layer yet: it checks
  `network/smartdns.sh` for the `enabled` key, not that the resolver is listening.

## Rollback

```sh
./install.sh --uninstall
```

Stops the units, restores the vendor's dnsmasq config from `/tmp/dnsmasq.conf.vendor`
(or strips the marker block), restarts dnsmasq, removes the boot-hook lines, the
unit files, the binary and the helper, and parks the config as
`smartdns.conf.removed`. The page stays in the UI (it belongs to QManager) and
correctly reports `enabled:false`.

Byte-for-byte vendor restore of the boot chain, if ever needed:

```sh
ssh zlt-root 'cp /etc/initscripts/StartTZApp.pre-smartdns /etc/initscripts/StartTZApp'
```
