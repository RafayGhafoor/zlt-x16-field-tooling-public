# ttl-normalise — stop tethered traffic advertising itself with TTL 63

Adds exactly one iptables rule to the X16:

```sh
iptables -t mangle -A POSTROUTING -o rmnet_data+ -j TTL --ttl-set 65
```

This is the rule the working **GreenPacket O5A on the same carrier** ships. The
X16 shipped nothing.

## Why

| Packet origin | TTL leaving the X16 | What the carrier sees |
|---|---|---|
| Router itself | 64 | normal |
| LAN client (tethering) | **63** (one hop decrement) | **hotspot signature** |

Anti-tethering enforcement on Pakistani mobile networks is documented behaviour,
and this is a concrete, testable config delta between the working GreenPacket
and the failing X16 — see `docs/13-greenpacket-comparison.md` ("TTL handling —
the standout difference") and `docs/14-config-defects-and-fixes.md` §6.

65, not 64, is deliberate: it reproduces the exact value the known-good device
uses on this carrier rather than inventing a new one.

`rmnet_data+` (not `rmnet_data0`) matches the GreenPacket and is the safe choice
on this box: the internet bearer's index is not stable across reconnects, and the
dialer has been observed tearing down `rmnet_data5` while `rmnet_data0` carried
data. Measured 2026-10-26: only `rmnet_data0` was up (MTU 1400); `rmnet_data1`–`5`
were `down`, so the wildcard costs nothing.

## What it does *not* do

No modem, dialer, MBN, `filter`/`nat` table or persistent vendor config is
touched. `remove` restores vendor behaviour exactly.

It is **not** an MTU/MSS fix — that was investigated and closed: the firmware
already clamps SYN MSS to PMTU in `filter/forward_mdl_chain`, and the dialer sets
`apn_mtu(1400)`. Leave `router-fix/zlt-wan-fix.sh` out of this; it is redundant.

## Deploy

```sh
./install.sh              # push, wire boot hook, apply, verify
./install.sh --check      # verify only, change nothing
./install.sh --uninstall  # remove rule + hook
```

Installs one file, `/etc/initscripts/zlt-ttlnorm`, which also owns the boot
wiring (`install-hook` / `remove-hook`) so that all sed/quoting logic runs on the
device rather than inside a nested ssh string.

`ZLT_HOST` (default `zlt-root`), `ZLT_TRIES`, `WAN_IF`, `TTL_SET` are honoured.

## Why the hook sits directly after `ddos.sh`

`/etc/initscripts/StartTZApp` line ~108 runs `ddos.sh`, which is the **last**
vendor step that builds the rule set at boot. The hook is inserted immediately
after it, so nothing in the boot sequence rebuilds the table underneath us.
(Busybox sed on this firmware has no GNU `\|` address delimiter, so the anchor is
a BRE with escaped slashes. The controller asserts the anchor is unique before
inserting, strips any previous block first, and rolls back from
`/data/zlt-backups/<date>/ttl-normalise/StartTZApp.orig` if `sh -n` fails.)

### Why there is no guard timer

A 1-minute re-assert timer was built, then deliberately removed. Measurement:
the vendor's `/etc/tzscript/iptables_config` only ever touches its own `tcprst`
chain in **`mangle FORWARD`**, and its whole-table flushes (`#iptables -F ...`)
are commented out — nothing flushes `mangle POSTROUTING` at runtime. This repo
only ships a guard when a measurement justifies it (compare the SmartDNS and
QManager guards). If a future firmware starts flushing mangle, `--check` reports
the rule absent.

## Verify

```sh
./install.sh --check
```

Real output after deployment on 2026-10-26:

```
controller:  present
boot hook:   present
hook markers:2
starttzapp:  syntax ok
rule:
  ttl-normalise: ACTIVE (-o rmnet_data+, --ttl-set 65)
    matched: 66117 packets, 76M bytes
    rmnet_data0: state=unknown mtu=1400
    rmnet_data1..5: down
```

The **counter is the proof**: a rule that exists but matches nothing normalises
nothing. Growth across two `--check` runs while LAN traffic flows is the check
that matters. (On 2026-10-26 the counter went 1041 → 2172 packets in 15 s.)

Limitation, stated honestly: `tcpdump` is not installed on this firmware, so the
rewritten TTL cannot be read off the wire from the device itself. The evidence is
(a) the rule is in `POSTROUTING`, i.e. immediately before egress, and (b) its
packet counter advances with real traffic. The `TTL` target itself is
deterministic.

## Roll back

```sh
./install.sh --uninstall
```

Deletes the rule and the hook block, removes `/etc/initscripts/zlt-ttlnorm`, and
leaves `/data/log/zlt-ttlnorm.log`. The pre-change boot script stays at
`/data/zlt-backups/<date>/ttl-normalise/StartTZApp.orig`.

## Status

- Deployed and verified live 2026-10-26 20:50 (rule active, counters advancing).
- **Reboot survival proven** 2026-10-26 21:25 — after a real reboot the hook ran from
  `StartTZApp` and wrote its own log entry:

  ```
  $ cat /data/log/zlt-ttlnorm.log
  1970-01-01 17:33:10 applied (-o rmnet_data+ --ttl-set 65)

  $ iptables -t mangle -L POSTROUTING -n -v | tail -1
  7440  4466K  TTL  all  --  *  rmnet_data+  0.0.0.0/0  0.0.0.0/0  TTL set to 65
  ```

  The `1970` timestamp is the unsynced clock at boot (the dialer's boot entries
  show the same); the counters had reset to zero and were climbing again, which
  proves this was a fresh boot and not a stale rule. `StartTZApp` syntax OK,
  WAN `10.140.40.97`, IPA `hw_tx` offload active, LAN client reachable.

See `docs/29-wan-drops-and-band-switching.md` for the drop-rate measurements
this fix is meant to move.
