# 25 — SmartDNS on the X16: the resolver, the dnsmasq wiring, and the carrier baseline

**Status: enabled and reboot-verified 2026-10-26.** Payload + installer:
[`../deploy-x16/smartdns/`](../deploy-x16/smartdns/) (its README carries the detail;
this page carries the reasoning and the evidence).

---

## What was actually missing

`http://192.168.3.1:8080/local-network/smartdns/` shipped with the QManager payload
and answered — with nothing behind it:

```json
{"enabled": false, "running": false, "pid": null, "config_size": null,
 "provider_count": 0, "blocked_count": 0, "edge": {"mode": "none", "members": []}}
```

No binary, no config, no units, and dnsmasq still talking to the carrier. The page
and its four CGIs (`smartdns.sh`, `smartdns_stats.sh`, `dns_test.sh`, and the four
`qmanager_dns_*` helpers) are unchanged QManager code — they were never broken.

## What the module adds

| Piece | Where |
| --- | --- |
| smartdns-rs 0.13.1 (static armv7, GPL-3.0, sha256-pinned) | `/data/qmanager/bin/smartdns` |
| seed config (the O5A's directives, unchanged) | `/data/qmanager/etc/smartdns.conf`, `root:root 0600` |
| resolver unit | `/etc/systemd/system/qmanager-dns.service` |
| stats sampler (5 min) → the page's history chart | `qmanager-dns-stats.{service,timer}` |
| measured edge refresh (30 min) | `qmanager-dns-edge.{service,timer}` |
| dnsmasq wiring guard (1 min) | `zlt-smartdns.{service,timer}` |
| boot + wiring helper | `/data/qmanager/bin/zlt-smartdns.sh` |
| boot hook | two lines in `/etc/initscripts/StartTZApp` |

The forwarding block appended to the vendor's `/tmp/dnsmasq.conf`:

```
strict-order                                # resolver first, carrier resolvers as tier 2
server=127.0.0.1#5353
cache-size=2000                             # the default was 150
log-facility=/tmp/dnsmasq.log               # there is no syslog on this firmware
```

## Three firmware facts this had to absorb

1. **Units under `/etc/systemd/system` get no boot job** — the `/etc` volume mounts
   after systemd loads its graph. Same trap as `start_qmanager` and `router-fix/ipacm`;
   the hook is the start mechanism, `enable` only records intent. `disable` is the way
   to make "off" survive a reboot, because the page's toggle merely stops the unit.
2. **dnsmasq's config lives in `/tmp` and nothing supervises dnsmasq.** Measured:
   `killall dnsmasq` left LAN DNS dead indefinitely. So the wiring is re-applied every
   minute from a timer, and that timer also starts dnsmasq when it is missing.
3. **There is no `/var/log/syslog`** (`/var/log` → `/var/volatile/log`, which does not
   exist), so dnsmasq's `SIGUSR1` counters went nowhere and every cache figure read
   `null`. `log-facility=/tmp/dnsmasq.log` + a `/var/log/syslog` symlink fixes it
   without switching on system-wide logging.

## Two self-inflicted bugs, recorded so they are not repeated

| Bug | Symptom |
| --- | --- |
| The wiring block was stripped and re-appended with a blank-line separator | the config grew one line per run, `cmp` never matched, and dnsmasq was killed + restarted **every 60 s** — a DNS blip a minute. Fixed by canonical assembly. |
| Default `KillMode=control-group` on the guard's oneshot unit | systemd SIGTERM'd the dnsmasq the guard had just started, one second later, leaving the LAN without DNS. Fixed with `KillMode=process`. |

Both are caught by a post-reboot check now: one dnsmasq start since boot, `SIGTERM`
count 0, config md5 and dnsmasq pid identical across two guard runs 75 s apart.

## Boot proof (real reboot, 2026-10-26)

```
boot_id                    7ffdff28… → f832fba7…      (a real reboot, not a restart)
qmanager-dns.service       ActiveEnterTimestampMonotonic = 57.0 s in a 137 s boot
timers                     qmanager-dns-stats / qmanager-dns-edge / zlt-smartdns — all active
wiring applied             06:55:31   (hook)
dnsmasq restarted          06:55:34   (config change; one restart, at boot, before clients)
LAN answers                06:55:37   (dig @192.168.3.1)
history ring               first sample taken automatically
```

## The carrier baseline (added the same day)

The page could not answer the only question worth asking — *is this faster than what
the ISP hands me?* — so `qmanager_dns_test` now calls the probe with `--carrier`, and
the tester table grows rows for the operator's resolvers, auto-discovered from
`/tmp/resolv.conf` → `/run/resolv.conf` → `/etc/resolv.conf` (never hardcoded; the
addresses change per SIM). They are excluded from the edge recommendation
unconditionally and the timer never asks for them, so pool membership can never grow
a plain UDP/53 entry. No frontend rebuild was needed: the table renders rows
generically.

Live, `youtube.com`, all ten rows sorted by RTT:

| provider | rtt | class |
| --- | --- | --- |
| dns.quad9.net | 93 ms | near |
| **carrier 182.176.100.89** | **93 ms** | near |
| doh.opendns.com | 110 ms | near |
| dns.google | 112 ms | near |
| **carrier 39.39.39.39** | **142 ms** | near |
| unfiltered.adguard-dns.com | 281 ms | far |
| sky.rethinkdns.com | 320 ms | far |
| dns.nextdns.io | 343 ms | far |
| 1.1.1.1 | 384 ms | far |
| cloudflare-dns.com | 398 ms | far |

Two conclusions, both useful and neither flattering: on this network the **carrier is
not the slow path**, and **two of the eight pool members are worse than it** (they
are the `far` class the edge algorithm drops). The win the page can honestly claim
here is the warm path — dnsmasq's front cache plus smartdns's 8192-entry cache
(`speedup_x ≈ 4.2` on the ping two-tier probe) — not cold-lookup latency.

## Verification habits that apply here

```sh
cd deploy-x16/smartdns && ./install.sh --check     # helper status + the page's own CGI payload
cat tests/check_boot_wiring.sh | ssh zlt-root 'cat > /tmp/b.sh && sh /tmp/b.sh'
dig +short @192.168.3.1 youtube.com                # 142.251.x near, not 192.178.x far
dig +short @192.168.3.1 guardsquare.com            # SOA only — blocked rules survive dnsmasq
netstat -lnu | grep 127.0.0.1:5353                 # exactly one listener
```

The toggle was verified both ways: `disable` stops the resolver and the LAN **keeps
answering** through the carrier tier (that is what `strict-order` buys), `enable`
brings it back with the near-class answer.

## Known gaps

- The pool's latency map is per-network: the seed config is the O5A's, and the first
  edge refresh (5 min after boot, then every 30) re-measures it on this unit.
- The 30-minute edge refresh restarts the resolver → a ~2 s dnsmasq-falls-back window
  every half hour. Upstream behaviour; recorded rather than hidden.
- A dnsmasq restart drops DHCP service for about a second (leases are on disk).
- The resolver is **not** covered by `tests/smoke_endpoints.sh`'s semantic layer yet.

## Rollback

```sh
cd deploy-x16/smartdns && ./install.sh --uninstall
```

Restores the vendor dnsmasq config (`/tmp/dnsmasq.conf.vendor`, else strips the
marker block), restarts dnsmasq, removes the hook lines, units, binary and helper,
and parks the config as `smartdns.conf.removed`. The page stays and correctly
reports `enabled:false`.
