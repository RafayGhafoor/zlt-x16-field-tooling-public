# GAP-02 — Vendor backend capability probe (what this firmware can actually DO)

**Scope:** read-only probe of on-device software/kernel support on the ZLT X16 ODU,
`root@192.168.3.1`. Nothing was changed. Every ssh call was wrapped in a retry loop
(8–12 attempts, 3 s spacing) because the link drops; one drop occurred mid-probe and
recovered without a reboot (`uptime` → `up 16 min` before and after).

**Purpose:** a capability matrix so a plan can say *"feature X is cheap because the
binary is already here"* vs *"feature Y needs a new binary on a 1-core box with no
compiler"*.

**Legend:** **[V]** = verified on device this session · **[I]** = inferred from a
verified artifact (the inference is stated). Sample time ~23:00, device up 16+ min.

---

## 0. Headline — the five things that change plans

1. **`iptables` works perfectly; it is simply not on `PATH`.** `/usr/sbin/iptables` is
   `iptables v1.8.4 (legacy)` with a **live, populated NAT table** (MASQUERADE + DNAT +
   REDIRECT all in use right now). Almost every prior note saying "no iptables on this
   box" is a `PATH` artifact, not a capability gap. **[V]**
   ```
   $ /usr/sbin/iptables -V
   iptables v1.8.4 (legacy)
   ```
   Cause, verbatim from `/etc/profile`: `/sbin` & `/usr/sbin` are added **only** when
   `$HOME = /home/root`, and the dropbear root login has `PATH=/usr/bin:/bin`.
   ```
   PATH="/usr/local/bin:/usr/bin:/bin"
   # Add /sbin & co to $PATH for the root user
   [ "$HOME" != "/home/root" ] || PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
   ```
   This is the same root cause behind the long-standing "`ip`/`ifconfig` are not in PATH"
   folklore: `/sbin/ip` is **iproute2 5.10.0**, 465 KB, fully working.

2. **There are two real scripting languages, not zero.** `perl 5.30.1` and `lua 5.2.2`
   both execute. The usual assumption ("shell only") is wrong. **[V]**
   ```
   $ perl -v          → This is perl 5, version 30, subversion 1 (v5.30.1) built for arm-linux
   $ perl -e 'print "perl_ok\n"'   → perl_ok
   $ lua -v           → Lua 5.2.2  Copyright (C) 1994-2013 Lua.org, PUC-Rio
   $ echo 'print("lua_ok",_VERSION, string.format("%d",42))' | lua -   → lua_ok  Lua 5.2  42
   ```
   There is still **no python, no compiler, no `make`, no `git`** (§4), so any new
   backend is shell/perl/lua — but the ceiling is higher than shell.

3. **Zero loadable kernel modules exist on disk.** `/lib/modules/5.4.210-perf/` has a
   577-entry `modules.builtin` and `find -name '*.ko*' | wc -l` → **0**. Everything is
   built in. A feature needing a module that is *not* built in is **impossible** without
   reflashing the kernel. **[V]**

4. **A whole enterprise network stack is installed, configured-or-not, and idle:**
   strongSwan 5.8.4, xl2tpd 1.3.7, pppd 2.4.7, miniupnpd 2.2.3, snmpd 5.9.1, ddclient,
   Tailscale 1.92.5, radvd, siproxd, ftpd/tftpd. None of them is running. Several are
   separate multi-week features for free. **§5 is the money section.**

5. **CPU, not RAM or disk, is the binding constraint.** 1× Cortex-A7, and the box was
   sitting at `load average: 9.09, 7.06, 4.44` while essentially idle from a user's
   point of view. RAM is fine (479 MB available of 645 MB) and there is 79 MB free on
   `/data` + 298 MB on `/cache`. Any new daemon must be near-zero CPU, and any polling
   design must be measured against a machine already at load 9. **[V]**

---

## 1. Capability matrix

`avail?` column: ✅ available · ⚠️ present but broken/unconfigured · ❌ absent.
"Unlocks" names a candidate feature from the product side; where nothing was specified
I name the obvious capability the evidence supports.

### 1.1 Firewall / NAT / connection tracking

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| iptables (legacy) | ✅ | `/usr/sbin/iptables` → `xtables-legacy-multi` (64228 B), **v1.8.4 (legacy)** | **Not on `PATH`** (§0). Full CLI: `-A -I -D -L -S -N -X`, `-t {raw,nat,mangle,filter}`. Live tables: 73 lines in `iptables-save`. | everything stateful-firewall: per-client rules, parental control, blocklists, QoS marks |
| iptables-save / -restore | ✅ | `/usr/sbin/iptables-save`, `iptables-restore` (+ `-legacy` variants), `/usr/bin/iptables-xml` | Atomic rule-set load → idempotent boot application | any module that must reapply rules at boot |
| ip6tables | ✅ | `/usr/sbin/ip6tables` v1.8.4, `ip6tables-save` | **`ip6tables -t nat` already has DNAT/MASQUERADE libs** (`libip6t_DNAT.so`, `libip6t_MASQUERADE.so`); live v6 filter table is populated with vendor chains | IPv6 WAN, v6 port-forward, v6 firewall parity |
| ebtables | ✅ | `/sbin/ebtables` **v2.0.10-4 (December 2011)** + `ebtables-restore/-save` | `kernel/net/bridge/netfilter/ebtables.ko` builtin | L2/MAC filtering, per-SSID policy, MAC-spoof guard |
| conntrack tooling | ✅ | `/usr/sbin/conntrack`, `/usr/sbin/conntrackd`, `/usr/sbin/nfct` | live `/proc/net/nf_conntrack` | per-client connection counts, live session table in UI, DoS detection |
| nftables | ❌ | `nft` MISSING; `nf_tables.ko` **not** builtin | **Permanently impossible** — no module on disk | — (use iptables legacy) |
| NAT targets | ✅ | MASQUERADE, DNAT, SNAT, REDIRECT, NETMAP confirmed **in the live ruleset** | kernel: `nf_nat`, `iptable_nat`, `xt_MASQUERADE`, `xt_REDIRECT`, `ip6table_nat` all builtin | port forwarding, 1:1 NAT, transparent proxy, captive portal |
| TCPMSS clamp | ✅ | `xt_TCPMSS` builtin; vendor already clamps to PMTU in `forward_mdl_chain` | 472 pkts matched | the existing MTU/MSS workaround; per-route MSS |
| TPROXY / policy routing | ✅ | `xt_TPROXY` builtin, `libxt_TPROXY.so` present | binary exists, **nothing uses it** | per-app / per-device transparent proxying |
| Bandwidth matching | ✅ | `libxt_hashlimit.so` (22624 B), `libxt_connlimit.so`, `libxt_quota.so`, `libxt_recent.so`, `libxt_limit.so` | full libxt set in `/usr/lib/xtables` | per-device rate limit, connection cap, brute-force guard |
| Connection marking | ✅ | `libxt_CONNMARK.so`, `libxt_MARK.so`, `libxt_CT.so`, `libxt_CLASSIFY.so` | + `net_cls` cgroup | multi-WAN policy routing, DSCP/QoS classing |
| mangle / TTL | ✅ | `libxt_TTL.so`, `libipt_TTL.so`, `libxt_DSCP.so`, `libxt_TOS.so`; live `mangle POSTROUTING … TTL set to 65` | the TTL rule present is **ours** (`router-fix/ttl-normalise`) | TTL normalisation (already shipped), DSCP marking |
| `tc` (shaping) | ✅ | `/sbin/tc` → `tc.iproute2` **iproute2-5.10.0** (421204 B) | `sch_htb.ko` **and** `sch_cake.ko` builtin; live `rmnet_data0` already runs `mq` + per-queue `fq_codel` | real QoS, per-client bandwidth caps, bufferbloat fix (cake) |
| `ifb` (ingress shaping) | ❌ | `ifb.ko` not builtin | egress-only shaping | — (ingress needs a different trick) |

**Who does NAT today, and with what** (verbatim, `iptables -t nat -L -n -v`):
```
Chain POSTROUTING (policy ACCEPT)
 postrouting_mdl_chain  all  --  *      *       0.0.0.0/0            0.0.0.0/0
 postrouting_dialer_chain  all  --  *      *       0.0.0.0/0            0.0.0.0/0

Chain postrouting_mdl_chain (1 references)
 1404  200K MASQUERADE  all  --  *      rmnet_data0  0.0.0.0/0            0.0.0.0/0

Chain prerouting_mdl_chain (1 references)
   65 26961 DNAT       all  --  rmnet_data0 *   0.0.0.0/0            10.141.57.64         to:127.0.0.1
    0     0 DNAT       all  --  *      *       192.168.3.0/24       10.141.57.64         to:127.0.0.1

-A PREROUTING -i bridge0 -p tcp -m multiport --dports 80,443 -m addrtype ! --dst-type LOCAL -j REDIRECT --to-ports 989
```
Reading of that: the vendor does **MASQUERADE to the WAN** (that is the whole of its
"LAN → internet"), a **DNAT of the WAN IP to `127.0.0.1`** (remote-management/TR-069
plumbing, not a user feature), and a **blanket REDIRECT of bridge0 HTTP/HTTPS to port
989**, which is `tpws` (a Tor transproxy). **There is no user-facing port forwarding, no
UPnP, and no per-device policy anywhere in the ruleset.** Verified corroboration: the
vendor's own config says the firewall feature is *off* —
```
/etc/data/mobileap_firewall.xml: <FirewallEnabled>0</FirewallEnabled>
                                 <UPNPInboundPinhole>0</UPNPInboundPinhole>
```
`grep -rlE "DNAT|port_forward|portforward|PortForward" /etc/data` → **no matches**.
So: **port forwarding / UPnP / per-client firewall are all genuinely new features on a
device whose kernel and userspace already fully support them.**

**Our own payload already speaks iptables** — 13 files, incl. a purpose-built chain:
```
/data/qmanager/bin/qmanager_firewall   → CHAIN="QMANAGER_FW", PORTS="80 443",
                                          TRUSTED="lo bridge0 eth0" (+tailscale0 if installed)
/data/qmanager/bin/{smartdns,qmanager_profile_apply,qmanager_dpi_run,qmanager_dpi_install,
                    qmanager_health_check}
/data/qmanager/lib/{platform.sh,ttl_state.sh,hw_profile.sh,dpi_state.sh}
/data/qmanager/www/cgi-bin/quecmanager/{cellular/apn.sh,network/video_optimizer.sh,network/ttl.sh}
```
The pattern to copy for every new firewall feature is already in-tree: dedicated user
chain hooked into `INPUT`/`FORWARD`, `-N`/`-F`/`-hook`/`-unhook`, `Type=oneshot
RemainAfterExit=yes`.

### 1.2 DHCP / DNS

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| dnsmasq | ✅ | `/usr/bin/dnsmasq` **2.86** (290856 B), running as `dnsmasq -C /tmp/dnsmasq.conf -x /tmp/dnsmasq.pid` PID stable | single 290 KB binary, no Lua/no DNSSEC | DNS + DHCP + RA + TFTP in one process |
| dnsmasq = LAN DHCP server | ✅ | yes — listens `udp/0.0.0.0:67`, `interface=bridge0`, `dhcp-range=…192.168.3.100,192.168.3.200,…,24h`, `dhcp-authoritative` | lease file `/tmp/dnsmasq.leases`, one live lease observed | static reservations, per-host options, client list |
| dnsmasq DHCPv6 / RA | ✅ | compiled `DHCPv6`; `--enable-ra` available | unused today (v6 only on `/proc/net/ip6_tables_names`) | IPv6 LAN, SLAAC/RA |
| dnsmasq TFTP | ✅ | compiled `TFTP` | unused | provisioning, PXE, config push |
| dnsmasq `ipset` | ✅ | compiled `ipset` | unused | domain→ipset→iptables routing policy |
| dnsmasq `dhcp-script` | ✅ | `-6, --dhcp-script=<path>` present | **unused** — the natural event hook for "device joined/left" | instant client-presence detection without polling |
| dnsmasq `--dhcp-hostsfile` | ✅ | already set: `dhcp-hostsfile=/etc/data/dhcp_hosts` (persistent, writable) | **file-backed static leases with no dnsmasq restart** | DHCP reservation UI |
| dnsmasq `addn-hosts` / `address=` | ✅ | live: `address=/m.home/192.168.3.1`, `address=/rtm.home/192.168.3.1` | | local DNS names, ad-block lists |
| DNSSEC | ❌ | compile line says `no-DNSSEC` | would need a different dnsmasq build | — |
| udhcpd (busybox) | ⚠️ | `/usr/sbin/udhcpd` (busybox applet) | `/tmp/udhcpd.leases` exists but **0 bytes** — vestigial; dnsmasq is the real server | — |
| dhcpcd / dhcprelay | ✅ | `/usr/sbin/dhcpcd`, `/usr/sbin/dhcprelay`; `/etc/dhcpcd.conf` present | not running | WAN-side DHCP client modes, relay |
| bind9 client tools | ✅ | `/usr/bin/dig` (95884 B), `/usr/bin/host` (75476 B), `/usr/bin/nslookup`→`nslookup.bind` | both verified working (`dig +short localhost` → `127.0.0.1`) | DNS diagnostics page, resolver test |
| SmartDNS resolver | ✅ | ours — `smartdns` PID on `127.0.0.1:5353`, dnsmasq `server=127.0.0.1#5353`, `cache-size=2000` | already wired by `deploy-x16/smartdns` | already shipped |

Verbatim compile-time capability line — this is the authoritative answer for the whole
dnsmasq row:
```
Dnsmasq version 2.86  Copyright (c) 2000-2021 Simon Kelley
Compile time options: IPv6 GNU-getopt no-DBus no-UBus no-i18n no-IDN DHCP DHCPv6
  no-Lua TFTP no-conntrack ipset auth no-cryptohash no-DNSSEC loop-detect inotify dumpfile
```

Live `/tmp/dnsmasq.conf` (vendor-written, ours appended) — the whole DHCP surface:
```
#generate by lan_mgr sunsea_x62_lan_mgr_setup_dhcp_handler
user=root
localise-queries
dhcp-leasefile=/tmp/dnsmasq.leases
dhcp-lease-max=250
resolv-file=/tmp/resolv.conf
dhcp-hostsfile=/etc/data/dhcp_hosts
pid-file
keep-in-foreground
dhcp-authoritative
interface=bridge0
listen-address=192.168.3.1
dhcp-range=bridge0,192.168.3.100,192.168.3.200,255.255.255.0,24h
dhcp-option=bridge0,option:router,192.168.3.1
dhcp-option=bridge0,option:dns-server,192.168.3.1
dhcp-option=bridge0,option:mtu,1500
```

### 1.3 Routing / VPN / tunnels

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| iproute2 | ✅ | `/sbin/ip` → `ip.iproute2` **iproute2-5.10.0** (465688 B) | **not on `PATH`** but works: `ip -br link`, `ip route`, `ip rule` all verified | policy routing, multi-WAN, VRF-ish separation |
| policy routing | ✅ | live `ip rule`: `17000: from 192.168.3.0/24 lookup 17000` + `from all to 192.168.3.0/24 lookup 17000` | vendor already uses a custom table 17000 | multi-WAN failover (a module `qmanager_band_failover` already exists) |
| GRE | ✅ | `kernel/net/ipv4/gre.ko` **builtin**, `ip_gre.ko` builtin; `gre0` device already in `ip link` | `ip tunnel add … mode gre` | GRE tunnels, some ISP/WAN modes |
| VXLAN | ✅ | `kernel/drivers/net/vxlan.ko` **builtin** | unused | overlay networking, remote LAN bridging |
| SIT / IPIP | ✅ | `sit.ko`, `ipip.ko` builtin; `sit0`, `tunl0` devices exist | unused | 6in4/4in6 tunnels |
| TUN/TAP | ✅ | `/dev/net/tun` exists (`crw-rw-rw- 10,200`), `tun.ko` builtin, `/proc/misc: 200 tun` | `tap` not a separate module (covered by tun) | **any userspace VPN**: Tailscale, user-space WireGuard impls, OpenVPN-if-you-port-it |
| WireGuard | ❌ | `wireguard` → 0 hits in `modules.builtin`, `wg` MISSING | kernel 5.4 predates mainline WG; **cannot** be added (no loadable modules) | — (WireGuard impossible in-kernel) |
| strongSwan IPsec | ⚠️ | `/usr/sbin/ipsec` **Linux strongSwan U5.8.4/K5.4.210-perf**; `/usr/libexec/ipsec/{charon,starter,stroke,xfrmi}`, `libcharon`, `libstrongswan`, `libvici`; full plugin set (`kernel-netlink`, `aes`, `gmp`, `openssl`, `curl`, `pem`, `x509`, `attr`, `constraints`, `dnskey`, `pgp`…) | **not running, and `/etc/ipsec.conf → /tmp/ipsec.conf` which does not exist**, same for `/etc/strongswan.conf`. Complete but never initialised. | **IKEv2/IPsec VPN client or server** — a big feature, essentially free |
| L2TP | ⚠️ | `/bin/xl2tpd` **xl2tpd-1.3.7** (414404 B), `l2tp.ko` builtin, `/usr/sbin/pppd` **2.4.7** | no `/etc/xl2tpd/` and no `/etc/xl2tpd.conf`; `/etc/data/l2tp_cfg.xml` is an **empty** `<l2tpcfg/>`; `start_l2tp` initscript exists | L2TP/IPsec client — the classic "unblock region" feature |
| PPP / PPPoE | ✅ | `pppd` 2.4.7, `ppp_generic.ko` builtin, `chat` at `/usr/sbin/chat`, `slattach`, `/etc/ppp` absent | | PPPoE WAN, serial failover |
| PPTP | ❌ | `pptpd` MISSING (only `/etc/initscripts/pptp.sh` remains) | | — |
| OpenVPN | ❌ | MISSING | would need a cross-compiled ARMv7 binary | possible with a payload binary |
| Tailscale | ⚠️ | `/data/tailscale/tailscale` (25 MB) and `tailscaled` (33 MB), **v1.92.5**, both execute (`tailscaled --version` works). `/dev/net/tun` present. Unit **installed and enabled**: `/etc/systemd/system/multi-user.target.wants/tailscaled.service` → `/etc/systemd/system/tailscaled.service` | **Not running**: `tailscale status` → `failed to connect to local tailscaled; it doesn't appear to be running`. Same boot bug as the QManager units: `/etc/systemd/system` mounts at ~10.6 s, after systemd read its units. QManager ships a 24 KB `/data/qmanager/www/cgi-bin/quecmanager/vpn/tailscale.sh` page that therefore only ever shows its "Tier 2 — installed but daemon not running" state. | **remote access / mesh VPN** — one boot-hook away from working |
| `socat` | ❌ | MISSING | | — (but `atcmd`/`atcli_smd11` obviate it) |
| `stunnel` | ❌ | MISSING | `openssl s_server`/`s_client` can substitute | TLS wrapping (possible) |
| SOCKSv5 | ✅ | `/etc/data/factory_qti_socksv5_{auth,conf}.xml` — QTI SOCKSv5 config, plus `qti_socksv5_auth.xml` | unused | proxy client |

### 1.4 Services / operator tooling

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| cron | ⚠️ | `/usr/sbin/crond`, `/usr/bin/crontab` (busybox applets) | **`/var/spool/cron/crontabs` does not exist**, nor `/etc/crontabs`, nor `/etc/cron.d`; `crontab -l` → `can't change directory`. Cron is *available but never set up*. Note `/var/lib` and `/var/volatile` are tmpfs → must point `-c` at `/etc/crontabs` for persistence | scheduled tasks, nightly reboot, time-of-day parental rules |
| tcpdump | ❌ | MISSING (`/usr/sbin/tcpdump`, `/usr/bin/tcpdump`, `/bin/nc` all absent) | the real diagnostic gap | packet capture from the UI; needs a payload binary |
| nc / netcat | ❌ | MISSING | | — |
| socat | ❌ | MISSING | | — |
| `lsof` | ✅ | `/usr/bin/lsof` → busybox applet | | port→PID attribution in UI |
| `ss` | ❌ | MISSING | use `netstat` | — |
| netstat | ✅ | `/bin/netstat` (busybox) | verified, `-lnpt`/`-lnpu` both work | live socket list |
| ping / ping6 | ✅ | `/bin/ping` → `ping.iputils`; `/bin/ping6` (busybox) | `qmanager_ping` already runs a latency poller | latency graph (shipped) |
| traceroute / mtr | ✅ / ❌ | `/usr/bin/traceroute` (busybox); **mtr MISSING** | | path diagnostics |
| arp tooling | ✅ | `/sbin/arp` (busybox), `/usr/sbin/arping`, `/usr/sbin/ether-wake` | `qmanager_neighbour_scanner` exists | device list, Wake-on-LAN |
| `brctl` | ✅ | `/usr/sbin/brctl` | + `/sbin/bridge` (iproute2) | LAN bridge introspection |
| `ethtool` / `iw` | ✅ | `/usr/sbin/ethtool`, `/usr/sbin/iw`, `iwconfig`, `iwlist`, `iwpriv` | | link quality, WiFi |
| curl | ✅ | `/usr/bin/curl` **7.69.1** `(arm-oe-linux-gnueabi) libcurl/7.69.1 OpenSSL/1.1.1s zlib/1.2.11 libidn2/2.3.0 nghttp2/1.40.0` | **has HTTP/2, TLS 1.3, idn** — everything an API client needs | DDNS, speedtest (shipped), webhook/notify, cloud APIs |
| wget | ✅ | `/usr/bin/wget` (busybox) | | simple downloads |
| openssl | ✅ | `/usr/bin/openssl` **1.1.1s 1 Nov 2022**; `s_client`, `s_server`, `req`, `x509`, `pkcs12`, `dgst`, `rand` all present | the only crypto toolkit | cert generation for the UI, TLS probing, HMAC/hash |
| jq | ✅ | **`/data/qmanager/bin/jq`** (1324676 B), verified `{"a":1} \| jq -r .a` → `1` | not in `/usr/bin`; comes with our own payload. Prior notes saying "no jq" are wrong *when `PATH` includes `$QM_ROOT/bin`* | every JSON CGI in QManager already relies on it |
| uuidgen | ❌ | MISSING | substitutes verified: `cat /proc/sys/kernel/random/uuid` → `7893e4c0-…`; `openssl rand -hex 8` | any feature needing IDs |
| base64 / sha256sum | ✅ | busybox applets (both verified) | | payload encoding, integrity checks |
| snmpd | ⚠️ | `/bin/snmpd` **NET-SNMP 5.9.1** (74488 B) | not running, no `/etc/snmp/` | **SNMP monitoring** — an enterprise checkbox for free |
| miniupnpd (UPnP IGD) | ⚠️ | `/usr/sbin/miniupnpd` **miniupnpd 2.2.3 Aug 16 2022**, `using netfilter(iptables) backend`; config `/etc/data/miniupnpd/miniupnpd.conf` (stock, `ext_ifname` commented out) | not running; `start_miniupnpd` initscript exists and is unwired | **UPnP/NAT-PMP port mapping** — console/app auto-forwarding, free |
| DDNS clients | ⚠️ | `/usr/sbin/ddclient` (perl script, needs the perl we have); `/etc/data/ddclient.conf` is the **stock upstream sample** | not running, zero config. `inadyn`/`ez-ipupdate` absent. | **Dynamic DNS** (duckdns/no-ip/Cloudflare) — free |
| ftpd | ⚠️ | `/usr/sbin/ftpd` (busybox) | not running | USB file share |
| tftpd | ⚠️ | `/usr/sbin/tftpd`, `/sbin/tftp_server` (busybox) | not running | config/firmware provisioning |
| radvd (IPv6 RA) | ⚠️ | `/sbin/radvd` (392968 B), `radvdump`, `/etc/initscripts/rdisc` | not running | IPv6 LAN |
| siproxd (SIP ALG) | ⚠️ | `/usr/sbin/siproxd` (1152420 B) | not running | **VoIP behind NAT** — directly relevant to `router-fix/voip-bridge` |
| pimd / multicast | ⚠️ | `/usr/sbin/pimd` + `/etc/pimd.conf` (5108 B) | not running | IPTV/multicast |
| telnetd | ⚠️ | `busybox telnetd -l /bin/sh` on `:::23` | **running, unauthenticated root shell**. Not a capability, a liability. | — (close it) |
| dropbear | ✅ | `dropbear` on `:22` (both `:::22` and `0.0.0.0:22`) | no sftp-server → no `scp -O`… use `ssh 'cat >'` | — |

### 1.5 Kernel / platform

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| Kernel | ✅ | `Linux sdxlemur 5.4.210-perf #7 PREEMPT Fri Jan 5 14:02:11 CST 2024 armv7l GNU/Linux`; built by `clang version 10.0.1`, `GNU ld 2.34.0` | confirms the 5.4.210 in `AGENTS.md` (previously **[I]** — now **[V]**) | — |
| SoC | ✅ | `/proc/cpuinfo`: `ARMv7 Processor rev 5 (v7l)`, `CPU part 0xc07`, `Features: half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt vfpd32 lpae evtstrm`, `BogoMIPS 38.40` | `0xc07` = **Cortex-A7**, 1 core (`nproc` → 1) | — |
| Loadable modules | ❌ | `/lib/modules/5.4.210-perf/` has `modules.builtin` (**577** entries), `modules.alias/dep/order/symbols`, `build`, `source`, `kernel/`, `extra/` — but `find -name '*.ko*' \| wc -l` → **0** | `modprobe`/`insmod` binaries exist and are useless. **Hard wall.** | nothing that needs an unbuilt-in module |
| Builtin: netfilter | ✅ | `nf_conntrack.ko`, `nf_nat.ko`, `iptable_nat.ko`, `xt_MASQUERADE.ko`, `xt_REDIRECT.ko`, `xt_TPROXY.ko`, `xt_TCPMSS.ko`, `ip6table_nat.ko` | see §1.1 | — |
| Builtin: net drivers | ✅ | `gre.ko`, `ip_gre.ko`, `vxlan.ko`, `tun.ko`, `sit.ko`, `ipip.ko`, `l2tp.ko`, `ppp_generic.ko`, `bridge.ko`, `dummy.ko`, `ebtables.ko` | see §1.3 | — |
| Builtin: qdiscs | ✅ | `sch_htb.ko`, `sch_cake.ko` | live `fq_codel` already default on `rmnet_data0` | QoS |
| Not builtin | ❌ | `wireguard`, `nf_tables`, `veth`, `ifb`, `macvlan`, `bonding`, `tap` → 0 hits in `modules.builtin` | **containers, WireGuard, nftables are all permanently out** | — |
| RAM | ✅ | `MemTotal: 661264 kB` (645 MB), `MemFree: 67260 kB`, `MemAvailable: 479420 kB` | RAM headroom is **not** the constraint | several more daemons fit |
| Swap | ✅ | `/dev/zram0` partition **330628 kB**, 0 used, `zram-setup` initscript | compressed swap, available | a burst-tolerant daemon is safe |
| CPU | ⚠️ | 1 core; observed `load average: 9.09, 7.06, 4.44` | **the** constraint. A poller on a 1 s tick is a measurable regression on this box | every design must be event-driven or low-cadence |
| cgroups | ⚠️ | v1: `cpu`, `cpuacct`, `freezer`, `net_cls`, `net_prio`, `debug`, `systemd`. cgroup2 **hybrid** at `/sys/fs/cgroup/unified` with **no controllers** (`cgroup.controllers` absent) | usable for `net_cls` tagging and freezer; v2 resource control unavailable | per-feature CPU ceiling, `net_cls` QoS classification |
| Namespaces | ⚠️ | `/proc/self/ns/` shows `cgroup`, `ipc`, `mnt`, `net` only; **no `pid`, `user`, `uts`, or `time`**; `unshare` binary MISSING | **containers are not realistically possible** (no PID NS, no `veth`, no cgroup2 controllers) | — |
| Writable `/` | ❌ | `ubi0:rootfs on / type ubifs (ro,…,assert=read-only,ubi=0,vol=0)` | confirmed; 76% full (44948 K free, read-only anyway) | — |
| Writable persistent volumes | ✅ | `/etc`, `/data`, `/persist`, `/userdata` **all = `/dev/ubi2_0`** (`ubi2_0 … (rw,…,ubi=2,vol=0)`), 177692 K / 98244 used → **79448 K free**; `/cache` = `ubi2_1` 304084 K, **298968 K free** (almost empty) | confirms the `AGENTS.md` claim, and adds: **`/cache` is a second, nearly empty 298 MB writable volume** | large payloads, logs, DBs, downloaded firmware images |
| `/systemrw` | ✅ | `ubi0:systemrw on /systemrw type ubifs (rw,…,ubi=0,vol=2)` — **2328 K total, 32 K used, 2108 K free** | a *tiny writable* slice on the otherwise read-only rootfs volume. Small enough to be interesting, too small for a payload. | a boot-critical 2 KB script that must exist before `/etc` mounts |
| tmpfs | ✅ | `/tmp`, `/run`, `/var/volatile`, `/var/lib` all tmpfs (330632 K), `devtmpfs /dev` (317832 K) | **`/var/lib` is tmpfs** — crond's default spool is ephemeral | — |
| `/firmware` | ⚠️ | `ubi1_0` **99% full** (1052 K free), ro | do not plan around it | — |
| ip_forward | ✅ | `net.ipv4.ip_forward = 1`, `net.ipv4.conf.all.forwarding = 1` | already a router | — |
| sysctl tunables | ✅ | `/etc/sysctl.conf` bumping `rmem/wmem_max` to 1 MB, `perf_event_paranoid=0` | writable tunables | TCP tuning features |
| No compiler | ❌ | `gcc`, `cc`, `make`, `git` all MISSING | **any new native binary must be cross-compiled off-box** | — |

### 1.6 Web server / backend language (what a new feature can be written in)

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| `:80` + `:443` (vendor UI) | ✅ | `/bin/mini_httpd` (**ACME mini_httpd**, 54620 B), two instances: `mini_httpd -C /tmp/mini_httpd.conf` and `mini_httpd -C /tmp/mini_httpsd.conf`. Config: `user=root dir=/tzwww cgipat=cgi-bin/* charset=UTF-8`; HTTPS adds `ssl certfile=/bin/mini_httpd.pem` | **not** goahead, **not** lighttpd, **not** busybox. Vendor CGI `/tzwww/cgi-bin/http.cgi` is a **native ELF binary** | — (leave alone) |
| `:8080` (our UI) | ✅ | `busybox httpd -p 8080 -h /data/qmanager/www` (PID 2375), **BusyBox v1.31.1 (2022-08-09)** | `qm_serve.sh` sets `PORT=8080`, `DOCROOT=$QM_ROOT/www`, runs as root deliberately (CGIs need `/bin/atcmd`), pidfile `/run/qmanager-httpd.pid`; comment states "busybox 1.31 httpd supports CGI natively and is already on the device, so no packages are installed" | — |
| busybox httpd CGI | ✅ | 308 applets; `httpd` supports CGI, `-c CONFFILE`, `-u USER[:GRP]`, `-r REALM` (digest auth) | the existing CGI tree (`/data/qmanager/www/cgi-bin/quecmanager/`: `at_cmd auth bands cellular device frequency monitoring network operator-list.json profiles public scenarios settings system tower vpn`) is **all `sh`**, executed via shebang | any new CGI — and `-u/-r` gives digest auth if needed |
| lighttpd | ⚠️ | `/usr/sbin/lighttpd` **lighttpd/1.4.55 (ssl)** + `lighttpd-angel` + `start lighttpd` initscript | **installed, not running** — free win if busybox httpd's concurrency is a limit | keep-alive / many-client UI, CGI under load |
| Python | ❌ | `python`, `python3` MISSING | | — |
| Perl | ✅ | `/usr/bin/perl` **5.30.1** `built for arm-linux`; `perl -e` verified | `ddclient` at `/usr/sbin/ddclient` is itself a perl script | **real backend language**: JSON, sockets, regex, CGI |
| Lua | ✅ | `/usr/bin/lua` **5.2.2** (136632 B); verified `lua -` executes a script | note dnsmasq is `no-Lua`, so Lua cannot extend dnsmasq — only standalone | embedded logic, small CGI, config templating |
| Ruby / PHP / Node | ❌ | all MISSING | | — |
| PATH for CGI | ⚠️ | `qm_serve.sh` does `PATH="$QM_ROOT/bin:/usr/sbin:/usr/bin:/sbin:/bin"` — **`$QM_ROOT/bin` first** | this is why `jq` and the AT helpers resolve inside CGIs but not in an interactive shell | any CGI needing `jq`/`atcmd` |

### 1.7 `/bin/atcmd` and AT concurrency

| Capability | avail? | exact binary / module / path + version | notes | which candidate feature it unlocks |
|---|---|---|---|---|
| `atcmd` | ✅ | `/bin/atcmd` (9732 B, `Jan 5 2024`, mode `rwxrwxr-x system:system`) | invoked with **no args → exit 0** (no usage text). It is a thin **socket client**: `strings` shows `/tmp/.tmpsock`, `/tmp/.tmpsock/atcmd`, `/tmp/.sockmsg/atcmd_daemon`. There is **no `flock` inside it** — serialisation is the caller's job. | every modem feature |
| `atcmd_daemon` | ✅ | `/etc/initscripts/start_atcmd_daemon`, `start_atfwd_daemon`, `start_diag_socket` | the daemon owns the socket; `atfwd` is the vendor AT-forwarding path | — |
| QManager AT gatekeeper | ✅ | `/data/qmanager/bin/qcmd` (**shell**) — the documented *single* entry point | `LOCK_FILE="/tmp/qmanager_at.lock"`, `flock`-based, `LOCK_WAIT_SHORT=20` / `LOCK_WAIT_LONG=45`; calls `/data/qmanager/bin/atcli_smd11`, which talks **`/dev/smd11` directly** (bypasses socat entirely) | — |
| Does it lock against `/bin/dialer`? | ⚠️ | **No.** `flock` serialises *our* callers against each other only. `atcli_smd11` writes `/dev/smd11` with no coordination with `/bin/dialer` or `atcmd_daemon`. | The observed consequence is exactly what `qcmd`'s own comment describes: "the port sometimes drops a command, and the shim re-sends it", which is why the lock waits were raised to 20/45 s. **Treat any new AT caller as a rival to the dialer, not a peer of `qcmd`.** | AT-heavy features must go through `qcmd`, never `atcmd` directly |
| `flock` | ✅ | `/usr/bin/flock` (busybox) | the primitive is available for any new mutex | guard scripts |
| `timeout`, `setsid`, `nohup` | ✅ | all busybox, all present | needed for the detached-from-`start_cfgd` boot pattern | boot hooks |
| Live AT locks observed | ✅ | `/tmp/qmanager_at.lock`, `/tmp/qmanager_schedule_arm.lock`, `/tmp/qmanager_speedtest.lock` | corroborates the lock file in use | — |

---

## 2. Hard walls (do not plan around these)

| Wall | Evidence | Consequence |
|---|---|---|
| **No loadable kernel modules** | `find /lib/modules -name '*.ko*' \| wc -l` → `0`; 577 builtin | Anything needing `wireguard`, `nf_tables`, `veth`, `ifb`, `macvlan`, `bonding` is **impossible** without a kernel reflash |
| **No nftables** | `nft` MISSING; `nf_tables.ko` not builtin | All firewall work is `iptables` **legacy** only |
| **No compiler** | `gcc`/`cc`/`make`/`git` MISSING | Any new native binary is cross-compiled off-box and shipped as payload |
| **1 core, already at load ~9** | `nproc` → 1; `load average: 9.09, 7.06, 4.44` | No second-by-second pollers. `qmanager-guard`'s 1-minute cadence is the right template, not a 5 s one |
| **`/` is read-only ubifs** | `ubi0:rootfs on / type ubifs (ro,…,assert=read-only)` | Nothing boot-critical in `/`; `/etc` + `/data` only |
| **`/etc/systemd/system` mounts late** | `/dev/ubi2_0` mounted at `/etc`; `AGENTS.md` §4 | Units placed there **do not start on boot** — proven again by Tailscale: unit enabled in `multi-user.target.wants`, daemon not running |
| **No containers** | `/proc/self/ns/` lacks `pid`/`user`/`uts`; no `unshare`; no `veth`; cgroup2 has no controllers | Docker/LXC/podman are out |
| **`/firmware` 99% full** | `76488` K total, `1052` K avail, `ro` | No room for anything there |

---

## 3. Feature cost model (the point of the matrix)

| Cost tier | Meaning | Supported by |
|---|---|---|
| **Cheap (shell only, no new binary)** | the binaries are already on the box, wired or nearly wired | port forwarding/DNAT UI; per-client firewall; DHCP reservations (`dhcp-hostsfile` is already `/etc/data/dhcp_hosts`); per-device bandwidth caps (`tc` + `sch_cake`/`sch_htb`); client list from `conntrack`/`arp`; DNS diagnostics (`dig`/`host`); per-client blocking (`ipset` compiled into dnsmasq); TTL normalisation (shipped); DoS rate limits (`hashlimit`/`connlimit` are present) |
| **Cheap-to-medium (one wiring fix)** | binary complete, only a boot hook or a config file missing | **UPnP/NAT-PMP** (`miniupnpd 2.2.3` + existing `start_miniupnpd`); **DDNS** (`ddclient` + perl, config is a stock sample); **SNMP** (`net-snmp 5.9.1`); **cron** (busybox, just create `/etc/crontabs` and run `crond -c`); **IPv6 LAN** (`radvd` + dnsmasq DHCPv6 + ip6tables NAT libs) |
| **Medium (config + supervision, no new binary)** | installed, unconfigured, needs a supervisor | **IKEv2/IPsec VPN** (strongSwan 5.8.4, full plugin set, `/etc/ipsec.conf`→`/tmp` empty); **L2TP/IPsec client** (`xl2tpd 1.3.7` + `pppd 2.4.7`); **Tailscale** (v1.92.5 + `/dev/net/tun` + enabled unit, just never starts); **lighttpd** as a second web server |
| **Needs a cross-compiled payload binary** | genuinely absent | tcpdump; `nc`; OpenVPN; any C/C++ feature; a *different* dnsmasq (for DNSSEC) |
| **Impossible** | kernel says no | WireGuard (in-kernel); nftables; ifb/ingress shaping; veth-based containers; macvlan; bonding |

---

## 4. Free wins — present, working, and used by nobody

Ranked by feature-value ÷ effort. Each was verified as *installed* and *not running*.

1. **UPnP IGD — `miniupnpd 2.2.3`, `using netfilter(iptables) backend`.** Full config
   already at `/etc/data/miniupnpd/miniupnpd.conf` (6547 B), `ext_ifname` simply
   commented out, and `/etc/initscripts/start_miniupnpd` already exists and is unwired.
   Console/app auto port-forwarding for ~1 hour of work. **Highest ratio on the box.**
2. **Tailscale — v1.92.5, both binaries present, `/dev/net/tun` present, unit installed
   *and enabled*.** Fails only because `/etc/systemd/system` is invisible at boot —
   the exact bug `deploy-x16` already has a fix pattern for. Remote-access feature,
   already has its own QManager page (`vpn/tailscale.sh`) waiting for it.
3. **strongSwan IKEv2 — U5.8.4 with `charon`, `starter`, `stroke`, `vici`, `xfrmi` and
   the complete plugin set** (kernel-netlink, aes, gmp, openssl, curl, pem, x509, attr,
   dnskey). `/etc/ipsec.conf` and `/etc/strongswan.conf` are symlinks into `/tmp` where
   the files do not exist. Nothing is missing but the config and the supervisor.
4. **L2TP/IPsec — `xl2tpd 1.3.7` + `pppd 2.4.7` + `l2tp.ko` builtin.** `start_l2tp`
   exists; `/etc/data/l2tp_cfg.xml` is an empty `<l2tpcfg/>`.
5. **DDNS — `ddclient` + perl 5.30.1.** `/etc/data/ddclient.conf` is the *unmodified
   upstream sample*, i.e. the vendor shipped the file and never configured it.
6. **SNMP — `net-snmp 5.9.1`.** Enterprise checkbox, zero code.
7. **cron — busybox `crond`/`crontab` are installed but the spool directory was never
   created** (`/var/spool/cron/crontabs` does not exist). `crond -c /etc/crontabs`
   gives persistent scheduling on a box that currently has none.
8. **`iptables` itself.** The single biggest "free win" is the realisation in §0: the
   whole NAT/firewall surface is live and healthy. Everything in §1.1 is available
   today.
9. **`/cache` — a second writable volume, 298 MB free (ubi2_1), currently 276 K used.**
   Large artefacts (logs, DB, firmware images, speedtest results) belong here, not in
   `/data`'s 79 MB.
10. **`perl` and `lua`.** Both work. "Shell only" was an untested assumption.
11. **`siproxd` (1.15 MB) — a SIP ALG/proxy** sitting unused on a device that already
    ships a VoIP bridge. Worth a look before writing any SIP NAT traversal by hand.
12. **`lighttpd 1.4.55 (ssl)`** installed and unused — a drop-in if busybox httpd's
    single-threaded CGI ever becomes the ceiling.

## 5. Liabilities found, not capabilities (flag, don't ship)

- **`busybox telnetd -l /bin/sh` is listening on `:::23` with no authentication** —
  root shell for anyone on the LAN.
- `mangle POSTROUTING … TTL set to 65` and the SmartDNS block are **ours**; do not
  mistake them for vendor behaviour when reading `iptables-save`.
- `-A PREROUTING -i bridge0 -p tcp --dports 80,443 … -j REDIRECT --to-ports 989` is the
  vendor sending **all LAN HTTP/HTTPS into `tpws`** (Tor transproxy) on `:989`
  (833 packets matched). Undocumented, undesired, and worth a decision on.
- `iptables` INPUT `DROP`s on `rmnet_data0` for `tcp/22`, `tcp/80`, `tcp/443` and
  `icmp echo` — so WAN-side SSH/HTTP/ICMP is closed by the vendor *in addition* to
  anything the carrier does.

---

## 6. Reproduce / method

```sh
# every call wrapped; the link drops
cat > /tmp/z16probe/rsh.sh <<'EOF'
#!/bin/bash
S=$(cat); for i in $(seq 1 ${ZLT_TRIES:-8}); do
  OUT=$(ssh -o ConnectTimeout=12 -o ServerAliveInterval=5 zlt-root "sh -s" <<<"$S" 2>/dev/null)
  [ $? -eq 0 ] && { echo "$OUT"; exit 0; }; sleep 3
done; echo SSH_FAILED
EOF

# the PATH trap — /usr/sbin and /sbin are NOT in a dropbear root login's PATH
echo 'export PATH=/usr/sbin:/sbin:/usr/bin:/bin
      iptables -V; ip -V; tc -V; dnsmasq --version; ipsec version' | /tmp/z16probe/rsh.sh
```

Read-only throughout: no file was created, modified, or deleted on the device; no
`iptables` rule was added; `tc qdisc add` was attempted only on `lo` (rejected by the
kernel with `Exclusivity flag on, cannot modify`, no state change).
