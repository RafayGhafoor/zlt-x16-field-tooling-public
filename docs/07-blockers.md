# 07 — Blockers & open questions

> **Update 2026-10-26 — Blocker 1 is RESOLVED.**
>
> Shell access to the X16 is now available:
>
> | Port | State |
> |---|---|
> | 23 (telnet) | **open**, unauthenticated root shell |
> | 22 (SSH) | **open**, dropbear, autostarts at boot, root password `<redacted-password>` |
> | 8080 | still free for QManager |
>
> The "reached through the upstream gateway `192.168.6.1`, we are on the WAN
> side" observation below is correct for the *web UI path we were using*, but the
> device is also directly reachable with a shell. See
> [`10-access-and-ssh.md`](10-access-and-ssh.md).
>
> Downstream items in this file that assumed "no shell" should be re-evaluated.



## Blocker 1 — no shell on the device (hard)

Live probe from this Mac:

| Port | Result |
|---|---|
| 80 | **open** — vendor UI answers `HTTP/1.1 200 Ok`, `simcom_war/index.html`, Last-Modified 2024-01-05 |
| 443 | **open** (TLS handshake did not complete from here) |
| 8080 | closed — **free for QManager** |
| 22 (ssh) | TCP connect times out |
| 23 (telnet) | closed |
| ICMP | dropped (ping fails; HTTP still works) |

The device is reached at `192.168.3.1` **through the upstream gateway `192.168.6.1`** — i.e.
we are on the **WAN side** of the X16, not its LAN. The vendor firewall drops management
ports from WAN while leaving the web UI reachable, which matches `basic_prv`'s WAN-side
rules. `zlt_x16_diagnose.py` only ever worked from inside the X16's LAN.

**Needed from the operator, any one of:**
1. Join the X16's LAN — plug into a LAN port or connect to its Wi-Fi — so the Mac gets a
   `192.168.3.x` address and `ssh zlt-root@192.168.3.1` / telnet 23 works.
2. Or connect the X16 to the `192.168.6.0/24` network and give it a DHCP address.
3. Or enable a management port on the WAN side (not recommended).

Everything in Phase 0 onward needs this. Phases 1–2 (build and stage) can proceed without it.

## Blocker 2 — AT entry point unknown (decision blocker)

No AT tty exists (see [05-the-at-problem.md](05-the-at-problem.md)). The vendor UI shows an
enabled `AT_CMD` menu (`main.js`: `AT_CMD:{index:55,hideFlag:"0"}`) served by
`/cgi-bin/http.cgi`, which implies an AT path exists — but **which binary implements it is
unknown**. One `ls` + `ps` on the device settles it, and it changes the entire Phase 4
approach (wrap it vs. build the QMI bridge).

Note: `/html/config/lteATConfig.html` returned **404** when probed, so the page name in
`main.js` is not the served path (or the page is only injected on certain menus). Do not
assume the UI page is reachable without login.

## Open questions (each needs ~1 command on the device)

| # | Question | Why it matters |
|---|---|---|
| 1 | `df -h /data`, free space, filesystem type | payload is ~15–25 MB (frontend + jq + libs) |
| 2 | Does `busybox httpd` exist? Which applets? | the whole serving story |
| 3 | Is `jq` present? If not, does our staged binary's `GLIBC_*` ≤ 2.31? | 142 files depend on it |
| 4 | `ps w` — full daemon list, and what serves port 80 (`-h` docroot) | docroot + `After=` targets for units |
| 5 | `uname -r`, `nproc` | kernel-dependent decisions, poll cadence budget |
| 6 | `busybox flock -w 1` supported? | `qcmd`'s lock loop exists because GreenPacket's busybox lacked `-w` |
| 7 | Does `xt_HL` exist (`iptables -j TTL --ttl-set`)? | TTL page |
| 8 | `/dev` listing — any `qrtr`, `mhi`, `ipa`, spare tty | confirms QMI path shape |
| 9 | Is `qmicli` still on the device from the earlier PDC experiment? Where? | saves re-staging, decides 4B cost |
| 10 | Does `systemctl enable` survive a reboot on this firmware? | whether a boot hook is needed |
| 11 | Vendor UI docroot + whether a second httpd instance on 8080 coexists cleanly | coexistence |
| 12 | Is there a vendor "LAN only" firewall toggle that would block 8080 from the LAN? | reachability |

## Assumptions that turned out to be WRONG (recorded so they are not repeated)

| Assumption | Reality |
|---|---|
| "The modem is a separate SIMCom module reachable over tty/USB" | On-die SDX65; AT is IPC (`sockmsg`), no device node |
| "The device has no Qualcomm QMI (SIMCom ≠ Qualcomm)" | **Wrong** — SDX65 is Qualcomm; QRTR/QMI works and `qmicli` was already used on this unit for PDC |
| "The rootfs is read-only like the GreenPacket" | **Wrong** — `/etc` and `/data` are writable, systemd units install normally |
| "WAN netdev will be `wwan0`/`eth2`, so QManager's `rmnet+` rules break" | **Wrong** — the X16 WAN is `rmnet_data0` over `rmnet_ipa0`, exactly what QManager expects |
| "`/usrdata` is the writable volume" | **Wrong** — that is a GreenPacket/Suncomm convention; X16 uses `/data` |

## What is already done

- QManager `greenpacket` fetched and unpacked at `/tmp/qm` (1427 files).
- Four exploration lanes completed; reports in [raw/](raw/).
- Host build toolchain verified: `bun 1.4.2`, `node v26`, `cargo 1.98`.
- Registry reachability verified: npm 200, `jq` release asset 200 (github.com direct git is
  blocked, `codeload`/release URLs work — use `curl`, not `git clone`).
