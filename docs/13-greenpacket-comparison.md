# 04 — GreenPacket O5A Comparison

Compares the **failing** ZLT X16 (`192.168.3.1`) against the **working**
GreenPacket O5A (`192.168.0.1`, SSH on port 2222). Same SoC family, same
userspace ABI, different WAN architecture and different firmware generation.

Local sources for the GreenPacket:

- `/Users/emumba/Downloads/projects/greenpacket-o5a`
- `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager`

---

## Platform

| | ZLT X16 | GreenPacket O5A |
|---|---|---|
| Kernel | `5.4.210-perf #7` (Jan 2024) | `5.4.210-perf #1` (Apr 2024) |
| Userspace | `LE.UM.6.2.3.r1-06200-SDX65.0-1` | `LE.UM.6.2.3.r1-03100-SDX65.0` |
| Modem baseband | **`MPSS.DE.2.0`**-01026 | **`MPSS.DE.3.0`** (newer generation) |
| WAN owner | SIMCom/Sunsea `dialer` | QCMAP |
| SSH | added by us (doc 10) | `dropbear` on **port 2222**, factory |

The modem firmware generation is the most significant platform difference —
`DE.2.0` (2023) vs `DE.3.0`.

---

## WAN interface and MTU

| | ZLT X16 | GreenPacket O5A |
|---|---|---|
| WAN iface | `rmnet_data0` | `rmnet_data0` |
| **WAN MTU** | **1400** | **1500** |
| LAN MTU (`bridge0`) | 1500 | 1500 |
| `USR_APN_MTU` | 1400 | n/a |
| `USR_DHCP_MTU` | 1500 | n/a |

The X16 is a **cellular** WAN with a 1400-byte MTU. The GreenPacket's WAN is also
`rmnet_data0` but at 1500 — it is not subject to the same cellular MTU
constraint, so the two are *not* directly comparable on MTU. Any MTU-driven
failure on the X16 has no equivalent on the GreenPacket.

---

## NAT

**ZLT X16**

```
-A POSTROUTING -j postrouting_mdl_chain
-A POSTROUTING -j postrouting_dialer_chain
-A postrouting_mdl_chain -o rmnet_data0 -j MASQUERADE
-A postrouting_mdl_chain -s 192.168.3.0/24 -d 127.0.0.1/32
-A prerouting_mdl_chain  -d 10.220.84.156/32 -i rmnet_data0 -j DNAT --to-destination 127.0.0.1
-A prerouting_mdl_chain  -s 192.168.3.0/24 -d 10.220.84.156/32 -j DNAT --to-destination 127.0.0.1
NATType = SYM   (symmetric)
```

**GreenPacket O5A**

```
-A PREROUTING  -i bridge0 -p tcp -m multiport --dports 80,443 \
      -m addrtype ! --dst-type LOCAL -j REDIRECT --to-ports 989
-A POSTROUTING -o rmnet_data0 -j MASQUERADE --random
NATType = SYM   (symmetric)
```

Notes:

- Both are symmetric NAT, same timeout values in `mobileap_cfg.xml`
  (`NatEntryTCPEstablishedTimeout 3600`, `UDPTimeout 60`, `ICMPTimeout 30`,
  `GenericTimeout 200`).
- The GreenPacket adds **`--random`** to MASQUERADE; the X16 does not. Irrelevant
  at these connection counts.
- The GreenPacket transparently redirects 80/443 to a local proxy on port 989.
  The X16 does not.

### Conntrack capacity

| | ZLT X16 | GreenPacket O5A |
|---|---|---|
| `nf_conntrack_max` | **45056** | 12288 |
| `nf_conntrack_buckets` | 11264 | 3072 |
| observed `count` | ~460 (1 %) | ~730 (6 %) |

The failing router has **3.7× more** NAT table capacity than the working one.
This is a strong, simple argument against a "NAT table population" root cause.

---

## MSS / MTU clamping

**ZLT X16** — clamp lives in the `filter` table, not `mangle`:

```
-A forward_mdl_chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

With WAN MTU 1400 the PMTU is 1400, so this clamps to **MSS 1360** automatically —
which is the correct value. **The mangle table is completely empty** on the X16.

**GreenPacket O5A** — explicit, in `mangle`:

```
-A FORWARD -i bridge0    -o rmnet_data0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1460
-A FORWARD -i rmnet_data0 -o bridge0    -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1460
```

Both handle MSS; they just do it in different tables. **The X16 is already
correct here**, which is why the MTU theory in `DIAGNOSIS.md` should be
downgraded — see doc 14 §3.

---

## TTL handling — the standout difference

**GreenPacket O5A:**

```
-A POSTROUTING -o rmnet_data+ -j TTL --ttl-set 65
```

**ZLT X16:** nothing.

Consequence on the X16:

| Packet origin | TTL leaving the router | What the carrier sees |
|---|---|---|
| Router itself | 64 | normal |
| LAN client (tethering) | 63 (one hop decrement) | **hotspot signature** |

The GreenPacket deliberately normalises this so tethered traffic is
indistinguishable from router-originated traffic. This is a common anti-tethering
countermeasure on Pakistani mobile networks, and it is a concrete, testable
config delta between the working and failing device.

---

## TCP/IP stack tunables

| sysctl | ZLT X16 | GreenPacket O5A |
|---|---|---|
| `tcp_mtu_probing` | **0** | **1** |
| `tcp_rmem` | 524288 2097152 4194304 | 4096 32768 4194304 |
| `tcp_wmem` | 524288 2097152 4194304 | 4096 32768 4194304 |
| `tcp_synack_retries` | 3 | 5 |
| `tcp_fin_timeout` | 60 | 15 |
| `ip_forward` | 1 | 1 |
| `conf/all/rp_filter` | **2** (strict) | **0** (off) || `ip_local_port_range` | 32768–60999 | 32768–60999 |

Worth noting:

- `rp_filter`: `conf/all` is `2` (strict) while `conf/rmnet_data0` is `0`. Linux
  takes the **maximum** of the two, so the effective value on the WAN interface is
  still strict (2). The GreenPacket has it fully off. Strict reverse-path
  filtering combined with a cellular WAN that changes IP on every re-activation
  can silently drop return traffic after a bearer flap.
- The X16's `tcp_rmem`/`tcp_wmem` **minimum** values are 512 KB, versus 4 KB on
  the GreenPacket. That is an unusual, non-default tuning: every TCP socket on
  the X16 starts with a 512 KB buffer. On a 645 MB box that is a lot of
  unnecessary memory for a router and could contribute to the observed stalls.
- `tcp_mtu_probing=0` on the X16 is the only item the pre-existing
  `zlt-wan-fix.service` was meant to change — and it never ran (doc 14 §3).

---

## Firewall

**ZLT X16** — a large vendor chain set including an unconditional port-22 DROP:

```
-A INPUT -j parental_input_mdl_chain
-A INPUT -j input_mdl_chain
-A INPUT -p tcp --tcp-flags ALL SYN -j syn-flood
-A INPUT -p tcp -m multiport --dports 80,443 --tcp-flags ALL ACK -j ack-flood
-A INPUT -j nmap_scan
-A input_mdl_chain -i rmnet_data0 -p tcp --dport 22  -j DROP
-A input_mdl_chain -i rmnet_data0 -p tcp --dport 80  -j DROP
-A input_mdl_chain -i rmnet_data0 -p tcp --dport 443 -j DROP
-A input_mdl_chain -i rmnet_data0 -p icmp --icmp-type 8 -j DROP
-A nmap_scan -p tcp --dport 22    --tcp-flags ALL SYN -j DROP   <- blocks LAN SSH too
-A nmap_scan -p tcp --dport 53    --tcp-flags ALL SYN -j DROP
-A nmap_scan -p tcp --dport 5555  --tcp-flags ALL SYN -j DROP
-A syn-flood  -m limit --limit 12/sec --limit-burst 24 -j RETURN
-A ack-flood  -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT
```

**GreenPacket O5A** — far simpler; no port blocking beyond QCMAP's own policy.

The `ack-flood` rule is worth remembering during any speedtest: **more than 10
concurrent connections to ports 80/443 from a single source IP are REJECTed.**
This rule had already fired on the live device at the time of inspection:

```
Chain ack-flood (1 references)
 pkts bytes target  prot opt in out source      destination
    4  1586 REJECT  all  --  *  *   0.0.0.0/0   0.0.0.0/0  #conn src/32 > 10
```

A browser-based speedtest opens several parallel HTTP streams; a multi-stream
test plus normal browsing from one machine can plausibly cross 10 and get
rejected. That would look like "internet dies during speedtest" while ping and
DNS (other ports) still work. This deserves an explicit test and is one of the
cheapest things to try.

---

## APN configuration

| | ZLT X16 | GreenPacket O5A |
|---|---|---|
| APN source | `/system/cusetc/apns-conf_8.xml` (SHIP APN db) | `mobileap_cfg.xml` `<APN_NAME/>` (operator-set) |
| Jazz prepaid entry | **`jazzconnect.mobilinkword.com`** ← typo | n/a |
| Current APN | `Ufone.internet` (ONIC) | operator-provisioned |
| Apache/Carrier APN db | also `/etc/data/data_iot/carrier_apn_cfg` (Qualcomm, wone* APNs) | same file present |

The ZLT auto-selects an APN from a shipped database; the GreenPacket expects the
operator/ISP to supply one. That is why the ZLT hits the misspelled entry and the
GreenPacket never does.

---

## Summary of the actionable deltas

| # | Difference | ZLT X16 | GreenPacket | Why it matters |
|---|---|---|---|---|
| 1 | Jazz prepaid APN | misspelled `mobilinkword` | n/a | real defect, fix it |
| 2 | TTL on WAN egress | not normalised | `--ttl-set 65` | anti-tethering detection |
| 3 | `ack-flood` connlimit | 10 conns to 80/443 per IP | none | speedtest can trip it |
| 4 | `rp_filter` | 2 (strict) | 0 | return traffic after IP change |
| 5 | `tcp_mtu_probing` | 0 | 1 | PMTU discovery |
| 6 | `tcp_rmem/wmem` min | 512 KB | 4 KB | memory behaviour |
| 7 | Modem generation | `MPSS.DE.2.0` | `MPSS.DE.3.0` | old DSI/WDS stack |
| 8 | WAN MTU | 1400 | 1500 | not comparable (different WAN type) |
| 9 | Conntrack max | 45056 | 12288 | X16 has *more* headroom |

Items 2, 3, 4 and 5 are cheap, reversible experiments that can be run without a
firmware change.
