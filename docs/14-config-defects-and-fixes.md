# 05 — Concrete Defects Found, with Fixes

Each item below was verified on the live device. Severity is judged by what it
can actually break, not by how interesting it is.

---

## 1. Jazz prepaid APN is misspelled in the firmware  — severity: HIGH

**File:** `/system/cusetc/apns-conf_8.xml`, around line 5703

```xml
<!-- Pakistan Mobilink -->
<apn carrier="jazz internet postpaid" mcc="410" mnc="01"
     apn="connect.mobilinkworld.com" />
<apn carrier="jazz internet prepaid"  mcc="410" mnc="01"
     apn="jazzconnect.mobilinkword.com" />   <!-- MISSING THE "L" -->
```

Jazz's own published APN settings:

| Jazz APN | Plan |
|---|---|
| `connect.mobilinkworld.com` | postpaid |
| `jazzconnect.mobilinkworld.com` | prepaid |

The firmware has `mobilinkword`. This is the APN the router auto-selects for a
Jazz prepaid SIM — and the customer's Jazz SIM used it 84 times
(`/data/logs_backup/DIALER.log`).

**Why it is only "HIGH" and not "root cause":** the manual, correctly-spelled
`connect.mobilinkworld.com` also churned (38 connects / 28 disconnects), so the
typo is not the whole story. But it is unambiguously wrong and must be corrected
before any other Jazz test is meaningful.

**Fix (immediate, no root needed):** set the APN manually in the web UI to
`jazzconnect.mobilinkworld.com` instead of relying on auto-detect.

**Fix (proper):** `/system` is on the read-only rootfs, so patch a copy and
bind-mount it:

```sh
mkdir -p /data/tzcfg
cp /system/cusetc/apns-conf_8.xml /data/tzcfg/apns-conf_8.xml
sed -i 's/jazzconnect\.mobilinkword\.com/jazzconnect.mobilinkworld.com/' \
    /data/tzcfg/apns-conf_8.xml
mount --bind /data/tzcfg/apns-conf_8.xml /system/cusetc/apns-conf_8.xml
```

…and add the `mount --bind` line to `/etc/rc.local` so it survives reboot.
**This has not been applied** — it was deliberately left as a decision for you,
since changing the shipped APN database is a firmware-level modification.

---

## 2. `ack-flood` rejects >10 connections to ports 80/443 per source IP — severity: MEDIUM
> **Correction (2026-10-26, after auditing `ddos.sh`):** this rule is in the
> **INPUT** chain, so it only affects connections **to the router itself**
> (i.e. its own admin UI), **not** forwarded LAN→internet traffic. A speedtest
> goes through `FORWARD` and is unaffected. It is therefore **not** a candidate
> cause for the speedtest symptom — only for being locked out of the admin page.
> See [16-initscript-and-firewall-audit.md](16-initscript-and-firewall-audit.md).
>
> The rule source is `/etc/initscripts/ddos.sh:28-30`, gated by
> `USR_DDOS_FUNC_SW` (currently `1`). The `80` in the rule comes from
> `USR_WEB_LOGIN_FROM_WAN_PORT=80`.

```
-A INPUT -p tcp -m multiport --dports 80,443 -m tcp --tcp-flags ALL ACK -j ack-flood
-A ack-flood -m connlimit --connlimit-above 10 --connlimit-mask 32 \
            --connlimit-saddr -j REJECT --reject-with icmp-port-unreachable
```

Live counters showed this rule **had already fired** (4 packets rejected) shortly
after boot. A multi-stream speedtest plus ordinary browsing from one PC can
easily exceed 10 concurrent 80/443 connections from a single IP.

This is a plausible direct explanation for "the speedtest kills the internet":
new connections get `icmp-port-unreachable` while the WAN is perfectly healthy.

**Test:**

```sh
# temporarily raise the limit and re-run the speedtest
iptables -R INPUT 5 -p tcp -m multiport --dports 80,443 \
    -m tcp --tcp-flags FIN,SYN,RST,ACK ACK \
    -m connlimit --connlimit-above 100 --connlimit-mask 32 \
    --connlimit-saddr -j REJECT --reject-with icmp-port-unreachable
```

(`iptables -R INPUT <n>` — check the current index with
`iptables -L INPUT -n --line-numbers` first, it moved to position 5 after our
SSH rule was inserted.) Or simply drop the rule for the duration of the test:

```sh
iptables -D ack-flood 1    # restore by re-adding, or reboot
```

Not applied — it weakens a DoS guard, so it should be an informed choice.

---

## 3. `zlt-wan-fix.service` is enabled but never runs — severity: LOW (it is also redundant)

```sh
$ systemctl is-active  zlt-wan-fix.service   -> inactive
$ systemctl is-enabled zlt-wan-fix.service   -> enabled
```

It has `Requires=TZApp.service` plus `After=TZApp.service`, and `TZApp.service`
ends in state *exited*; the ordering/requirement combination means the unit is
never pulled into the boot transaction. Consequently:

```
tcp_mtu_probing = 0        (the script would set 1)
iptables -t mangle = empty (the script would add TCPMSS rules)
```

**However — the MSS problem it was written to solve is already solved by the
firmware.** The `filter` table clamps to PMTU:

```
Chain forward_mdl_chain (1 references)
 pkts bytes target  prot opt in out source    destination
 7573  454K TCPMSS  tcp  --  *  *   0.0.0.0/0 0.0.0.0/0
                    tcp flags:0x06/0x02 TCPMSS clamp to PMTU
```

7573 SYN packets matched, i.e. it is actively working. With WAN MTU 1400 the
PMTU is 1400 so the clamp yields **MSS 1360**, which is correct.

**Conclusion: `DIAGNOSIS.md`'s "no TCPMSS clamp in the mangle table" is true but
misleading** — the clamp exists in the `filter` table and is doing its job. The
MTU/MSS hypothesis should be treated as *closed*, and adding a second clamp in
`mangle` would be redundant at best and conflicting at worst.

If you still want `tcp_mtu_probing=1` (the GreenPacket has it), set it directly:

```sh
echo 1 > /proc/sys/net/ipv4/tcp_mtu_probing
```

or fix the unit by replacing `Requires=` with `Wants=` and adding
`Type=oneshot` + `RemainAfterExit=yes`.

---

## 4. Factory vendor SSH key baked into the image — MEDIUM (security) — FIXED

`/home/root/.ssh/authorized_keys` shipped from the factory containing a single
key belonging to a vendor/SDK engineer:

```
ssh-rsa AAAA... linweiqiang@server
```

**Resolved 2026-10-26.** Removed from every authorized_keys location on the box:

| File | Before | After |
|---|---|---|
| `/data/root/.ssh/authorized_keys` (root's actual home) | 7 keys | **6 keys** |
| `/data/zlt/.ssh/authorized_keys` | 7 keys | **6 keys** |
| `/data/root-ssh/authorized_keys` (bind-mounted over `/home/root/.ssh`) | 7 keys | **6 keys** |
| `/home/root/.ssh/authorized_keys` (via the bind mount) | 7 keys | **6 keys** |

The removed key material is preserved for audit and reversibility at:

```
/data/zlt-backups/2026-10-26/removed-keys/
  vendor-home-root-authorized_keys.orig
  _data_root_.ssh_authorized_keys.with-vendor-key
  _data_zlt_.ssh_authorized_keys.with-vendor-key
  _data_root-ssh_authorized_keys.with-vendor-key
```

Remaining keys are all the customer's. Verify:

```sh
ssh zlt-x16 'awk "{print \$NF}" /data/root/.ssh/authorized_keys'
```

Expected: `emumba-mac-x28`, `rafay@rafay`, `rafay.awan@emumba.com`,
`rawan@extremenetworks.com`, `shop@M1-2.local` x2.

> This only removes the *key* from **this** unit. Whoever holds the matching
> private key can still log in wherever that key is trusted. Also note the key
> was identical on every unit of this model — it is a fleet-wide factory
> credential, not a per-device one.

## 5. Telnet on port 23 is an unauthenticated root shell — severity: HIGH (security)

The running `busybox telnetd -l /bin/sh` has **no password prompt at all**. It
came from a saved web-UI debug toggle, not from the vendor's gated telnet path
(`SYS_TELNET_SWITCH=0`).

**Fix:** see doc 10 §"Disabling telnet".

---

## 6. TTL is not normalised on WAN egress — severity: MEDIUM (testable)

GreenPacket sets `iptables -t mangle -A POSTROUTING -o rmnet_data+ -j TTL --ttl-set 65`;
the ZLT sets nothing, so tethered traffic leaves with TTL 63 and router traffic
with 64 — a hotspot signature some mobile operators act on.

**Test (fully reversible):**

```sh
iptables -t mangle -A POSTROUTING -o rmnet_data0 -j TTL --ttl-set 65
# undo
iptables -t mangle -D POSTROUTING -o rmnet_data0 -j TTL --ttl-set 65
```

Requires `xt_TTL` to be present; the kernel has the `TTL` target available if the
GreenPacket on the same kernel can use it.

---

## 7. Unusual TCP buffer minimums — severity: LOW

```
tcp_rmem = 524288 2097152 4194304
tcp_wmem = 524288 2097152 4194304
```

The **minimum** is 512 KB per socket, versus 4 KB on the GreenPacket. On a 645 MB
device this is an odd tuning and reserves a lot of memory per connection.

**Revert toward the kernel default:**

```sh
echo "4096 87380 4194304" > /proc/sys/net/ipv4/tcp_rmem
echo "4096 16384 4194304" > /proc/sys/net/ipv4/tcp_wmem
```

Not applied — no evidence it causes the disconnect, but it is out of line with
the working device.

---

## 8. Broker / dialer recovery is up to 60 s slow — severity: MEDIUM

Established in `DIAGNOSIS.md` by reverse-engineering `/bin/dialer`: the one-second
handler only invokes the PDP-state and WAN-address watchdogs roughly every 60
seconds. Observed recovery times after a teardown ranged from ~6 s to ~59 s.

This does not cause the disconnect, but it is what turns a network blip into
"my internet disappeared". A faster watchdog would be a meaningful quality
improvement, and it is the one fix that helps regardless of the root cause.

---

## 10. `zlt-ssh-watchdog.timer` has never fired — severity: MEDIUM (access)

Measured 2026-10-28, after the unit rebooted on its own:

```
$ systemctl is-active  zlt-ssh-watchdog.timer   -> inactive
$ systemctl is-enabled zlt-ssh-watchdog.timer   -> enabled
$ systemctl show -p LastTriggerUSec -p NextElapseUSecRealtime zlt-ssh-watchdog.timer
LastTriggerUSec=                 <- empty: it has never run
NextElapseUSecRealtime=          <- empty: nothing armed
$ systemctl show -p ExecMainStartTimestamp zlt-ssh-watchdog.service
ExecMainStartTimestamp=          <- the service has never run this boot
```

`systemctl list-timers --all` lists it as `n/a n/a n/a`.

**Root cause is the documented boot-ordering bug** (§4 of AGENTS.md): its enable
symlink lives in `/etc/systemd/system/timers.target.wants/`, which is invisible
for the boot in which `/etc` is not yet mounted. `qmanager-guard.timer` and
`zlt-smartdns.timer` are alive only because a hook starts them explicitly.

So *"enabled"* and *"running"* are independent facts on this firmware, and this
unit is a live instance of the difference: `docs/11` previously recorded this
timer as `active`, which was wrong.

Not yet fixed. The fix is the one this repo already uses twice — start the timer
from a hook that runs out of the mounted `/etc` (`StartTZApp` / `start_qmanager`)
and re-assert it from a guard. Deliberately not applied here: it changes the SSH
access path, and `router-fix/start_ssh` is already invoked from `StartTZApp`, so
the marginal value needs measuring before adding another supervisor.

---

## 11. QCMAP backhaul order puts WWAN last, with autoconnect off — severity: MEDIUM

`/etc/data/mobileap_cfg.xml`, measured 2026-10-28:

```xml
<FirstPreferredBackhaul>bt-pan</FirstPreferredBackhaul>
<SecondPreferredBackhaul>eth</SecondPreferredBackhaul>
<ThirdPreferredBackhaul>usb_cradle</ThirdPreferredBackhaul>
<FourthPreferredBackhaul>wlan</FourthPreferredBackhaul>
<FifthPreferredBackhaul>wwan</FifthPreferredBackhaul>
<AutoConnect>0</AutoConnect>
```

The cellular WAN — the only backhaul that exists on this installation — is the
**lowest** priority, and autoconnect is off, so QCMAP never brings the WAN up
itself; the vendor dialer does. The working GreenPacket O5A on the same SIM uses
QCMAP as the exclusive WAN owner with WWAN first and autoconnect enabled
(doc 13).

`DIAGNOSIS.md` recommended this change; it was never applied and was not
recorded here, which is why it kept looking like an unexplored idea.

Deliberately not changed: per AGENTS.md §5.4, QCMAP owns the PDP data path, so
re-ordering backhauls and turning autoconnect on can drop the WAN and changes who
reconnects after a teardown. It needs a maintenance window and a rollback of
`mobileap_cfg.xml`, not a drive-by edit.

---

## Note: `mdlcfg` takes `-g`, not `-r`

`DIAGNOSIS.md` lists "safe authoritative values read through `mdlcfg`" without
the flag. `mdlcfg -r <KEY>` prints **nothing and exits 0** — a silent failure;
the correct getter is `mdlcfg -g <KEY>` (and `mdlcfg -e` exports everything).
While checking this, the applied band masks were confirmed to agree with NV:

```
mdlcfg -g USR_LTE_LOCK_BAND_MASK = 12008000015  -> [1,3,5,28,38,41]   (matches NV lte_bandpref)
mdlcfg -g USR_NR_LOCK_BAND_MASK  = (tzcfg) 20000000018000000081 -> [1,8,40,41,78]
```

The *product default* in `/productinfo/tzcfg/main_config` is
`2A0000800D5` -> `[1,3,5,7,8,20,38,40,42]`, which **does** include B8. So B8 being
absent from the live policy is the result of the applied band lock, not a
firmware omission.

---

## Not defects (checked and cleared)

| Checked | Result |
|---|---|
| NAT/conntrack capacity | 45056 max, ~460 used — healthy |
| NAT rule set | single correct MASQUERADE rule |
| Internet-limit / quota | disabled, flow log empty |
| Memory / OOM | 499 MB available, no OOM in dmesg |
| Thermal | 39–45 °C, no mitigation active |
| IPA/QMAP error counters | all zero |
| MSS clamp on forwarded TCP | **vendor clamp works** — `filter forward_mdl_chain` → `TCPMSS --clamp-mss-to-pmtu`, 141 packets matched on 2026-10-28. `zlt-wan-fix`'s mangle rules are redundant (this is why §3 rates it LOW) |
| `tcp_mtu_probing` | 0 after a reboot; harmless — the vendor clamp already enforces the right MSS, so this is not the upload bottleneck it looks like |
| MBN selection | tested both available profiles; no improvement (`DIAGNOSIS.md`) |
| RSSI/signal | adequate, registration stable at `CEREG: 0,1` |
