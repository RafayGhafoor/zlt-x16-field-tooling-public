# AGENTS.md — ZLT X16 field tooling

Operating notes for agents (and humans) changing the customer's **ZLT X16** ODU
at `192.168.3.1` (SDXLEMUR-LITE / SDX65-class, ARMv7 **1 core**, kernel
5.4.210, systemd 244, Ubuntu 18.04 userland).

Read `docs/README.md` for the documentation index; this file is about **how to
change the device safely and reproducibly**.

---

## 1. Access

```sh
ssh zlt-root        # root@192.168.3.1, key ~/.ssh/id_ed25519 (alias in ~/.ssh/config)
```

Hard-won transport rules — do not relearn them the painful way:

| Rule | Why |
|---|---|
| **`scp` does not work** | dropbear has no `/usr/libexec/sftp-server`. Use `ssh host 'cat > /path' < localfile` (`scp -O` also works). |
| **Every ssh call must retry** | The link drops regularly (multi-WAN upstream). Wrap calls in a retry loop; 3–10 attempts with 3–4 s spacing. |
| **`rsync` is not installed** | Pull directories with `ssh host 'cd dir && tar cf - .' \| tar xf - -C local`. |
| **No `ip`/`ifconfig` in PATH** | Use `/bin/busybox.nosuid ifconfig`, `/proc/net/route`, `/proc/net/dev`, `/sys/class/net`. |
| **No `getent`, no `jq`, no python** | `/bin/atcmd` is the AT entry point; `curl`, `wget`, `flock`, `timeout` exist. |

## 2. Filesystem reality

| Path | State |
|---|---|
| `/` , `/firmware` | **read-only** ubifs — never plan to write there |
| `/etc`, `/data` | writable, persistent, **same volume** (`/dev/ubi2_0`) — changes survive reboot and `/` remount |
| `/persist`, `/cache` | writable, persistent |
| `/tmp`, `/run` | tmpfs, lost on reboot |

Anything you want to survive a reboot belongs in `/etc` (config/units) or
`/data` (payload/logs). Anything you want gone after a reboot belongs in `/tmp`.

## 3. Repository layout

```
qmanager/             **The QManager source tree, vendored** as a git subtree (full history):
                      Next.js UI, www/cgi-bin, lib, poller, dependencies/
                      (qmicli, sms_tool, smartdns). A fresh clone of THIS repo is
                      enough to deploy; `QM_SRC` defaults to it. Refresh with
                      `git subtree pull --prefix=qmanager qmsrc greenpacket`.
docs/                 Analysis, captures, per-topic write-ups (docs/README.md is the index)
docs/18-ipacm-enablement.md   IPA / ipacm investigation + current activation state
docs/25-smartdns-enablement.md  SmartDNS: what the page needed, the dnsmasq wiring, boot proof
deploy-x16/           QManager adaptation payload (AT shim, httpd, systemd units, unit healer)
deploy-x16/smartdns/  SmartDNS resolver module (resolver + dnsmasq wiring + guard; own install.sh)
router-fix/voip-bridge/  Call terminal module (PCMIO audio pump, WebRTC/G.711 bridge, QManager HTTPS front,
                         qmanager/ = the QManager app-layer source overlay it needs, with apply.sh)
router-fix/           Device-side fixes for the vendor firmware
router-fix/ipacm/     IPACM resilience module (payload + install.sh)  <- first module of this shape
device-etc/           (private repo only) on-device /etc snapshots and backups
firmware-analysis/    (private repo only) extracted vendor binaries + RE notes
tests/                Host-side unit/smoke tests for the QManager payload
scripts/modem-profile/  Read-only cellular/CA/band profiler; host-side, reusable on a new router
scripts/efs-nv/       Modem EFS/NV access (armv7 build of qcom-efsd), NV reader + backup
scripts/qmi-probe/    Read-only QMI over QRTR with no libqmi (band capability, SSP, CA, cell-lock GETs);
                      also the preferred backend for every 1 Hz qmi_read.sh read -- band lists,
                      neighbours, signal and registration -- with qmicli then AT as fallbacks
scripts/flap-meter/   Radio-transition sampler (1 Hz, typed events) + host analyzer that joins
                      it with the vendor dialer log to say whether churn or drops come first
scripts/demo/         Local harness: serves an exported UI build against captured CGI
                      answers, so a UI/branding change can be looked at without deploying
scripts/at-probe/     Read-only AT/NV facts nothing else exposes: module SN (AT+CNVR=2497,0),
                      the modem reboot policy + counters, NV by number and by EFS path, and a
                      no-AT health view (daemon fd table, /tmp/.sockmsg, guard log) -- docs/42
scripts/gnss-probe/   Does this unit get a GNSS fix: drives SIMCom's own SDK demo, listens for
                      position indications, stops the session -- docs/47
scripts/decompile/    Vendor ARM ELF -> annotated C (Ghidra headless + a resolver for the ARM
                      literal-pool strings both decompilers print as arithmetic) -- docs/38 §10
(private repo only) the publication gate: audit.sh + build-mirror.sh
zlt_x16_diagnose.py   Read-only on-device diagnostic collector
```

## 4. Deployment model (do this for new work)

Every device fix is a **self-contained module**: a directory with the payload,
a `README.md`, and a host-side **`install.sh`** that is idempotent, backs up what
it replaces, and verifies afterwards.

```
<module>/
├── README.md          what it does, why, how to verify, how to roll back
├── install.sh         host-side: --install (default) | --check | --uninstall
└── <payload files>    exact bytes that land on the device
```

**Boot-time reality (learned the hard way, applies to every module):**

- `/` is a read-only ubifs. The writable `/etc` + `/data` volume is mounted at
  **~10.6 s**, *after* systemd has loaded its units, so **anything under
  `/etc/systemd/system` (unit files, drop-ins) is invisible for that boot**.
  That is why `qmanager-*.service` and `zlt-wan-fix.service` do not come back
  after a reboot.
- `systemd-run` is refused until ~36 s into boot
  (`Transaction ... is destructive (shutdown.target has 'start' job queued)`).
- `userdata-ubi-mount.sh` (the script that mounts `/etc`) is executing from the
  read-only rootfs copy, so editing its `/etc` copy has no effect. It also ends
  with `exit 0`, so appended code never runs.
- The hookable place is a vendor script that runs from the mounted `/etc`:
  `/etc/initscripts/start_cfgd` (first one available, ~12 s) and
  `/etc/initscripts/StartTZApp` (later, where `start_ssh` and `zlt-fwtune` are
  wired). Insert hooks at the **top** of the script, not the end — meaning the first
  **executable** line, i.e. **after** the `#!` line. Both files are execve'd directly
  by systemd (`start_cfgd.service: ExecStop=…/StartTZApp stop`), so a comment above
  the shebang gives `ENOEXEC` and silently disables every hook in the file. It still
  passes `sh -n`; a module's own `--check` has to assert `head -1 == #!…`
  (`router-fix/atcmd-guard/hook.sh check` is the reference, `docs/43` §2.0).
- **A file you rewrite loses its mode bit.** `{ … } > f.new && mv f.new f` creates the
  new file with the umask default (644), and this busybox **`chmod` has no
  `--reference`** — under `2>/dev/null || true` that failure is silent. `StartTZApp`
  is 755 because systemd execve's it, so a rewrite without an explicit `chmod` leaves
  a file that parses, has its shebang, and still fails at `EACCES`. Capture the mode
  first (`stat -c %a`) and re-apply it after the rename; assert `-x` in `--check`
  (`docs/43` §2.0 has both failure modes).

### The build tree must carry every overlay

The UI is built from a QManager source tree, and **more than one module writes
into that tree**. That tree is now **vendored in this repository** as
`qmanager/` (a git subtree, full history), so one clone is enough and there is
no longer a way to build from a tree that is missing an overlay — the tree you
hold is the tree you build. `deploy-x16/install.sh` defaults `QM_SRC` to it and
only falls back to `/tmp/qm` if `qmanager/` is absent (that scratch path is not
a git checkout and predates this module's fixes: building it silently deploys
old behaviour).

| Writer | What it adds | Verify |
|---|---|---|
| `deploy-x16`'s fixes | committed in the QManager tree itself — i.e. in `qmanager/` here (CGIs, parsers, poller, and the `/system-settings/processes` page + its `processes.sh` endpoint) | `git log --oneline -- qmanager/` |
| `router-fix/voip-bridge/qmanager/` | 45-file app overlay: the Calls page, its sidebar entry, the mask/ring/reveal/RNNoise helpers, six locale files | `QM_SRC=./qmanager router-fix/voip-bridge/qmanager/apply.sh --check` |

Keeping the tree in-repo is what makes `apply.sh --check` (see the second row)
meaningful on every clone. **Refreshing the vendored tree** from its own repo,
and pushing QManager-side work back to it:

```sh
git subtree pull --prefix=qmanager qmsrc greenpacket     # refresh from the QM repo
git subtree push --prefix=qmanager qmsrc greenpacket     # send qmanager/ changes back
```

`qmsrc` is a remote for `RafayGhafoor/greenpacket-o5a-qmanager` (private). The
two-repo shape it implies is deliberate: this repo is what you deploy from, the
other is the upstream sync point for the fork.

**Build from this clone and the historical failure mode is gone** — previously a
tree missing an overlay half-disappeared silently. The Calls button vanished
exactly this way: the tree had no `app/cellular/calls/`, so the new sidebar had no
entry for it — but `install.sh` extracts the payload *over* the existing `www/`
without deleting, so the old `/cellular/calls/` page files survived on the device.
The result was a route that answered 200 and no way to reach it.

Two habits that follow:

- **Before building**, run each module's `--check` against `$QM_SRC` (the
  table above). `--build` prints the tree it used; if it is not the tree you
  meant, the payload will be wrong in a way no test catches, because the tests
  do not know what the UI *should* contain.
- **A rebuild does not remove pages** that a tree no longer has. Adding a
  feature and later dropping it leaves its route reachable until `/data/qmanager`
  is cleared. Deleting a page is therefore a deploy step, not a build step.

`install.sh` contract:

1. defaults to `ZLT_HOST=zlt-root`, honours `ZLT_TRIES` for retries;
2. streams files with `ssh 'cat > dst'` — never scp;
3. backs up anything it overwrites to `/data/zlt-backups/<YYYYMMDD>/<module>/`;
4. activates the fix using the device's actual boot mechanism (not necessarily
   `systemctl enable`; IPACM is launched detached from `start_cfgd` because
   units under `/etc/systemd/system` are invisible during boot);
5. prints a verification block and `--uninstall` restores vendor behaviour;
6. re-running is safe.

**One command, ordered.** `./deploy.sh` runs every module in the order that
actually works — `ipacm` first (it hooks `start_cfgd`, the earliest hookable script),
then the `StartTZApp` hooks, then `deploy-x16` and the two modules that live inside
its tree — and stops at the first failure with that module's rollback instead of
leaving a mixed state. `--check` verifies everything and changes nothing,
`--dry-run` prints the plan, `--only a,b` does a subset. Prefer it over the
per-module commands unless you are working on one module.

Reference implementation for a single module: `router-fix/ipacm/install.sh`.

```sh
cd router-fix/ipacm && ./install.sh              # deploy
cd router-fix/ipacm && ./install.sh --check      # verify only, no changes
cd router-fix/ipacm && ./install.sh --uninstall  # revert
```

Existing modules and their current steps:

| Fix | Payload | Installs to |
|---|---|---|
| IPACM supervisor | `router-fix/ipacm/` | `/etc/initscripts/ipacm-starter.sh`, `/etc/initscripts/zlt-ipacm.sh`, hook in `/etc/initscripts/start_cfgd` |
| WAN MTU/MSS workaround | `router-fix/zlt-wan-fix.sh`, `zlt-wan-fix.service` | `/data/zlt-wan-fix/`, `/etc/systemd/system/zlt-wan-fix.service` |
| SSH at boot | `router-fix/start_ssh` | `/etc/initscripts/start_ssh`, wired from `StartTZApp` |
| Firewall tuning | `router-fix/zlt-fwtune` | `/etc/initscripts/zlt-fwtune`, wired from `StartTZApp` |
| QManager UI | `deploy-x16/` | `/data/qmanager`, `/etc/systemd/system/qmanager-*.service` |
| QManager unit healer | `deploy-x16/qmanager-guard.{service,timer}` | `/etc/systemd/system/`, timer started by `start_qmanager` |
| SmartDNS resolver | `deploy-x16/smartdns/` | `/data/qmanager/{bin/smartdns,etc/smartdns.conf}`, `/etc/systemd/system/{qmanager-dns*.service,zlt-smartdns.*}`, hook in `StartTZApp` |
| Browser call terminal | `router-fix/voip-bridge/` | `/data/webrtc/{bin/x16-audio,bin/x16-webrtc,bin/zlt-webrtc.sh,etc/{ca.crt,server.crt},log/calls.jsonl,contacts.json,recordings/}`, `/etc/systemd/system/zlt-webrtc.service`, hook in `StartTZApp` |
| AT daemon health guard | `router-fix/atcmd-guard/` | `/data/zlt-atcmd-guard/guard.sh`, `/etc/systemd/system/zlt-atcmd-guard.{service,timer}`, hook at the top of `StartTZApp` |
| GNSS daemon off | `router-fix/gnss-off/` | `/data/zlt-gnss-off/gnss-off.sh`, hook at the top of `StartTZApp` (below the shebang), `simcom-gnss.service` stopped + masked; **no fix is obtainable on this unit** (`docs/47` §3) |
| WAN TTL normalisation | `router-fix/ttl-normalise/` | `/etc/initscripts/zlt-ttlnorm`, hook in `/etc/initscripts/StartTZApp` (directly after `ddos.sh`) |
| CPU governor pin | `router-fix/cpu-governor/` | `/etc/initscripts/zlt-cpufreq`, hook at the top of `StartTZApp` (below the shebang); **performance** vs the vendor's `ondemand`, measured ~4 % on a fixed loop |
| WAN outage recorder | `router-fix/wan-recovery/` | `/etc/initscripts/zlt-wan-recovery`, hook at the top of `StartTZApp`; read-only: one line per outage in `/data/zlt-wan-recovery.log` (durations parsed from the dialer's own stamps) |

Three of those modules own a **guard** as well as a payload, for the same reason: a
process that is up is not a process that stays up, and nothing on this firmware
supervises dnsmasq, the QManager units, or `atcmd_daemon`'s indication thread.

| Guard | Cadence | Evidence it writes |
|---|---|---|
| `zlt-smartdns.timer` → `zlt-smartdns.sh wire` | 1 min | re-applies the `/tmp/dnsmasq.conf` block, restarts dnsmasq only if it changed, starts it if dead |
| `qmanager-guard.timer` → `start_qmanager ensure` | 1 min | `/data/log/qmanager-guard.log` — one line per unit it had to restart, with the time |
| `zlt-atcmd-guard.timer` → `/data/zlt-atcmd-guard/guard.sh` | 1 min | `/data/log/zlt-atcmd-guard.log` — only when it acted (or suppressed); it repairs the daemon's dead URC thread (`docs/38` §1) |

All three are silent when healthy: a run costs a `netstat`/`grep`/`cmp`, four
`systemctl is-active` calls, or one `pgrep` plus a `/proc/<pid>/fd` read. Each was
justified by a measurement, not a hunch — `docs/25-smartdns-enablement.md`, the
healer's section in `deploy-x16/README.md`, and `docs/38` §1 for the daemon guard.
A guard that fires on a hunch is how a supervisor becomes the outage.

## 5. Rules before touching the device

1. **Collect first, change second.** Run `zlt_x16_diagnose.py` / the recon
   script and commit the capture to `docs/captures/`.
2. **Back up** every file you overwrite (`/data/zlt-backups/<date>/`), see
   `docs/17-backups-and-restore.md`. For **modem NV** use
   `scripts/efs-nv/backup.sh --raw` (whole `efs2` partition) before a round of
   changes and `scripts/efs-nv/backup.sh` (item-wise, sha256-verified) before
   each write: NV cannot be reinstalled from any vendor package.
3. **Never touch modem firmware, MBN/PDC profiles or `/bin/dialer`** without a
   verified rollback ID. A previous MBN experiment (`W_One_Commercial`) did not
   fix the CID-6 flapping — see `DIAGNOSIS.md`.
4. **The data call is fragile.** Restarting QCMAP/dialer/services that own the
   PDP context can drop the WAN; know the recovery path before you start, and
   prefer reversible changes.
5. **Check the vendor services you are fixing actually run.** Several units ship
   `failed` on every boot (`QCMAP_Bootup`, `mbim_copybind`, `pcie-diag`,
   `qcmap_wlan`, `rdisc`, `ninfod`) — that is background noise, not a target,
   unless a specific symptom points at it.
6. **A unit's "disabled" label is unreliable.** `systemctl is-enabled` reports
   `disabled` for vendor units whose enable symlink lives in `/lib/...wants/`.
   Check `/lib/systemd/system/*.target.wants/` and `systemctl show -p After`.

## 6. Verification habits

- Prefer **observable ground truth** over daemon logs: `/sys/kernel/debug/ipa/*`,
  `/proc/net/route`, `/proc/net/dev`, and process/service state. On this X16
  firmware the IPA `ip4_*` debugfs tables read empty even when hardware traffic
  is flowing; use `/sys/kernel/debug/ipa/stats` (`hw_tx` vs `sw_tx`) and the
  IPACM WAN-event marker/log instead.
- After a change that should survive reboot, **reboot and re-check** — several
  vendor bugs only appear during boot ordering.
- Journald does **not** persist (`journalctl` → "No journal files were found").
  Capture diagnostics with `dmesg`, `/data/log/<service>.log`, or your own
  logging — and note that `dmesg -c` clears the ring buffer of evidence.
- A guard's own log is often the only place a *silent* failure is visible:
  `/data/log/qmanager-guard.log` (a unit something else stopped),
  `/data/log/zlt-smartdns.log` (boot + wiring decisions),
  `/data/log/zlt-ipacm-boot.log`. Read them before concluding "it just stopped".
- A remote reboot takes ~2–3 min; re-verify WAN, LAN client reachability, and
  the specific fix afterwards.
- **For a UI change, look at it before you deploy it.** `scripts/demo/` serves an
  exported build against captured CGI answers (`capture-fixtures.sh` snapshots a
  live device, so the shapes are real), with the snapshot's timestamps shifted so
  the cards read as live. Two builds on two ports = the before/after in two tabs,
  no reboot, no `/data/qmanager` churn — and it is the only cheap way to check a
  branding token, a layout change, or "does this page still render".

### Reading the modem: radio state, EFS and NV

Five host-side tools, all read-only and all parameterised by `ZLT_HOST` so they
run unchanged against the next device (`qmi-probe` and `at-probe` are also the two that
answer without ever taking the AT lock):

```sh
scripts/modem-profile/profile.sh --minutes 10   # capability vs policy vs actual + churn rate
scripts/qmi-probe/build.sh                      # read-only QMI over QRTR, 12.5 ms/call end-to-end (docs/36)
scripts/flap-meter/start.sh                     # 1 Hz typed radio transitions + drop join (docs/44)
scripts/efs-nv/build.sh && scripts/efs-nv/nv-read.sh   # NV policy, decoded
scripts/efs-nv/backup.sh --raw                  # full efs2 snapshot BEFORE any NV write
scripts/at-probe/at-probe.sh health             # AT daemon / bus / guard, no AT traffic
scripts/at-probe/at-probe.sh sn                 # module serial number (docs/42)
scripts/decompile/decompile.sh <elf>            # vendor binary -> annotated C (docs/38 §10)
```

Traps that cost real time here — all measured on this unit:

| Trap | Reality |
|---|---|
| `AT+CLAC`, `AT+CNBP?`, `AT+CSYSSEL=?` | **Hang risk, and `atcmd` has no timeout** — one of these blocks the shared AT channel and takes the QManager poller and the calls bridge down with it until `atcmd_daemon` respawns. Never send them directly. Measured 2026-10-29 through the shim it *did* answer (`AT+QNWPREFCFG="ue_capability_band"` → 18–32 ms, warm), which is exactly why this trap is dangerous: it works until the boot where it does not. `qmi_read.sh` reads it over QMI instead: probe → qmicli → AT fallback, same `+QNWPREFCFG:` dialect, so `parse_policy_band()` is unchanged (`docs/36`). The poller's boot path has used the QMI route since commit `d82715d5`. Its first deployment looked like a restart loop every ~40 s and was not the change — see the hand-push row below. |
| `AT+CFUN?` | **Hangs** on this firmware (killed at 20 s, no reply) — same class as `AT+CSYSSEL=?`. Do not send it to read the functional mode. `AT+CPSMS?`, `AT+CEDRXS?` and `AT+CSCLK?` do answer, with `ERROR`: PSM, eDRX and UART sleep are not implemented, so there is no modem power-saving switch to turn off for performance (`docs/44` §2a). |
| `AT+QCAINFO` | Quectel command; **ERRORs** on this SIMCom part. The CA source is **`AT+CCAINFO?`** (PCC/SCC rows). |
| `AT+QNWPREFCFG="lte_band"` | A shim rename of `AT+CSYSSEL="lte_band"`. Under contention the read can be **truncated** (`1:3` for `1:3:5:28:38:41`) — an artefact, not a policy change. docs/29's "mystery writer" was this. |
| `AT+CSYSSEL="lte_band"` truncation vs a real policy change | The band set has been read as `1:3:41`, `1:3:5:41` and (2026-10-29) `1:3:5:28:38:41` across sessions. Before blaming the shim, re-read the **mask** over QMI (`scripts/qmi-probe ssp`) — it cannot truncate, and on 2026-10-29 it agreed byte-for-byte with EFS `lte_bandpref`. See `docs/36-qmi-direct-probe.md`. |
| Carrier aggregation "flapping" | **An SCell has THREE states**, not two — `QMI_NAS_SCELL_STATE_{DECONFIGURED=0, DEACTIVATED=1, ACTIVATED=2}` — and they are signalled differently: configured/released is **RRC** (A4/A2/A6, the network re-deciding your carriers, *the churn worth chasing*), activated/deactivated is **MAC CE** (power saving, tracks data activity, normal). Collapsing 0 and 1 is the mistake this row exists to prevent. A UE cannot refuse any of it. `scripts/qmi-probe watch` types them `scc-set` (membership), `scc-cfg` (state 0 ↔ 1/2) and `scc-state` (1 ↔ 2); over 1h45m on 2026-10-29: **0 serving-cell changes, 57 scc-set, 82 scc-state, 0 WAN drops** — so the flicker is CA management, not reselection, and it is not what takes the link down. Do not over-attribute it to `sCellDeactivationTimer` either: that timer's values are 20–2560 ms while measured activated episodes run to a **median 25 s / max 558 s**, so most deactivations are explicit network MAC CEs or long scheduling gaps. `docs/44` §2d–2e. |
| `+CPSI` fields 11–14 | RSRQ, RSRP, RSSI, SIL/SNR, **×10**. `-731` is −73.1 dBm RSRP. Reading field 11 as RSRP makes a healthy link look dead. |
| Band capability over AT | Not readable — the only query hangs. Read it over **QMI** instead: `qmicli -d qrtr://3 --dms-get-band-capabilities`, or `scripts/qmi-probe caps` (12.5 ms end-to-end, no AT lock, no `atcmd` risk) — `docs/36-qmi-direct-probe.md`. The QManager status JSON still works but is no longer the only source. |
| `/data/log` | **Persists** — corrected 2026-10-30 by rebooting this unit: files from Oct 26/28 were still there afterwards, and `/data/log/zlt-atcmd-guard.log` kept the lines a previous run had written. What *is* lost is **`/tmp/logs`** (tmpfs: the vendor's `ATCMD_DAEMON.log`, `DIALER.log`). So a guard's own log in `/data/log` is usable across reboots, and anything you want to correlate after a reboot must go there, not to `/tmp/logs`. Uptime still has to be checked before/after (`profile.sh` does). |
| EFS item names seen in the modem image | Mostly **firmware defaults**, not live items: reading them returns `bad length (0x15)`. Of 22 `nr5g/RRC/cap_*` items only 2 exist. |
| NV capability items (`cap_limit_rf_mimo`, `cap_control_*`) | They can only **downgrade**. No NV write adds a capability the UE firmware does not advertise — so "enable UL CA for X+Y" is not an NV knob. |
| `qcom-efsd` `image` command | Rejected by this modem (`bad command 0x13`). Use `backup.sh` / `backup.sh --raw` instead. |
| Hand-pushing a QManager shell file | **Push through `deploy-x16/install.sh`, or apply its patches.** The deployed `qmi_read.sh` carries `qmi_read_ld_library_path.patch` (ash: a `VAR=val func` prefix does not reach a shell function's children, and `platform.sh` makes `qm_timeout` a function). A plain copy breaks **every** qmicli call with status 3 while a static helper keeps working, so it presents as "the other backend is faster". The poller also needs the full path rewrite — `qm_pathfix_x16.sh` rewrites three patterns (`/usr/lib/qmanager` → `$QM_ROOT/lib`, `/usrdata/qmanager` → `$QM_ROOT`, `/usrdata` → `/data`); missing the first leaves a poller that cannot `. parse_at.sh` and exits 1 in a restart loop. Both hit on 2026-10-29. |
| Abstract unix socket connect | Must pass `offsetof(sun_path)+1+strlen(name)`; `sizeof(sockaddr_un)` gives `ECONNREFUSED` while the daemon looks healthy. |

The EFS helper is upstream `qcom-efs-browser`, which ships **aarch64-only**; this
box is **armv7l/glibc 2.31**. `scripts/efs-nv/build.sh` rebuilds it with
`zig cc -target arm-linux-musleabihf -static` (a plain zig glibc build fails on
the device with ``/lib/libc.so.6: version `GLIBC_2.33' not found``). It reaches
the EFS over **DIAG on QRTR node 3** — this firmware has **no `/dev/diag`**.

Where the radio policy actually lives, since this matters before any modem work:

- **MBN is not it.** `ROW_Commercial` sets 50 EFS items — IMS stack, data/PS
  features, GNSS, mmode voice/SMS — and **zero** band/CA/RRC-measurement items.
  The tree carries 138 packages but only two `common/` ones (ROW, W_One), and no
  Pakistan package exists. Chasing MBN for band/CA behaviour is wasted effort.
- **EFS NV is it.** `modem/mmode/lte_bandpref`, `nr_band_pref`,
  `nr_nsa_band_pref`, `mode_pref`, `nr5g_disable_mode` are the authoritative
  values, and they agree exactly with the AT layer.

## 7. Version control — one commit per completed feature

This working tree is a **local git repository** (initialised 2026-10-26).
`git log --oneline` is the change record of record; the `docs/` pages stay the
*reasoning* record. Do not let them drift: a doc that describes a fix and a commit
that contains it should land together.

**The gate is automatic.** Every commit runs `tests/run-all.sh` (host-only,
~6 s, no device, no network) and is **blocked** if any suite fails — in this
repo *and* in the QManager tree, because most of what the suites cover lives
there. Hooks are version-controlled in `.githooks/` (selected with
`core.hooksPath`, so they survive a fresh clone) plus a local hook written into
the sibling QManager checkout.

```sh
sh tests/install-hooks.sh            # install / re-install (idempotent)
sh tests/install-hooks.sh --check    # verify
sh tests/install-hooks.sh --remove   # revert
```

The suites run in parallel (deterministic output: each writes its own file and
the files are replayed in declaration order). `QM_TESTS_SEQ=1` forces the
sequential path. The device leg (`run-all.sh --device`) is deliberately *not* in
the hook: it needs the box and a 2–3 minute window, and it is never parallelised
— one SSH session against a 1-core router.

`git commit --no-verify` still exists, and a commit that uses it should say why
in its body.

**The rule: commit when a feature is finished and verified — not before, not in
one lump at the end.** "Finished" means the §6 verification was actually run; a
commit that claims a device fix carries the command and its result in the body.
Work that spans a device and the QManager source is committed **in both repos,
same scope**, and each message names the other side.

Message shape — subject is what changed, body is why and how it was proved:

```
<type>(<scope>): <imperative summary, ≤ 72 chars>

Why: the failure this prevents or the measurement behind it.
Verified: <command> -> <result>   (on-device work only)
```

`type` ∈ `feat` `fix` `docs` `test` `chore`; `scope` is the module directory
(`smartdns`, `ipacm`, `qmanager`, `agents`, …). One feature per commit — a commit
that also reformats, renames or "cleans up" something else makes the rollback of
the feature impossible, which is the only reason the history exists.

**What never goes in:**

| Excluded | Why |
|---|---|
| Vendor firmware, update packages, the SIM8200 AT manual PDF | `.gitignore` — re-add one deliberately with `git add -f` if it must ship |
| `firmware-analysis/` ELF dumps and `.raw` memory dumps | `.gitignore` keeps the `.c`/`.asm`/`.strings`/`.nm` RE notes beside them |
| `zlt-check-*/`, `zlt-diagnostic-*/`, `zlt-mbn-*/` capture dirs | One investigation's evidence; the copy worth keeping goes in `docs/captures/` |
| `node_modules/`, `.next/`, `out/`, `__pycache__/`, `.DS_Store` | Generated |
| The `smartdns` binary | It is GPL-3.0 vendor bytes owned by the QManager tree (`dependencies/smartdns/`); the X16 module takes it from there with a sha256 check |

`deploy-x16/speedtest` **is** committed on purpose: `deploy-x16/install.sh` pushes it
as payload, so ignoring it would break a fresh deploy of the speedtest feature.

**Secrets:** `device-etc/` and `device-etc/backup-*/` deliberately keep vendor config
snapshots (the rollback record) and those include credentials and auth server blocks.
They are **plaintext-equivalent, not hashes**: measured 2026-10-29, `mdlcfg -e`
returns `USR_WLAN2G_PASSWORD_0` byte-for-byte (`<wlan-psk-redacted>`, identical on all four
radios) — there is no encoding step to reverse (`docs/43` §2.3).

This is the **public mirror** of a private field repository. The private one
also keeps the vendor `/etc` snapshots, the extracted vendor binaries and the
raw captures those came from; they carry credential material and device
identity, so they are not published here.

## 8. Current state highlight: IPA / ipacm

`ipacm.service` used to die at boot (exit 255), leaving IPA with zero rules and
all forwarding in software. `router-fix/ipacm/` now deploys a detached
supervisor from the top of `/etc/initscripts/start_cfgd` (the first hookable
script after `/etc` mounts). At the verified reboot IPACM was up at ~23 s,
before the dialer assigned the WAN address, and learned it from rtnetlink.
Live IPA stats currently show hardware TX activity (`hw_tx>0`, `sw_tx=0`); internet
and LAN-client reachability were verified. IPACM learns the WAN address
**only** from an rtnetlink `RTM_NEWADDR` event, so restarting the supervisor
by hand loses hardware offload until the next data-call reconnect or reboot.
Details, deploy, checks and rollback: `docs/18-ipacm-enablement.md` and
`router-fix/ipacm/`.
