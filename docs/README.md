# ZLT X16 — Documentation Index

Working notes for the customer's **ZLT X16** router at `192.168.3.1`
(SDX65 / SIMCom SIM8260E, Ooredoo-Oman `OMN247` firmware, deployed on Pakistani
networks).

There are **two parallel tracks** in this folder. Read the one you need.

---

## Track A — QManager port to the X16 (design + blockers)

Goal: run the GreenPacket QManager web UI on the X16 ODU with real SIM8260E data.

| Doc | Topic |
|---|---|
| [01-target-device.md](01-target-device.md) | Hardware/SoC/module profile of the X16 ODU |
| [02-qmanager-architecture.md](02-qmanager-architecture.md) | How QManager works, runtime contract |
| [03-quectel-surface.md](03-quectel-surface.md) | Quectel-specific surface that must move |
| [04-simcom-at-mapping.md](04-simcom-at-mapping.md) | SIM8260E AT command mapping |
| [05-the-at-problem.md](05-the-at-problem.md) | The crux: AT transport/dialect |
| [06-port-plan.md](06-port-plan.md) | Phased port plan, port 8080 |
| [07-blockers.md](07-blockers.md) | Blockers & open questions |
| [08-deployment-log.md](08-deployment-log.md) | **Deployed & verified**: payload, shims, live AT captures, what works today |
| [18-ipacm-enablement.md](18-ipacm-enablement.md) | IPACM supervisor deployment, boot hook, verification and rollback |
| [25-smartdns-enablement.md](25-smartdns-enablement.md) | SmartDNS resolver: what the `/local-network/smartdns` page needed, the dnsmasq wiring, the carrier baseline, and the boot proof |
| [09-features.md](09-features.md) | **Feature audit + test suite**: every endpoint's verdict, the AT-daemon outage and its three fixes, speed numbers, known gaps |
| [23-cell-locking-on-sim8260e.md](23-cell-locking-on-sim8260e.md) | SIMCom LTE cell-lock mapping, verified limits, NR-SA refusal, and tower schedule safety |
| [24-history-archive-on-x16.md](24-history-archive-on-x16.md) | Why the X16 History tab was blank and the Tier-1 archive fallback |
| [26-antenna-stats-on-x16.md](26-antenna-stats-on-x16.md) | Per-chain antenna telemetry: the `CRSRP`/`CSINR` mapping behind Antenna Statistics, and why RSRQ stays per-cell |
| [27-call-terminal.md](27-call-terminal.md) | **Browser call terminal**: two-way VoLTE call audio in the QManager UI (vendor PCM tap, G.711/WebRTC, HTTPS front for the microphone) |
| [28-porting-contract.md](28-porting-contract.md) | **Every assumption a new device must satisfy** — transport, CPSI/CCAINFO field order and scaling, TA units, the non-AT sources and their env overrides, vendor data grammars, busybox/ash traps, boot ordering. Read this before porting to a second device. |
| [29-wan-drops-and-band-switching.md](29-wan-drops-and-band-switching.md) | **Why the internet disappears for "about a minute"** — the vendor dialer's two ~50–60 s poll watchdogs, measured recovery times, and why the band switch is a *symptom* of the bearer teardown rather than its cause |
| [30-cpu-profile-and-kernel-noise.md](30-cpu-profile-and-kernel-noise.md) | **CPU profile + kernel-log triage** — what is actually hot (measured by jiffy deltas), the two self-inflicted hogs, the 14 720 lines/min ipacm log noise (fixed, −93.4 %), and why the dmesg entries are boot transients |
| [31-webrtc-stack-research.md](31-webrtc-stack-research.md) | Open-source gateway comparison for the X16 call path: keep Pion, evaluate Janus only if rooms grow, Asterisk does not replace the modem adapter |
| [32-client-noise-suppression.md](32-client-noise-suppression.md) | Client-side noise suppression for the browser uplink: what RNNoise, DeepFilterNet3, DTLN, FastEnhancer and webrtc-apm actually are (checked with `gh`), why it belongs in the browser and not on the one-core router, and the phased plan with the measurements that would let us ship it |
| [33-antenna-controllability.md](33-antenna-controllability.md) | **Can the antenna be configured in software? No.** Four chains are measurable (`CRSRP`/`CSINR`/`CRSSI`) but not selectable — the AT, userland, device-tree and NV evidence, what *is* configurable (band/RAT/cell), and the `AT+CLAC` probe that wedges `atcmd_daemon` |
| [34-at-shim-cost.md](34-at-shim-cost.md) | **What the AT shim itself costs** — 40 ms of the 70 ms per command was our own pipelines, not the modem; the fork-free rewrite and the snapshot cache that followed, the A/B that proved no behavioural change, the fixed reply socket in `/bin/atcmd` that makes serialisation mandatory, and why `/dev/smd8` is not a shortcut |
| [35-modem-firmware-version.md](35-modem-firmware-version.md) | **Which SIMCom release is on the module** (`2212B01X62M88A-LGA_CUS_TZ`, baseband `B01V22`, LE12 baseline 2023-04-10), why "update the SIMCom" means "update the ODU" (the module's SoC is the router), the four update paths and which one is viable, and why firmware is a candidate — not the established cause — of the WAN drops |
| [30-gap-fill-plan.md](30-gap-fill-plan.md) | **What the vendor UI on :80 has that QManager on :8080 does not** — the parity gaps (NAT/DHCP/QoS/parental/VPN), the installed-but-unwired engines, the ODU-only features worth building, and the sprint order. Built from five scouts in `raw/gap-0*.md` |
| [36-qmi-direct-probe.md](36-qmi-direct-probe.md) | **QMI without libqmi**: band capability vs policy vs EFS (four sources, all agreeing), CA with an activation state AT cannot report, why the QRTR control ABI is mainline here and not Android's, and the proof that **cell lock has no QMI path** on this firmware (`NAS 0x00D7` → `not-supported`, while `AT+CCELLCFG?` still reads `0,0`). Tool: [`../scripts/qmi-probe/`](../scripts/qmi-probe/) |
| [37-process-table.md](37-process-table.md) | **The Processes page** — live per-process CPU/memory from `/proc`, why the window is the poll interval, the two CPU scales (one process vs the whole core), the two `null` rules, the four constructs that made it 5× more expensive (measured), and why it is read-only |
| [44-scell-churn-vs-band-flapping.md](44-scell-churn-vs-band-flapping.md) | **"It keeps switching bands"** — an SCell has three states and two different signallings: 1h45m of 1 Hz data shows **0 serving-cell changes**, 57 RRC SCell add/release (the real churn) and 82 MAC activation toggles (normal). What other operators' users report, and why the UE cannot refuse an SCell |
| [45-firmware-scell-surface.md](45-firmware-scell-surface.md) | **Is there an LTE CA/SCell switch in the firmware? No.** EFS has five RRC/ML1 items and none concern CA; the whole QMI IDL has one CA message and it is a getter; 14 vendor services refuse inventory; PDC reports no configs. Includes the deep pass (DSD decodes, three carriers' APNs) and the method that does not work |
| [46-mbn-switch-attempt.md](46-mbn-switch-attempt.md) | **Switching to ROW_Commercial: not possible on this firmware.** `AT+CMCFG="list"/"autoselect"` → ERROR (the command the vendor dialer is coded for); PDC *software* configs are empty and the `.mbn` upload fails at 0 of 48 436 bytes. Nothing was changed, so nothing to roll back — and `docs/12` already found no MBN swap helps the bearer |
| [recon-x16.sh](recon-x16.sh) | On-device recon script |
| [captures/](captures/) | Raw recon output + real SIM8260E AT responses |
| [raw/](raw/) | Scout reports and captured X16 web assets |
| [`../deploy-x16/`](../deploy-x16/) | The X16 adaptation layer (AT shim, serve script, path-fix, systemd unit) |
| [`../deploy-x16/smartdns/`](../deploy-x16/smartdns/) | SmartDNS module: resolver + dnsmasq wiring + guard (own `install.sh`, `--check`, `--uninstall`) |
| [`../router-fix/voip-bridge/`](../router-fix/voip-bridge/) | Call terminal module: PCMIO audio pump + WebRTC bridge + the QManager Calls page's backend (own `install.sh`) |

> **⚠️ Blocker 1 ("no shell on the device") is now SOLVED.** Shell access exists
> over both telnet (port 23) and SSH (port 22). See
> [10-access-and-ssh.md](10-access-and-ssh.md).
>
> **⚠️ Blocker 2 (AT transport) is also SOLVED.** The X16 has no AT tty, but
> `/bin/atcmd` is the vendor's CLI for `atcmd_daemon` and inherits its
> serialisation against `/bin/dialer`. QManager's `qcmd` now works end-to-end:
> `qcmd 'AT+CGMM'` → `SIMCOM_SIM8260E`. See [08](08-deployment-log.md).
>
> **Status: QManager is LIVE on `http://192.168.3.1:8080/`** (password `<redacted-password>`),
> vendor UI on :80/:443 untouched, both services enabled at boot.
>
> The dialect layer (**Option A**) is implemented and in production:
> `deploy-x16/atcli_smd11` translates Quectel ⇄ SIMCom so `parse_at.sh`, all 87
> CGIs and the poller run unmodified. Live data verified: LTE B3 with
> B3+B1+B5 carrier aggregation, RSRP/RRSQ/SINR, carrier, APN, WAN IP, temperature.
> Poller errors `[]`, dialer AT-failure lines **0**.
>
> **Endpoint audit: 46 ok · 2 known-unsupported · 0 failures.** Tests:
> `sh tests/run-all.sh` (180 assertions, no device) and
> `sh tests/run-all.sh --device` (+ 48-endpoint smoke + semantic checks), and
> `tests/check_boot_wiring.sh` (21 assertions: enabled ≠ started on this
> firmware — see "Boot persistence" in [09](09-features.md)).
>
> Known gaps (deliberate, documented in [09](09-features.md)): SMS *bodies*
> (storage counts are accurate), per-antenna RSRQ, CA SINR per component,
> full-band `AT+QSCAN`, NR-SA cell locking and modem persistence control, and
> dual-SIM failover. The SIM8260E LTE neighbour scan and Ookla speedtest now
> have live-data coverage; see [23](23-cell-locking-on-sim8260e.md) for the
> narrower LTE cell-lock/tower-schedule contract.
>
> **⚠️ Port 8080 has no firewall rule and binds `:::8080`.** It is currently
> reachable from the cellular WAN (`INPUT` policy is `ACCEPT`; only tcp 22/80/443
> are explicitly dropped on `rmnet_data0`). Today the WAN address is
> carrier-CGNAT so it is not internet-reachable, but this should be closed —
> see [16](16-initscript-and-firewall-audit.md) §S4 for the two rules to add.

---

## Track B — Access, and the customer's "internet disappears" fault

| Doc | Topic |
|---|---|
| [10-access-and-ssh.md](10-access-and-ssh.md) | Telnet/SSH access, credentials, how SSH was installed, boot wiring |
| [11-device-and-firmware.md](11-device-and-firmware.md) | Firmware/build versions, partitions, writable paths, users, services |
| [12-speedtest-disconnect-diagnosis.md](12-speedtest-disconnect-diagnosis.md) | **The reported fault** — Jazz vs ONIC, the NAT-table claim, what is actually happening |
| [13-greenpacket-comparison.md](13-greenpacket-comparison.md) | Side-by-side config vs the working GreenPacket O5A |
| [14-config-defects-and-fixes.md](14-config-defects-and-fixes.md) | Every concrete defect, with severity and fix |
| [15-change-log-on-device.md](15-change-log-on-device.md) | Exactly what was changed on the box, and how to undo it |
| [16-initscript-and-firewall-audit.md](16-initscript-and-firewall-audit.md) | Audit of all 82 boot scripts + the firewall: rule→source map, security findings, tuning |
| [17-backups-and-restore.md](17-backups-and-restore.md) | On-device + local backups, manifest, and restore procedure |
| [18-ipacm-enablement.md](18-ipacm-enablement.md) | IPACM / IPA investigation + current activation state |
| [19-vulnerability-assessment.md](19-vulnerability-assessment.md) | **Full vulnerability assessment** — 19 ranked findings, exploit status, remediation |
| [20-device-unlock-analysis.md](20-device-unlock-analysis.md) | How this unit was unlocked: SIM-lock state, and the confirmed root-shell injection chain |
| [21-fota-and-update-channels.md](21-fota-and-update-channels.md) | FOTA / TR-069 / version-check: why the device cannot self-update |



---

## Track C — The vendor binaries, decompiled (reference for everything above)

Five vendor ELFs account for almost every behaviour we have had to guess at. Each
has a page here, and the decompiled C for each is committed in
[`../firmware-analysis/`](../firmware-analysis/) — `atcmd_daemon`, `atcmd`,
`libmdlsockmsg`, `libolinterface`, `libmdlencrypt` — so a claim can be re-checked
without a device.

Tool: [`../scripts/decompile/`](../scripts/decompile/) — one command per binary
(Ghidra headless + a resolver for the ARM literal-pool strings both decompilers
print as arithmetic, plus `EXTRA_FUNCS` for functions Ghidra will not create).
The daemon's own log carries `(function, line)` for every entry, which is how a
dump is proved to match the shipped build.

| Doc | Binary | What it settles |
|---|---|---|
| [38-atcmd-daemon-internals.md](38-atcmd-daemon-internals.md) | `/bin/atcmd_daemon` (+ `/bin/atcmd`) | The AT channel: `smd8` vs `smd9`, the `tMSG` payload from both ends, the 60-deep queue and 3–60 s clamp, the two intercepted pseudo-AT commands (`AT+MODULE_SN` → `AT+CNVW=2497`, `AT+TOZEDSMS` → `AT+CMGS`), USSD via `/tmp/.ussd_*`, and the vendor bug that parks the URC thread on a nonexistent `/dev/smd3` |
| [39-sockmsg-bus.md](39-sockmsg-bus.md) | `/lib/libmdlsockmsg.so` | The IPC bus: `tMSG` field names from the vendor's DWARF, **all 55 app ids**, `/tmp/.sockmsg/<name>` layout, broadcast = 54 unicasts, `listen(1)` backlog, no auth |
| [40-simcom-sdk-interface.md](40-simcom-sdk-interface.md) | `/lib/libolinterface.so.1.0.0` | The **SIMCom SDK**: 83 QMI-facing entry points, `Sunsea_Basic_Init`'s three callbacks, **USSD arrives as a voice-call indication**, the PCM shm segments behind the call terminal |
| [41-vendor-crypto-lib.md](41-vendor-crypto-lib.md) | `/lib/libmdlencrypt.so` | **Nothing in the AT/QMI path is encrypted**; what the library really is (DES/3DES/AES-256/MD5/SHA-256/PBKDF2 + a keyless, reversible "encode"), and the 40 binaries that link it |
| [42-vendor-at-surface.md](42-vendor-at-surface.md) | `/bin/dialer` | The vendor's own AT commands: the **`CNVR`/`CNVW`/`CNV` NV family** (read **and** write, by number *and* by EFS path), `AT+CFAILUREMGRCFG?` (the reboot policy), `AT+SPIMEI`, and what this firmware refuses |
| [43-improvement-backlog.md](43-improvement-backlog.md) | **What the RE work changed, and what it deliberately did not** — the five shipped fixes with their evidence, the `AT+CFUN?` that was live inside a CGI chain *and* our allowlist, the vendor respawner nobody knew about, the measurement that shows the config credentials are **plaintext, not hashes**, and the P3 decisions (IMS via the SDK, USSD, the reboot-policy write) with reasons. Also the evidence-backed "don't do this" list |
| [47-antenna-chains-and-gnss.md](47-antenna-chains-and-gnss.md) | **"8 antennas, we report 4" and "can we get coordinates"** — the modem measures **4 chains per RAT**, so 8 = 4 LTE + 4 NR5G and the NR half only exists while NR is aggregated (it was not, on 2026-10-29); the UI already renders both cards. Plus the whole GNSS chain: `simcom-gnss.service` running 5 h, the SDK demo accepting a session (`gnss start success!!`), **no fix obtained** because no assistance data was ever downloaded and the receiver needs sky, and why QMI LOC is a dead end here (4 messages, all `missing-arg`). Tool: [`../scripts/gnss-probe/`](../scripts/gnss-probe/) |
| [48-open-sourcing.md](48-open-sourcing.md) | **Publishing this repo** — the audit that found 11 blockers (a fleet-wide WLAN PSK and a root password, in the tree *and* in history), why a sanitised mirror beat rewriting 2000 commits, exactly how the mirror was built and what it omits, and the two traps (`\b` does not work in a POSIX ERE; `gh` cannot push workflow files without the `workflow` scope) |

Read 39 before 38 if you want the data model first; read 42 before writing any new
AT plumbing, because it is where the undocumented commands live.

---

## The rest of the repo

| Path | Contents |
|---|---|
| [`../DIAGNOSIS.md`](../DIAGNOSIS.md) | 2026-09-01 deep dive: modem/dialer reverse engineering, MBN experiments, PDU teardown |
| [`../router-fix/`](../router-fix/) | MTU/MSS workaround assets + `start_ssh` (source of truth for the device) |
| [`../firmware-analysis/`](../firmware-analysis/) | Extracted `dialer`, `basic_prv`, `libolinterface`, decompiled sources |
| [`../scripts/at-probe/`](../scripts/at-probe/) | Read-only AT/NV reads nothing else exposes: module SN, the modem reboot policy + counters, NV by number and by EFS path, and a no-AT daemon/bus/guard health view (`docs/42`) |
| [`../scripts/decompile/`](../scripts/decompile/) | Vendor ARM ELF → annotated C: Ghidra headless plus a resolver for the ARM literal-pool strings both decompilers print as arithmetic (`docs/38` §10) |
| [`../zlt_x16_diagnose.py`](../zlt_x16_diagnose.py) | Long-running correlation harness (pings + telnet telemetry) |
| [`../zlt-*`](../) | Timestamped diagnostic capture directories |

---

## Current state — quick reference

**Access**

```bash
ssh zlt-x16                  # key-based, root, port 22
sshpass -p <redacted-password> ssh root@192.168.3.1   # password-based
```

SSH autostarts via `/etc/initscripts/start_ssh`, wired the same way the vendor
wires telnet (`TZApp.service → StartTZApp`). A 2-minute watchdog re-asserts it.

> **Vendor factory key removed 2026-10-26.** `/home/root/.ssh/authorized_keys`
> shipped containing `linweiqiang@server` (a fleet-wide vendor credential). It has
> been deleted from every authorized_keys location; only the customer's 6 keys
> remain. Removed material archived in
> `/data/zlt-backups/2026-10-26/removed-keys/`. See
> [14](14-config-defects-and-fixes.md) §4.

**TL;DR of the fault investigation**

1. **The customer's "NAT table / firmware 1.5" theory does not hold.** Firmware is
   `1.09.39.10` (not 1.5); conntrack peaks at **~1 %** of capacity
   (460 / 45056); NAT sits *below* the failure point. What actually happens is the
   **cellular bearer being deactivated by the network**, then re-created with a
   new WAN IP.
2. **The Jazz-vs-ONIC difference is real and quantified** from the router's own
   dialer log: Jazz churns 86 disconnects over 87 sessions; ONIC has **zero**.
3. **A genuine firmware defect was found**: the built-in APN database ships a
   misspelled Jazz prepaid APN — `jazzconnect.mobilinkword.com` (missing the `L`)
   versus Jazz's published `jazzconnect.mobilinkworld.com`.
4. **Three cheap, reversible experiments** are the fastest route to an answer:
   fix/force the APN, test the same SIM in the GreenPacket, and normalise TTL the
   way the GreenPacket does.
   > *Correction:* an earlier note here suggested the `ack-flood` connlimit could
   > be tripping the speedtest. It cannot — that rule lives in the **INPUT** chain
   > and only affects connections **to the router's own admin UI**, not forwarded
   > traffic. See [16](16-initscript-and-firewall-audit.md) §1.

Details and evidence: [12-speedtest-disconnect-diagnosis.md](12-speedtest-disconnect-diagnosis.md).

---

## House rules for this device

Learned the hard way; violating these costs 10+ minutes of downtime.

- **`/` and `/firmware` are read-only ubifs.** Only `/data` and `/etc` persist.
  `/tmp` is tmpfs and dies on reboot.
- **No `python`/`python3` on the box.** Use `sh`/`awk`/`sed`.
- **Never run recursive `grep` over `/system`, `/usr`, `/tzwww`.** It stalls the
  entire device (no ping, no telnet, HTTP accepts but never answers) for minutes.
  Observed twice. The box does not reboot — uptime keeps counting.
- **`mdlcfg get KEY` silently does nothing.** Reads are `mdlcfg -g KEY`; writes
  need `mdlcfg -a KEY=VAL` followed by `mdlcfg -c` or they are lost.
- **The device times out on roughly every second or third command.** Use retry
  wrappers (`zssh` / `zput`, described in [10-access-and-ssh.md](10-access-and-ssh.md)).
- **PATH matters.** `/sbin` is not on the default non-root PATH; `ip` and
  `iptables` live there.

## QManager on this box (quick reference)

```bash
/data/qmanager/bin/qm_serve.sh {start|stop|restart|status}   # :8080
/data/qmanager/bin/qcmd 'AT+CPSI?'                           # real modem read
curl -s http://127.0.0.1:8080/cgi-bin/quecmanager/public/overview.sh
```

- Payload root `/data/qmanager` (16.7 MB). Config `/etc/qmanager`. Nothing in
  `/`, `/usr` or `/firmware` was modified.
- AT goes through `/data/qmanager/bin/atcli_smd11` → `/bin/atcmd` → `atcmd_daemon`.
  **Never** open `/dev/at_mdm0` or `/dev/smd*` directly — that interleaves with the
  dialer, which reboots the box after repeated AT failures.
- `jq` is **not** installed on the device; the payload ships a static armhf build
  in `/data/qmanager/bin/`.
- 85 of 87 CGI scripts are stored non-executable in the repo — always
  `chmod 755` the CGI tree after staging, or httpd answers 404.

