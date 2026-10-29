# 02 — How QManager works (runtime contract)

Source: `/tmp/qm` = `RafayGhafoor/QManager-RM520N`, branch `greenpacket`.
Full report: [raw/scout-01-qmanager-architecture.md](raw/scout-01-qmanager-architecture.md).

> The branch is **not** stock upstream. It is upstream QManager already ported once to a
> non-Entware, read-only-root device (GreenPacket O5A Pro / Quectel RG520N-EB). That port is
> the template for this one.

## Shape

```
browser ── fetch('/cgi-bin/quecmanager/<area>/<endpoint>.sh')
   ↑ static export (out/)                      ↓ shebang'd POSIX shell + jq
busybox httpd / lighttpd :8080              reads tmpfs JSON written by root daemons
                                             or issues AT via qcmd → atcli_smd11
```

- **No Node on device.** `next.config.ts` → `output:"export"`, `trailingSlash:true`
  (every route is `route/index.html`, so a plain docroot server needs no rewrite rules).
- **No database, no app server.** State = JSON files in `/tmp`, config = JSON in `/etc/qmanager`.
- **87 CGI endpoints**, grouped: `at_cmd auth bands cellular device frequency monitoring
  network profiles public scenarios settings system tower vpn`.
- **Auth**: salted SHA-256 in `/etc/qmanager/auth.json`; session token file per login under
  `/tmp/qmanager_sessions/`; cookies `qm_session` (HttpOnly) + `qm_logged_in`; 1 h TTL;
  rate limit 5 attempts with a `30/120/300/900 s` ladder. `setup_required` gate until a
  password exists.

## Daemons (all write tmpfs JSON, all read by CGIs)

| Daemon | Fills | Notes |
|---|---|---|
| `qmanager_poller` | `/tmp/qmanager_status.json` | **the only status AT consumer**; tiered (QENG/QCAINFO each cycle, QRSRP/QRSRQ/QSINR every 5, identity every ~15, PHY ~60 s via `ubus call modemd status`) |
| `qmanager_ping` | `qmanager_ping.json` + history | reachability/latency |
| `qmanager_traffic` (Rust) | `qmanager_traffic.json` + symlink `www/live-traffic.json` | 1 Hz counters via `ETHTOOL_GSTATS` |
| `qmanager_dpi_run` + `tpws` | rules | TCP desync; QUIC handled by a separate REJECT |
| `qmanager_dns_*` + smartdns | `qmanager_dns.json` | resolver + edge selection |
| `qmanager_ippt_apply` | — | **Qualcomm `ql_qmap` binary** — dead on a non-Qualcomm vendor stack |
| `qmanager_atd` (Rust, opt-in) | unix socket | alternate AT broker, `[Install]` disabled |

## Runtime dependencies (break-the-whole-UI if missing)

| Bin | Origin upstream | GreenPacket workaround |
|---|---|---|
| **`jq`** | Entware `/opt/bin/jq` | static armhf binary in payload `bin/` — **142 files depend on it** |
| `atcli_smd11` | prebuilt ARM binary, talks `/dev/smd11` | **shell shim** → `/dev/at_mdm0` |
| `sms_tool` | prebuilt static ARM | wrapper + `sms_tool.bin`, device `-d /dev/smd7`, vendor radio lock |
| `lighttpd` | Entware + 4 modules | **busybox httpd** instead |
| `sudo` | Entware | passthrough shim (CGI already runs as root) |
| `flock`, `timeout`, `openssl`, `iptables`, `curl` | Entware / busybox / vendor | `qm_timeout()` detects the two `timeout` dialects |

## The single AT seam

`scripts/usr/bin/qcmd` is the only gatekeeper:

```sh
LOCK_FILE="/tmp/qmanager_at.lock"
AT_CLI="/usr/bin/atcli_smd11"
AT_DEVICE="/dev/smd11"
# flock poll loop 1 s, LOCK_WAIT_SHORT=20 / LOCK_WAIT_LONG=45
```

`atcli_smd11` **always exits 0**; `qcmd` parses `OK`/`ERROR` from the text.
Everything else (`parse_at.sh`, the poller, all 87 CGIs) speaks only `qcmd`.
**Port that one file and the rest of the app is unchanged.**

## Serving on 8080 (already parameterised)

`deploy/qm_serve.sh` — `PORT="${QM_PORT:-8080}"`, `DOCROOT=/data/qmanager/www`,
`busybox httpd -p "$PORT" -h "$DOCROOT"` as root (CGI needs AT + `/etc/qmanager` writes).

Port audit: 80 and 443 only in the *upstream lighttpd* config; 8080 is the only server port
that varies, and 8080 is **free on the X16**. One collision exists in upstream units:
`qmanager-console.service` (ttyd) also claims 8080 — do not deploy it.

## Existing portability machinery (reuse, don't reinvent)

- `scripts/usr/lib/qmanager/hw_profile.sh` — profile tiers keyed on model/SoC; **`SDX55` is
  already in the table**, and caps are advisory (never a security boundary).
  Output `/etc/qmanager/platform.json`.
- `scripts/usr/lib/qmanager/platform.sh` — the init-system seam (`svc_start/stop/enable`).
  On the X16 this is plain `systemctl`, so it works nearly as-is.
- `deploy/` — the whole GreenPacket adaptation layer: shims, path rewriter, boot hook,
  modem-readiness gate, per-daemon unit overrides.
