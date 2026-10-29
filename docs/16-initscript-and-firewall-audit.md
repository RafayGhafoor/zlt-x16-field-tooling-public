# 16 — Initscript & Firewall Audit (ZLT X16)

Deep read of all **82** scripts in `/etc/initscripts/` (mirrored at
[`../device-etc/initscripts/`](../device-etc/initscripts/)), with the live
rule set and running processes cross-checked.

---

## 1. Where every iptables rule actually comes from

Confirmed by reading the scripts and matching the observed live rule order.

| Chain / rule | Source | Notes |
|---|---|---|
| `prerouting_mdl_chain`, `postrouting_mdl_chain`, `postrouting_dialer_chain` | `/bin/firewalltools` (binary, 593 KB) | built by the closed-source daemon |
| `-A postrouting_mdl_chain -o rmnet_data0 -j MASQUERADE` | `firewalltools` | the only NAT rule |
| `-A prerouting_mdl_chain -d <WAN_IP> -i rmnet_data0 -j DNAT --to 127.0.0.1` | `firewalltools` | WAN→router self-DNAT |
| `input_mdl_chain` WAN DROPs (tcp 22/80/443, icmp8) | `firewalltools` | applied to **IPv4 and IPv6** (`ip6tables -S input_mdl_chain` is identical) |
| `forward_mdl_chain … TCPMSS --clamp-mss-to-pmtu` | `firewalltools` | works — 7573 pkts matched |
| `parental_input_mdl_chain`, `parental_forward_mdl_chain` | `firewalltools` + `/bin/parent_control` | parental-control filtering |
| `flow` chain | `/bin/flow_ctrl` | flow accounting hook |
| `syn-flood` | **`ddos.sh:24-26`** | gated by `USR_DDOS_FUNC_SW` |
| `ack-flood` | **`ddos.sh:28-30`** | gated by `USR_DDOS_FUNC_SW` |
| `nmap_scan` (tcp 53/5555/**22** SYN DROP) | **`ddos.sh:50-58`** | ⚠️ **NOT gated** — always applied |

`start_firewalltools` itself contains no rules at all:

```sh
# /etc/initscripts/start_firewalltools
start)  firewalltools &   ;;
stop)   killall -9 firewalltools ;;
restart) iptables -t filter -D INPUT -i rmnet_data0 ... --dport 443 -j DROP
         iptables -t filter -D INPUT -i rmnet_data0 ... --dport 80  -j DROP
         killall -9 firewalltools ; firewalltools & ;;
```

### The `ack-flood` rule is INPUT-only — correction to an earlier claim

```sh
# ddos.sh:29-30
iptables -A INPUT -p tcp -m multiport --dport ${remote_web_port},443 \
         --tcp-flags FIN,SYN,RST,ACK ACK -j ack-flood
iptables -A ack-flood -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT
```

> **This is in `INPUT`, so it only governs traffic addressed to the router
> itself — not forwarded LAN→internet traffic.** A speedtest from a LAN client
> traverses `FORWARD`, so **this rule cannot cause a speedtest to fail.** An
> earlier note in this repo implied it could; that was wrong.
>
> It can still matter operationally: it will lock you out of the router's own
> admin UI if one client opens >10 connections to it. `USR_WEB_LOGIN_FROM_WAN_PORT`
> is `80`, which is why the rule reads `80,443`.

`USR_DDOS_FUNC_SW = 1`, `USR_DDOS_DEFENCE_SYN_FLOOD_SW = 1`.

`ddos.sh` also sets, whenever it runs:

```
net.ipv4.tcp_syncookies      = 1
net.ipv4.tcp_synack_retries  = 3
net.ipv4.tcp_max_syn_backlog = 2048
```

(observed values match exactly — so these are not vendor image defaults, they are
imposed by this script at every boot).

### Runtime rebuild points (things that can resurrect vendor rules)

| When | What |
|---|---|
| Boot, `StartTZApp` line 30 | `start_firewalltools start` → `firewalltools &` |
| Boot, `StartTZApp` line 102 | `ddos.sh` → **re-adds syn-flood, ack-flood, nmap_scan** |
| WAN up/down | `firewalltools` re-applies the `*_mdl_chain` set |
| Any web-UI config write | TZApp re-runs the relevant CGI handler, which can rebuild chains |
| `parent_control` / `flow_ctrl` | own their chains, refresh independently |

**This is why our local tuning is anchored after line 102, not after
`start_firewalltools`.** See §5.

---

## 2. Security findings, ranked

### S1 — HIGH: arbitrary root command injection via the web config path

Direct evidence on this device:

```
/productinfo/tzcfg/iptables/iptables_dmz_function
{"enabled":"1","ip":"127.0.0.1;busybox telnetd -l /bin/sh","cmd":172,"subcmd":6,...}
```

The `ip` field holds a **semicolon-chained shell command** which TZApp executes
**as root**. This is precisely how the unauthenticated port-23 telnet root shell
exists on this box.

Any actor able to POST to the admin UI (or to any save-handler with a
shell-metacharacter field) gets root. Treat the web UI as a root RCE surface.

**This is confirmed as the actual root path used on this unit** — including the
hardcoded `superadmin` / `<super-admin-pw-redacted>` credential that was used to reach the
handler. Full chain, timeline and remediation:
[20-device-unlock-analysis.md](20-device-unlock-analysis.md).

### S2 — HIGH: admin web UI runs as root

```sh
# /etc/initscripts/start_tz_httpd:49-66
user=root
port=$port1                 # USR_WEB_LOGIN_FROM_WAN_PORT = 80
dir=/tzwww
cgipat=cgi-bin/*
```
plus a second instance on 443 with a **fixed** `certfile=/bin/mini_httpd.pem`
(shared key across every unit of this model).

Observed: `mini_httpd` listening on `:::80` and `:::443` (wildcard, both stacks),
`/bin/mini_httpd -C /tmp/mini_httpd.conf` running as **root**.
`REMOTE_LOGIN_ENABLE` is empty, so the WAN-login branch is skipped.

Mitigation that exists: `firewalltools` drops tcp 80/443 from `rmnet_data0` in
both `iptables` and `ip6tables`. `EnableWebserverWWANAccess=0`.

### S3 — HIGH: port 23 telnetd, no authentication, root shell

`busybox telnetd -l /bin/sh` (PID from boot). No login handler — it drops
straight to `/ #`. Note the vendor's own `start_telnet` is different and safer
(`telnetd -l /etc/tzscript/telnet_login.sh -p 9876`, gated by
`SYS_TELNET_SWITCH`), and that switch is `0`. So the running telnetd is the
debug toggle from S1, not the vendor path.

### S4 — HIGH: port 8080 unauthenticated QManager, **no firewall rule, wildcard bind**

```
busybox httpd -p 8080 -h /data/qmanager/www     # no -c config => NO auth
netstat: :::8080 LISTEN
iptables -S | grep -c 8080  ->  0               # no rule at all
```

`INPUT` policy is `ACCEPT`; the only WAN blocks are the explicit DROPs for
tcp 22/80/443 in `input_mdl_chain`. **Port 8080 is therefore reachable from the
cellular WAN.** Today the WAN address is carrier-CGNAT (`10.220.84.156/29`) so it
is not reachable from the public internet, but it is reachable from inside the
carrier's private network, and it would be fully exposed if a public IP were
assigned.

Also: `/data/qmanager` was deployed at 02:52–02:53 on 2026-10-26 and is started
by **nothing in `/etc/initscripts/`** (verified — the only `8080` hits in
`power_config` are register offsets).

**Correction (2026-10-26): an earlier version of this section said QManager
"will not survive a reboot". That is WRONG.** It is not started from
`/etc/initscripts/`, but it *is* installed as systemd units under
`/etc/systemd/system/` (`qmanager-httpd`, `qmanager-ping`, `qmanager-poller`,
`qmanager-traffic`), all `WantedBy=multi-user.target`, and verified enabled:

```
$ systemctl is-enabled qmanager-httpd.service qmanager-poller.service
enabled
enabled
```

So the unauthenticated root listener **does** come back on every boot. The
exposure is persistent, not transient. See
[19-vulnerability-assessment.md](19-vulnerability-assessment.md) §V5.

**If you intend to keep QManager running, add:**

```sh
iptables -I INPUT 1 -i bridge0 -p tcp --dport 8080 -j ACCEPT
iptables -A input_mdl_chain -i rmnet_data0 -p tcp --dport 8080 -j DROP
```
and give busybox httpd an auth file (`-c`) or front it with something that has
authentication.

### S5 — MEDIUM: vendor factory SSH key

`/home/root/.ssh/authorized_keys` shipped containing
`ssh-rsa AAAA… linweiqiang@server`. See doc 14 §4.

### S6 — MEDIUM: `tz_upgrade_client` is a LAN firmware-push listener

```sh
# start_upgrade_client.sh:6
test -x /bin/tz_upgrade_client && /bin/tz_upgrade_client -i bridge0 &
```

Given the S1 command-injection primitive, a LAN device that can talk to this
port could potentially trigger an upgrade. **Currently not running** — keep it
that way unless needed.

### S7 — MEDIUM: `tftp_server` runs at boot as `system`

`/sbin/tftp_server` (PID 290, `tftp_server.service`, `DefaultDependencies=no`).
At inspection it held **no bound socket**, so it is currently inert, but it is a
file-transfer service enabled by default. Disable if unused:

```sh
systemctl disable --now tftp_server.service
```

### S8 — LOW: `start_netcwmpd` has a shell syntax bug — TR-069 never starts

```sh
# start_netcwmpd:38
if [ -z "`pidof netcwmpd`"];then      # <-- no space before ]
```

The `]` is glued to the quoted string, so the `test` command fails and the
`then` branch never runs. Confirmed: `netcwmpd` is **not** running even though
`USR_TR069_SERVER_IP=183.6.18.43` is configured. Accidentally protective, but it
means remote management silently does not work.

### S9 — LOW: `start_parent_ctrl` logic bug + verbose leak

```sh
set -x                                        # leaks to the console/log
case "$parent_ctrl_sw" in
  1) if [ "$parent_ctrl_sw" = "0" ]; then exit 0; fi   # dead code
     parent_control & ;;
  *) exit 1 ;;
esac
```

The inner test can never be true. Also `set -x` is left on unconditionally.
(`parent_control` **is** running — `USR_PARENTAL_CONTROL_SW=1`.)

### S10 — LOW: misleading usage strings

- `start_radvd:69` prints `Usage telnetd { start | stop | restart }`
- `start_unormal_reboot:13` prints `Usage adbd { ... }`
- `start_fota` uses `==` inside `[ ]` (bashism under `#!/bin/sh`)

### S11 — INFO: internal services bound on the LAN

| Listener | Process |
|---|---|
| `192.168.3.1:7777` tcp | `qmi_ip_multiclient` |
| `192.168.3.1:7755` udp | `qmi_ip_multiclient` |
| `:::80`, `:::443` | `mini_httpd` (root) |
| `:::53`, `:53` | `dnsmasq` |
| `:::8080` | `busybox httpd` (QManager) |
| `:::22` | dropbear (ours) |
| `:::23` | `busybox telnetd` |

QMI IPC on the LAN is normal for QCMAP platforms; it should not be reachable
from the WAN.

### Clean / disabled (verified, no action needed)

| Item | State |
|---|---|
| `USR_FOTA_SWITCH` | `0` → FOTA daemon not started |
| `SYS_ADB_SWITCH` | `0` → adbd not started |
| `SYS_TELNET_SWITCH` | `0` → vendor telnet path off |
| `rpcapd` | not running |
| `netcwmpd` (TR-069) | not running (because of S8) |
| `tz_upgrade_client` | not running |
| `fota` | not running |

---

## 3. What this means for the "speedtest kills internet" symptom

Honest assessment after reading every script:

- **None of the vendor firewall rules can break a forwarded speedtest.**
  `syn-flood`, `ack-flood` and `nmap_scan` are all `INPUT`-scoped, i.e. they
  police traffic *to the router*. Forwarded LAN→WAN traffic goes through
  `FORWARD` → `parental_forward_mdl_chain` → `forward_mdl_chain` → `flow` →
  `ACCEPT`. All permissive.
- The only `FORWARD`-table rule that touches traffic is the MSS clamp, and it is
  correct (`--clamp-mss-to-pmtu` → MSS 1360 on a 1400 MTU WAN).
- So the firewall is **not** the cause. This strengthens doc 12's conclusion that
  the fault is the cellular bearer being torn down at the network layer, below
  Linux routing.

The genuinely useful conclusion from this audit is a **security** one, not a
performance one: this box ships a root-privileged, unauthenticated web UI plus a
command-injection primitive, with telnet and a second unauthenticated HTTP server
live on the LAN.

---

## 4. Safe, reversible tuning options

| # | Change | Command | Risk |
|---|---|---|---|
| 1 | Disable only the `ack-flood` connlimit (web-UI lockout) | `iptables -I INPUT 1 -i bridge0 -p tcp --dport 22 -j ACCEPT; /etc/initscripts/zlt-fwtune` | none — INPUT only |
| 2 | Disable *all* DDOS chains the vendor way | `mdlcfg -a USR_DDOS_FUNC_SW=0 && mdlcfg -c` then reboot | loses syn-flood protection; `nmap_scan` stays regardless |
| 3 | Raise the SYN rate limit if legitimate SYNs are dropped | edit `ddos.sh:26` `--limit 12/s --limit-burst 24` | INPUT only |
| 4 | Block 8080 from the WAN | `iptables -A input_mdl_chain -i rmnet_data0 -p tcp --dport 8080 -j DROP` | keeps LAN access |
| 5 | Disable unused tftp | `systemctl disable --now tftp_server.service` | none if unused |
| 6 | Kill unauthenticated telnet | `killall telnetd` + remove the saved debug toggle | you lose the no-auth console (SSH replaces it) |

Items 1 and 4 are the two worth doing. Item 6 is the biggest security win.

---

## 5. Boot ordering — what we changed and why

`/etc/initscripts/StartTZApp` runs services in sequence. Final ordering around
the parts that matter:

```
 15:  /etc/initscripts/start_telnet start
 17:  /etc/initscripts/start_ssh start          <-- starts dropbear early
 30:  /etc/initscripts/start_firewalltools start
102:  /etc/initscripts/ddos.sh                  <-- re-adds ack-flood!
103:  ### local firewall tuning + ssh allow, applied AFTER ddos.sh
104:  /etc/initscripts/zlt-fwtune              <-- flushes ack-flood
105:  /etc/initscripts/start_ssh start         <-- re-asserts port-22 ACCEPT
111:  /etc/initscripts/start_unormal_reboot start
```

Two ordering bugs were found and fixed during this work:

1. The tuning hook was first placed after `start_firewalltools` (line 30) —
   **too early**, because `ddos.sh` at line 102 re-adds `ack-flood`. Moved to
   line 104.
2. A duplicate `start_ssh` call was left at line 32. Removed (line 17 covers the
   early start, line 105 the post-firewall re-assert).

Both are idempotent, so the 2-minute `zlt-ssh-watchdog` timer also re-asserts
them if anything rebuilds the rules at runtime.

Original file preserved at
`/data/zlt-backups/2026-10-26/etc/initscripts/StartTZApp.orig`
(and `StartTZApp.before-reorder`).
