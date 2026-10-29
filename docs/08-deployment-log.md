# 08 — Deployment log (what was actually done, verified)

Date: 2026-10-26 · device: ZLT X16 · access: `ssh root@192.168.3.1` (password auth)

> The link to the X16 is flaky (multi-WAN smart load balancing upstream). Every
> command below ran through a **retry wrapper**. `scp` does not work over this
> dropbear — stream files with `ssh root@host 'cat > /path' < file`.

## Final state

| | |
|---|---|
| UI | **`http://192.168.3.1:8080/`** — password `<redacted-password>` |
| Vendor UI | `http://192.168.3.1/` and `:443` — **untouched, still 200** |
| Services | `qmanager-httpd.service`, `qmanager-poller.service` — **active + enabled** |
| Modem data | live: LTE B3, 20+10+10 MHz CA (B3+B1+B5), RSRP −94, RSRQ −7, SINR 12–17, carrier `Onic`, APN `Ufone.internet`, WAN `10.220.84.156` |
| Poller errors | `[]` |
| Dialer AT failures | **0** — `grep -c "AT send failed" /tmp/logs/DIALER.log` |
| Payload | `/data/qmanager` 16.7 MB; config `/etc/qmanager` |

## Verified on-device facts

| Item | Value |
|---|---|
| Kernel / CPU | `5.4.210-perf`, `armv7l`, **1 CPU** |
| Systemd | 244 |
| Writable | `/data`, `/etc`, `/persist`, `/cache` (ubi2_0 173.5 MB, 164.5 MB free) — `/` and `/firmware` are not |
| Vendor web | `/bin/mini_httpd` on **:80 + :443**, docroot `simcom_war`, API `/cgi-bin/http.cgi` |
| busybox | 1.31.1, `httpd` present, **`flock -w` unsupported** |
| Present | curl, wget, flock, timeout, openssl, microcom, dnsmasq, iptables (`/usr/sbin/xtables-legacy-multi`), bash |
| Absent | **jq**, python, lighttpd, socat |
| **AT entry point** | **`/bin/atcmd`** → `atcmd_daemon` (sockmsg `APP_ID_ATCMD`) |
| Also | `/dev/at_mdm0`, `/dev/smd7..11`, `qmicli` at `/data/zlt-mbn-recovery/bin/` |

## The transport decision (final)

`/bin/atcmd "AT+CGMM"` → `SIMCOM_SIM8260E`. It is a client of the vendor's AT
daemon, so it inherits the daemon's serialisation against `/bin/dialer`. **No QMI
bridge was needed and no device node is opened directly.** Measured after ~1 h of
polling: **zero** "AT send failed" lines in the dialer log.

## The dialect layer (Option A)

`deploy-x16/atcli_smd11` rewrites Quectel commands to SIMCom ones and re-emits
the responses in the exact Quectel shape the existing parsers consume — so
`parse_at.sh`, the 87 CGIs and the poller body are **unchanged**.

| QManager asks | Device answers with | Synthesised as |
|---|---|---|
| `AT+QENG="servingcell"` | `AT+CPSI?` | `+QENG: "servingcell","CONNECT","LTE","FDD",410,03,CA52865,256,1312,3,5,5,29DD,-94,-7,-80,15` |
| `AT+QCAINFO` | `AT+CCAINFO?` | `+QCAINFO: "PCC"/"SCC",<earfcn>,<bw>,LTE BAND <n>,0,<pci>,<rsrp>,<rsrq>,<rssi>,-` |
| `AT+QCCID` | `AT+CICCID` | prefix rewritten to `+QCCID:` |
| `AT+CVERSION` | `ATI` | Quectel banner (`VERSION:` / `Authors:`), **model line first** |
| `AT+QTEMP` | thermal sysfs `modem-*` | `+QTEMP: "modem-0",38` |
| `AT+QNWPREFCFG="lte_band"` etc. | `AT+CSYSSEL="lte_band"` | `+QNWPREFCFG: "lte_band",1:3:5:8` |
| `AT+QNWPREFCFG="mode_pref"` | `AT+CNMP?` | `AUTO` / `LTE` / `NR5G`; writes map back to `CNMP=2/38/109` |
| `AT+QNWPREFCFG="ue_capability_band"` | `AT+CSYSSEL=?` | capability line + the three band keys `bands/current.sh` greps |
| `AT+QNWPREFCFG="nr5g_disable_mode"` | `AT+CSYSSEL="nr5g_disable"` | same 0/1/2 |
| `AT+CGCONTRDP` | `AT+CGCONTRDP` + `ip addr` | **only the row whose address is the WAN address** |
| `AT+QUIMSLOT?` / `AT+QSIMSTAT?` / `AT+QSIMDET?` | — | single-slot answers |
| `AT+QRSRP/QRSRQ/QSINR` | — | empty `OK` — per-antenna data does not exist here; faking it would fabricate diversity |
| `AT+QNWCFG`, `AT+QGETCAPABILITY`, `AT+QMAP*` | — | empty `OK` |

Everything unrecognised is passed through verbatim.

### Four bugs found and fixed by measuring, not guessing

1. **RSRP and RSRQ do not share a scale.** `+CPSI` RSRP is tenths of a dBm
   (−940 → −94) but RSRQ is **hundredths** (−668 → −6.68 → −7). Using the tenths
   rule for both produced `rsrq: -66`, outside RSRQ's physical range.
   Cross-checked against `+CCAINFO` PCC on the same second:
   CPSI −668/−638/−656 ⇔ RSRQ −7 dB.
2. **`+CCAINFO` SCC rows carry one extra field after PCI**, so the metric
   columns sit at 7/8/9 for SCC but 6/7/8 for PCC. Both are handled explicitly,
   and every metric is range-validated (RSSI ≥ RSRP, RSRQ −25…−3) because a
   wrong pick plots as if it were measured. Validation caught a transient
   `B1 rsrp: -44` that was really field misalignment.
3. **The APN was a dormant profile.** Six PDP contexts are provisioned; the
   parser takes the first non-IMS row, which is `GPRS.SWISSCOM.CH` (CID 1), not
   the live `Ufone.internet` (CID 6). The shim now returns only the row whose
   local address equals `rmnet_data0`'s address.
4. **`model` came out as `SIMCOM INCORPORATED`.** The poller takes the first
   non-prefixed line after the CVERSION block as the model, so the model line
   must precede the manufacturer line.

Two firmware quirks confirmed against real output:

- `+CGCONTRDP` **omits the gateway** and leaves the address unquoted:
  `6,6,"Ufone.internet",10.220.84.156,,39.39.39.39,182.176.100.89`. The real
  gateway (dialer log) is `10.220.84.157`.
- `AT+CESQ` and bare `AT+CSYSSEL?` return **ERROR** (the latter needs a key).

## Endpoint status (measured, with a valid session cookie)

| Endpoint | Result |
|---|---|
| `public/overview.sh` | **200** `state: ok`, modem reachable, 3 CA bands, real values |
| `cellular/settings.sh` | **200** `success: true` — sim_slot 1, cfun 1, mode `AUTO`, nr5g 0, roam 1 |
| `cellular/apn.sh` | **200** 6 profiles, `data_source: "at"` |
| `device/about.sh` | **200** model/manufacturer/firmware correct |
| `system/logs.sh` | **200** |
| `bands/current.sh` | **200** LTE `1:3:5:8`, NSA/SA `1:8:40:41:78` |
| `cellular/sms.sh` | **200** storage 17/23 used — but see limitation |

## Known limitation: SMS bodies cannot be read

`AT+CMGR`, `AT+CMGL` (text and PDU modes) all answer `+CMS ERROR: Unknown error`
on this firmware, while `AT+CPMS` counts **17 messages of 23**. The vendor reads
SMS through a different bus application (`APP_ID_TZ_SMS_MGR`), not `APP_ID_ATCMD`.

`deploy-x16/sms_tool` therefore implements what is real (`status` via `AT+CPMS`,
`at` pass-through, `delete` via `AT+CMGD`) and returns an **empty list fast** for
`recv`. The previous (GreenPacket) wrapper opened `/dev/smd7` and blocked ~25 s
per call, freezing the SMS page — that hang is gone. `send` is refused
explicitly, because `AT+CMGS` needs an interactive `> ` prompt the broker does
not provide.

## Files

```
/data/qmanager/                 payload root (16.7 MB)
  bin/atcli_smd11               ← deploy-x16/atcli_smd11   (transport + dialect)
  bin/sms_tool                  ← deploy-x16/sms_tool      (AT-broker SMS shim)
  bin/qm_serve.sh               ← deploy-x16/qm_serve.sh   (busybox httpd :8080)
  bin/qm_pathfix_x16.sh         ← deploy-x16/qm_pathfix_x16.sh
  bin/jq                        static armhf (no glibc constraint)
/etc/systemd/system/qmanager-httpd.service
/etc/systemd/system/qmanager-poller.service
/etc/systemd/system/qmanager-ping.service
/etc/systemd/system/qmanager-traffic.service
/etc/qmanager/                  auth.json, sessions
```

> **Re-deploy note:** `bin/atcli_smd11` and `bin/sms_tool` are X16-specific. A
> fresh payload stage ships the GreenPacket versions — always copy the two files
> from `deploy-x16/` after staging, then re-run `qm_pathfix_x16.sh`.

## Reproduce from scratch

```bash
# host
cd /tmp/qm && bun install --frozen-lockfile && bun run build
STAGE=/tmp/qm-stage; mkdir -p $STAGE/www $STAGE/lib $STAGE/bin $STAGE/www/cgi-bin
cp -a out/. $STAGE/www/
cp -a scripts/www/cgi-bin/quecmanager $STAGE/www/cgi-bin/
cp -a scripts/usr/lib/qmanager/. $STAGE/lib/
cp -a scripts/usr/bin/. $STAGE/bin/
cp -a deploy/atcli_smd11 deploy/sudo $STAGE/bin/
cp dependencies/sms_tool $STAGE/bin/sms_tool.bin
cp deploy-x16/atcli_smd11 deploy-x16/sms_tool $STAGE/bin/     # ← X16 overrides
curl -fsSL -o $STAGE/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-armhf
curl -fsSL -o $STAGE/etc-cacert.pem https://curl.se/ca/cacert.pem
find $STAGE/www/cgi-bin -type f -exec chmod 755 {} +         # 85/87 ship non-exec
COPYFILE_DISABLE=1 tar czf /tmp/qm-payload.tar.gz -C $STAGE .

# device
ssh root@192.168.3.1 'mkdir -p /data/qmanager'
ssh root@192.168.3.1 'cat > /tmp/qm-payload.tar.gz' < /tmp/qm-payload.tar.gz
ssh root@192.168.3.1 '
  tar xzf /tmp/qm-payload.tar.gz -C /data/qmanager
  find /data/qmanager -name "._*" -delete
  chown -R root:root /data/qmanager && chmod 755 /data/qmanager
  find /data/qmanager/bin /data/qmanager/www/cgi-bin -type f -exec chmod 755 {} +
  mkdir -p /data/qmanager/etc && mv /data/qmanager/etc-cacert.pem /data/qmanager/etc/cacert.pem
  mkdir -p /etc/qmanager && chmod 777 /etc/qmanager
  /data/qmanager/bin/qm_pathfix_x16.sh
  systemctl daemon-reload
  systemctl enable --now qmanager-httpd.service qmanager-poller.service'
# then browse :8080 and set the password
```

## Uninstall

```sh
systemctl disable --now qmanager-httpd.service qmanager-poller.service
rm -f /etc/systemd/system/qmanager-*.service
systemctl daemon-reload
rm -rf /data/qmanager /etc/qmanager
```
