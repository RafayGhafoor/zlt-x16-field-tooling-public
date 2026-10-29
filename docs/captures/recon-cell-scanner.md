# Recon — QManager "Live" neighbour list does not work (X16)

Read-only investigation. Nothing was pushed, installed, restarted or edited on the
device. All device commands were `curl -s`, `ls`, `grep`, `ps`, `qrtr-lookup`, or a
`sh -c` that sources `qmi_read.sh` and calls its two predicates (no writes).

**Verdict up front:** the user's hypothesis is **correct**. The UI's *Live* range
(`?range=now`) is served **only** by the poller's QMI tick, that tick needs
`/data/qmanager/lib/qmi/bin/qmicli` + two private libs, and those three files were
**never deployed** to this device — the X16 staging script does not copy
`dependencies/qmi/` at all. The *Last read* range is a different code path (native
AT) and works. NR neighbour cells are unavailable on both paths; QMI would not
change that.

---

## 1. Reproduced symptom

### 1a. The device has no qmicli (and no libqmi-glib / libqrtr-glib payload)

```sh
ssh zlt-root 'ls -d /data/qmanager/lib/qmi'
# ls: /data/qmanager/lib/qmi: No such file or directory
```

`/data/qmanager/lib/` holds 32 `.sh` libraries and **no `qmi/` subdirectory**.
`/data/qmanager/bin/` holds 60 payload files and **no `qmicli`**. There is also no
`/data/gp` and no `/usrdata` on this device:

```sh
ssh zlt-root 'ls -d /data/gp /usrdata'
# ls: /data/gp: No such file or directory
# ls: /usrdata: No such file or directory
```

### 1b. The QMI reader resolves its binary and reports it unusable

```sh
ssh zlt-root 'sh -c ". /data/qmanager/lib/qmi_read.sh; \
  echo \"BIN=\$QM_QMI_BIN LIBDIR=\$QM_QMI_LIBDIR DEV=\$QM_QMI_DEV\"; \
  qm_qmi_available; echo \"avail_rc=\$?\"; \
  o=\$(qm_qmi_neighbours); echo \"neigh_rc=\$?\"; echo \"out=[\$o]\""'
```

```
BIN=/data/qmanager/lib/qmi/bin/qmicli LIBDIR=/data/qmanager/lib/qmi/lib DEV=qrtr://3
avail_rc=1
neigh_rc=2
out=[]
```

`rc=2` is `_qm_qmi_raw`'s "binary is not there / not executable"
(`qmi_read.sh:113-115`).

### 1c. The poller says so, once a minute, in its own log

`/tmp/qmanager.log` (qlog default, `qlog.sh:33`):

```
61:[2026-10-26 08:07:20] WARN  [poller:2377] neighbours live: QMI unavailable — live view idle
78:[2026-10-26 08:09:57] WARN  [poller:2377] neighbours live: QMI unavailable — live view idle
147:[2026-10-26 14:20:32] WARN  [poller:2377] neighbours live: QMI unavailable — live view idle
```

each immediately after `INFO [poller] neighbours: live mode on` — i.e. the UI did
enter the Live range and did renew the lease.

### 1d. The lease exists, the sample never does

```sh
ssh zlt-root 'ls -la /tmp/qmanager_neigh*'
# -rw-r--r-- 1 root root 1515 Oct 26 09:11 /tmp/qmanager_neighbour_scan_result.json
# -rw-r--r-- 1 root root   11 Oct 26 15:20 /tmp/qmanager_neighbours_live
```

The lease file (`?range=now` writes it) is being renewed; the live sample file
`/tmp/qmanager_neighbours_live.json` **has never been created**.

### 1e. What the user sees

`neighbour_scan_status.sh?range=now` answers the constant fallback
(`neighbour_scan_status.sh:100-106`): `live_at: null`, `cells: []`. The hook
treats that as a *successful* answer (`use-neighbour-scanner.ts:246-261`), so
`live` becomes a non-null object with `liveAt: null`, and
`aim-strip.tsx:363-368` renders the "waiting" copy:

> "The modem has not published a live sample yet. It usually appears within a
> second of opening this range."

i.e. a permanent empty table / permanent "waiting" strip — exactly "live
neighbour list does not work". (The CGI itself needs a session cookie; direct
`curl` from the device returns `{"success":false,"error":"unauthorized"}`, which is
why 1b/1c were used as the reproduction and not the HTTP endpoint.)

### 1f. The contrast: the AT one-shot path works

`/tmp/qmanager_neighbour_scan_result.json` (written 09:11 by the X16 override
worker) contains **8 real LTE neighbour rows** — EARFCN 1850 intra ×2, 3748 inter
×6, PCI 480/227/224/342/300/374, RSRP −74…−95. So the *Last read* range and the
AT transport are healthy; only the QMI-fed path is dead.

---

## 2. Root cause

### 2a. Which path serves what

| UI range | CGI | Data source | State on X16 |
|---|---|---|---|
| **Live** (`?range=now`, `en/cellular.json:426` `"now": "Live"`) | `neighbour_scan_status.sh` → `handle_range_now()` (`:78-106`) | `/tmp/qmanager_neighbours_live.json`, written by `qmanager_poller`'s `neighbours_live_tick()` (`qmanager_poller:3074-3120`) | **broken** — no qmicli |
| **Last read** (`?range=last`) | same CGI → `handle_range_last()` (`:113-158`) | `/tmp/qmanager_neighbour_scan_result.json`, written by `qmanager_neighbour_scanner` over **AT** (`qcmd AT+QENG="neighbourcell"`) | works |

The Live tab is **not** an AT path and has no AT fallback:

```
qmanager_poller:3076   qm_qmi_available || { neighbours_live_warn "QMI unavailable — live view idle"; return 1; }
```

### 2b. The line that is wrong

The tick is correct; the **deployment** is wrong. `deploy-x16/install.sh`
`build_payload()` stages only these trees (`install.sh:107-113`):

```sh
cp -a "$QM_SRC/out/."                            "$STAGE_DIR/www/"
cp -a "$QM_SRC/scripts/www/cgi-bin/quecmanager"  "$STAGE_DIR/www/cgi-bin/"
cp -a "$QM_SRC/scripts/usr/lib/qmanager/."       "$STAGE_DIR/lib/"
cp -a "$QM_SRC/scripts/usr/bin/."                "$STAGE_DIR/bin/"
cp -a "$SRC_DIR/qmanager_neighbour_scanner"      "$STAGE_DIR/bin/"
cp -a "$QM_SRC/deploy/sudo"                      "$STAGE_DIR/bin/"
...
cp -a "$SRC_DIR/atcli_smd11" "$SRC_DIR/sms_tool" "$STAGE_DIR/bin/"
```

`dependencies/qmi/` is **never copied** — `grep -n dependencies install.sh` returns
nothing. Upstream's own deploy recipe does stage it
(`greenpacket-o5a-qmanager/deploy/README.md:157`:

```sh
cp -a dependencies/qmi/bin dependencies/qmi/lib stage/lib/qmi/
```

and says at `:99` "a fresh device has no `/data/gp/qmi`, and without it the
neighbour live view cannot run"). The X16 module adapted the rest of the deploy
but dropped this step — so on this device `qmi_read.sh` resolves to a path that
does not exist.

### 2c. Path resolution is otherwise correct (not a second bug)

`qmi_read.sh` upstream looks for `/usrdata/qmanager/lib/qmi/bin/qmicli`
(`qmi_read.sh:70,80`). On the device the **deployed** copy already says
`/data/qmanager/…`, because `qm_pathfix_x16.sh` rewrites
`-e s|/usrdata/qmanager|/data/qmanager|g` (`qm_pathfix_x16.sh:53`). Verified:

```sh
ssh zlt-root 'grep -n "QM_QMI_BIN=\|_qmc in" /data/qmanager/lib/qmi_read.sh'
# 70:    for _qmc in /data/qmanager/lib/qmi/bin/qmicli /data/gp/qmi/bin/qmicli; do
# 80:[ -n "$QM_QMI_BIN" ] || QM_QMI_BIN=/data/qmanager/lib/qmi/bin/qmicli
```

So dropping the files at `/data/qmanager/lib/qmi/{bin,lib}` is sufficient; no code
change is needed for the lookup.

### 2d. The dependency never existed in this repo either

`deploy-x16/` has no `qmi/`, and the zlt-x16 tree has no `dependencies/` at all.
The bytes live only in the QManager tree:

| File | Size | sha256 |
|---|---|---|
| `dependencies/qmi/bin/qmicli` | 405 728 B | `ada595fd226e6be993523d44a485e545242794b7d98b426d0b4b1865eeab8bda` |
| `dependencies/qmi/lib/libqmi-glib.so.5.10.0` | 2 432 076 B | `1b6390c26ecc8ea3b3bac7730272219a007399fb8d5d5b2d98db55970c39019e` |
| `dependencies/qmi/lib/libqrtr-glib.so.0.0.0` | 26 360 B | `d02b0387f0cf243a372d4b8bc54bd39f2e6f35bbcec33d4d65ac0f9e53f914848` |

(plus the two symlinks `libqmi-glib.so.5 → .5.10.0`, `libqrtr-glib.so.0 → .0.0.0`).

---

## 3. Is QMI the true cause? Is it even available here?

### 3a. Yes, it is the cause — for the Live range only

Nothing else is consulted. `neighbours_live_tick()` calls `qm_qmi_available` →
`_qm_qmi_raw 'Operating mode retrieved' --dms-get-operating-mode` → returns 2 when
the file is missing (`qmi_read.sh:113-115, 186-210`). `qm_qmi_neighbours` and
`qm_qmi_signal` therefore never run, `/tmp/qmanager_neighbours_live.json` is never
written, and the CGI's 6 s freshness window (`neighbour_scan_status.sh:62,86-88`)
can never be satisfied.

### 3b. QMI *is* reachable on this firmware — the transport exists

This is the important counter-check, because the X16 is a Qualcomm SDX65
(`sdxlemur`, kernel 5.4.210) while the upstream feature was written against an
RG520N/RM520N:

```sh
ssh zlt-root 'ps w | grep -i qrtr; timeout 10 /usr/bin/qrtr-lookup | head'
#   16 root  [qrtr_ns]
#  189 qrtr  /usr/bin/qrtr-ns
#  492 root  [qrtr_rx]
#  Service Version Instance Node  Port
#       49       1        1    2 16389 IPA control service
#     4097     N/A        0    2 16414 DIAG service (MODEM:CNTL)
#       16       2        0    3    65 Location service (~ PDS v2)
```

`qrtr-lookup` answers, so AF_QIPCRTR works from userspace and the name service is
live. Node/port inventory (service → node):

```
1,2,3,4,5,7,8,9,10,11,12,15,16,17,18,21,22,23,24,25,26,29,33,34,36,41,42,43,47,
48,51,55,66,68,73,74,75,76,77,78,85,86,1071,5004  ->  node 3
49 (IPA control), 1024, 1059, 4096, 4097 (DIAG) ->  node 2
```

Service 3 = **NAS** is on **node 3**, so QManager's default device string
`qrtr://3` (`qmi_read.sh:82`) is the right one for this box. **No code change
needed for the node id.**

Also present in the base firmware (so `qmicli`'s own deps are satisfied):

| Need | Present on device |
|---|---|
| `libc` | glibc **2.31** (`/lib/libc-2.31.so`), `ld-linux-armhf.so.3` |
| `libglib-2.0`, `libgobject-2.0`, `libgio-2.0` | **2.62.0** at `/usr/lib` |
| arch | armv7l; the payload is ELF 32-bit ARM EABI5, `GLIBC_2.4` max symbol → compatible |
| vendor QMI bits (must not be confused with ours) | `/usr/lib/libqmi.so.1`, `libqmiservices.so.1`, `libqrtr.so.1`, `/usr/bin/qrtr-*`, `/usr/bin/qmi_ip_multiclient` — Qualcomm's **C** QMI, not libqmi-glib. `qmicli` needs *its own* `libqmi-glib.so.5` / `libqrtr-glib.so.0`, which the firmware does **not** ship (`dependencies/NOTICE:45-46`). |

Capacity: `/data` (`/dev/ubi2_0`) has **143 MB free**; the payload is 2.8 MB.

### 3c. What `dependencies/qmi/` actually is

`dependencies/NOTICE:30-61`:

- `bin/qmicli` — libqmi's CLI, **built by the project owner on 2026-10-13**, not
  vendor-supplied; armhf cross-build.
- `lib/libqmi-glib.so.5.10.0`, `lib/libqrtr-glib.so.0.0.0` — LGPL-2.1-or-later,
  shipped as separate replaceable `.so` files on purpose ("Do not fold them into a
  single statically linked binary").
- libc/glib/gio/gobject are deliberately **not** bundled — the base firmware has
  them.
- The owner's build tree also carries `qmi-band-helper`, `qmi-cell-lock-probe`,
  `qmi-nr-ncell-probe`; **none are shipped and QManager uses none of them**
  (`NOTICE:50-52`). Relevant here: `qmi-nr-ncell-probe` exists, so an NR-neighbour
  experiment is possible later, but it is not part of this fix.

### 3d. What the Live tab is asking for, and what it will never get

The Live range asks for `--nas-get-cell-location-info` (LTE serving + LTE
neighbour set) and `--nas-get-signal-info` (serving SINR), merged by
`neighbours_live_tick()`:

- **LTE neighbours: yes**, this is exactly the QMI NAS neighbour list.
- **NR neighbours: no.** `qmi_read.sh:236-249` states it and
  `docs/specs/neighbour-live-aim.md` "Out of Scope" repeats it: the `5GNR` section
  of that answer carries the NR **serving** ARFCN, not neighbours. NR neighbour
  rows would have to come from AT (`AT+QNWCFG="nr5g_meas_info"`), which the X16
  override worker already tries (`qmanager_neighbour_scanner:152-190`) — and on
  this unit that leg produced **zero** rows (the 09:11 result JSON is LTE-only).
  `docs/09-features.md:169` already records this as a known gap: *"the separate LTE
  neighbour scan is supported via native AT+QENG=\"neighbourcell\"; NR neighbour
  data remains unavailable."*
- So: deploying QMI gives a **live LTE neighbour view** (serving badge, band, DL
  MHz, Δ-RSRP, 1 Hz). It does **not** and cannot give live NR neighbours. Setting
  that expectation in the report to the customer matters.

### 3e. How the stock UI does it

It does not. The vendor web root is `/tzwww` (`/tmp/mini_httpd.conf: dir=/tzwww`),
served by `/bin/mini_httpd` on :80/:443. `grep -rl "neighbourcell\|QENG" /tzwww`
→ **nothing**; `grep -ril "neigh" /tzwww` → only `cgi-bin/http.cgi.bak` (a config
backup, not a neighbour view). There is **no vendor live-neighbour feature to
copy**, which is consistent with QManager's live view being our own feature
(`docs/specs/neighbour-live-aim.md`), not a parity port.

### 3f. Is an AT-backed live tick a viable alternative? No.

The X16 AT transport is `/bin/atcmd` → `atcmd_daemon`
(`deploy-x16/atcli_smd11:5-27`, `docs/09-features.md`, `docs/05-the-at-problem.md`):
one request at a time, **no timeout**, and `/bin/dialer` reboots the router after
repeated AT failures. A 1 Hz neighbour poll (`AT+QENG` ≈ 0.35 s raw, plus
`QNWCFG` + `sleep 1`) would sit on that single-request bus continuously and fight
the poller's own tier reads. QMI is on a different transport entirely, which is
why the feature was built on it. **Do not add an AT fallback.**

---

## 4. Deployed vs expected

| Path | Expected (code) | Deployed | Evidence |
|---|---|---|---|
| `/data/qmanager/lib/qmi_read.sh` | present | **present**, paths already rewritten to `/data/qmanager` | `grep` §2c |
| `/data/qmanager/bin/qmanager_poller` | has `neighbours_live_tick` | **present** | `/tmp/qmanager.log` "neighbours: live mode on" |
| `/data/qmanager/www/cgi-bin/.../neighbour_scan_status.sh` | `range=now`/`last` | **present** | deployed bundle contains `range=now` (`grep -rl "range=now" /data/qmanager/www/_next/static`) |
| `/data/qmanager/bin/qmanager_neighbour_scanner` | X16 AT override | **present**, AT scan works | 8-row result JSON |
| `/data/qmanager/bin/qcmd`, `jq`, `atcli_smd11` | present | **present** | `ls -la /data/qmanager/bin` |
| **`/data/qmanager/lib/qmi/bin/qmicli`** | present, `chmod 755`, real qmicli | **MISSING** | §1a |
| **`/data/qmanager/lib/qmi/lib/libqmi-glib.so.5(.10.0)`** | present | **MISSING** | §1a |
| **`/data/qmanager/lib/qmi/lib/libqrtr-glib.so.0(.0.0)`** | present | **MISSING** | §1a |
| `deploy-x16/install.sh` stages `dependencies/qmi` | yes | **no** | `install.sh:107-113` |
| any `qmi/` copy in this repo | — | **none** | `ls -d dependencies` → absent |

---

## 5. Fix plan (concrete, no investigation needed downstream)

### 5.1 The fix is one staging step + three files

**Change 1 — `deploy-x16/install.sh`, `build_payload()` (after line 113).**

```sh
    # libqmi CLI + its two private .so's: the Live neighbour range's only
    # transport. Upstream stages the same three files (deploy/README.md:157);
    # without them qmi_read.sh resolves to a path that cannot exist and the
    # poller logs "QMI unavailable — live view idle" once a minute forever.
    # LGPL-2.1: separate, dynamically linked, replaceable — do not amalgamate.
    mkdir -p "$STAGE_DIR/lib/qmi"
    cp -a "$QM_SRC/dependencies/qmi/bin" "$STAGE_DIR/lib/qmi/"
    cp -a "$QM_SRC/dependencies/qmi/lib" "$STAGE_DIR/lib/qmi/"
    chmod 755 "$STAGE_DIR/lib/qmi/bin/qmicli"
```

`cp -a` keeps the two symlinks (`libqmi-glib.so.5`, `libqrtr-glib.so.0`), which
`qmi_read.sh`'s `LD_LIBRARY_PATH` needs.

**Change 2 — `deploy-x16/install.sh`, `--install` chmod block (line ~266).**
The existing `find … -exec chmod 755` covers `bin/` and `www/cgi-bin/` only; add
`'$QM_ROOT/lib/qmi/bin'` to it (belt-and-braces; tar already preserves 755):

```sh
        find '$QM_ROOT/bin' '$QM_ROOT/www/cgi-bin' '$QM_ROOT/lib/qmi/bin' -type f -exec chmod 755 {} +
```

**Change 3 — `deploy-x16/install.sh`, `verify()` (after the `jq:` line, ~line 161).**

```sh
        printf "qmicli:     "; [ -x /data/qmanager/lib/qmi/bin/qmicli ] && echo present || echo MISSING
        printf "qmi live:   "; sh -c '. /data/qmanager/lib/qmi_read.sh; qm_qmi_available && echo available || echo unavailable' 2>/dev/null
        printf "qmi cells:  "; sh -c '. /data/qmanager/lib/qmi_read.sh; qm_qmi_neighbours' 2>/dev/null | head -c 160; echo
```

Expected: `present` / `available` / a `{"serving":…,"cells":[…]}` fragment.

**Change 4 — docs + module table.** `deploy-x16/README.md` (payload table, ~line 28)
gains a row for `lib/qmi/`; `docs/09-features.md` (Scanners row, line 48, and the
Known-gaps table, line 169) gets the corrected statement: *live neighbours work
over QMI on X16 (LTE only); NR neighbours remain unavailable*. One commit,
`fix(qmanager): ship the libqmi CLI so the live neighbour range works on X16`.

### 5.2 Alternative if shipping a binary is unacceptable (not recommended)

Rewrite `handle_range_now()` to serve the poller's AT-derived status file — but the
poller has no AT neighbour cache, so this becomes "one AT `QENG` read per CGI
request" (0.35 s+, ~1 Hz on the single-request `atcmd_daemon`, `dialer` reboot
risk). It also loses serving-cell identity, Δ-RSRP and the 1 Hz cost model the spec
measured. Reject; record the rejection rather than implement it.

### 5.3 What must NOT be touched

- `/usr/lib/libqmi*.so.1`, `/usr/lib/libqrtr*.so.1`, `/usr/bin/qrtr-*`,
  `qmi_ip_multiclientd`, `/dev/socket/data/*` — vendor QMI/IPA chain, unrelated to
  `qmicli` (which uses its own `libqmi-glib`). Do not replace or symlink these.
- `qmi_read.sh`'s `qrtr://3` and its `--dms-get-operating-mode` capability probe.
- The AT allowlist / `atcli_smd11` / `qcmd`.
- `dependencies/NOTICE` terms: keep the two `.so` files separate and dynamically
  linked.

---

## 6. How to verify (post-deploy, in this order)

```sh
# 1. files + version
ssh zlt-root 'ls -l /data/qmanager/lib/qmi/bin /data/qmanager/lib/qmi/lib;
              LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib /data/qmanager/lib/qmi/bin/qmicli --version'
# expect qmicli + 2 libs (+2 symlinks) and e.g. "qmicli 1.xx" / "libqmi 1.xx"

# 2. the modem answers over QRTR (the actual unknown of this plan)
ssh zlt-root 'cd /tmp && LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib \
  timeout 10 /data/qmanager/lib/qmi/bin/qmicli -d qrtr://3 --dms-get-operating-mode'
# expect "Operating mode retrieved:" -> "online"

# 3. the neighbour read itself
ssh zlt-root 'cd /tmp && LD_LIBRARY_PATH=/data/qmanager/lib/qmi/lib \
  timeout 10 /data/qmanager/lib/qmi/bin/qmicli -d qrtr://3 --nas-get-cell-location-info'
# expect "Successfully got cell location info" + LTE Info Neighboring Cells sections

# 4. the lib's own predicates
ssh zlt-root 'sh -c ". /data/qmanager/lib/qmi_read.sh; qm_qmi_available; echo avail=\$?; qm_qmi_neighbours"'
# expect avail=0 and {"serving":{...},"cells":[{...}]}

# 5. end-to-end through the poller: open the UI's neighbour page, pick "Live", then
ssh zlt-root 'cat /tmp/qmanager_neighbours_live.json'
# expect {"at":<epoch>,"registered":true,"carrier":...,"serving":{...},"cells":[3-8 rows]}
ssh zlt-root 'tail -5 /tmp/qmanager.log'   # expect "neighbours: live mode on" and NO "QMI unavailable"

# 6. cost on a 1-core box (the spec's ~4 % was measured on the O5A)
ssh zlt-root 'top -b -n 2 -d 5 | grep -E "qmanager_poller|qmicli" | tail -4'
```

Acceptance: step 2–5 succeed and the Live tab shows a serving row plus ≥1 LTE
neighbour with an age counting up. If step 2 or 3 fails, the deployment is correct
and the *transport* is the problem — see risks (§7) and report back rather than
patching around it.

---

## 7. Risks and unknowns

| Risk | Detail / mitigation |
|---|---|
| **QMI NAS may be gated for new QRTR clients** (the only real unknown) | `qrtr-lookup` shows NAS (service 3) on node 3 and the NS answers, but whether `--nas-get-cell-location-info` is permitted for a non-vendor client on this firmware is **UNKNOWN** until step 2/3 of §6 runs. Mitigation: the probes are read-only; if they fail, nothing has changed on the device except three unused files. |
| **`qmicli` was built for the O5A** | armhf EABI5, max `GLIBC_2.4` symbol, deps present (glib 2.62, gio 2.62, glibc 2.31). Low risk, but it is the same binary, not a rebuild — if it crashes with SIGILL, the source tree is `libqmi` upstream and a rebuild is the answer (`dependencies/NOTICE:32-38`). |
| **Run from a directory the loader can write** | `qmi_read.sh` already runs bounded (`timeout 5`) and reads through a file, so a wedged call cannot stall a poller cycle (`qmi_read.sh:141-181`). Do not "optimise" that away. |
| **1 Hz on one core** | Two `qmicli` spawns + a `jq` merge per second while a browser holds the lease. Spec measured ~4 % on the O5A and the UI copy claims ~7 % here. Verify with §6 step 6; the lease stops on its own when the tab closes (`NEIGHBOURS_LIVE_LEASE_SEC=10`). |
| **Disk** | 2.8 MB of `/data` (143 MB free). Trivial, but it is persistent — make sure `--uninstall`'s `rm -rf /data/qmanager` (§5, existing behaviour) still removes it (it does; the files live under the payload root). |
| **NR expectation** | Anyone expecting the Live tab to show 5G neighbours will be disappointed after this fix. State it up front: LTE only (`qmi_read.sh:236-249`, `docs/09-features.md:169`, `docs/specs/neighbour-live-aim.md` Out of Scope). |
| **Reboot survival** | Payload lives in `/data` (persistent, `/dev/ubi2_0`), so it survives reboot without any boot hook. The only boot-time concern here is that `qmanager-poller` must be up (it already is: `qmanager-guard.timer`). |
| **LGPL** | Keep `libqmi-glib.so.5.10.0` and `libqrtr-glib.so.0.0.0` as separate `.so` files; lgpl terms in `dependencies/NOTICE:54-58`. Do not statically link, do not fold. |
| **Do not diagnose with `dmesg -c`** | `AGENTS.md` §6: it clears the evidence ring buffer. |

### Open items marked UNKNOWN

1. Whether NAS `Get Cell Location Info` is authorised for an external QRTR client
   on this SDX65 firmware → resolved by §6 step 3.
2. The exact CPU cost of the 1 Hz tick on this 1-core device → resolved by §6
   step 6.
3. Whether the SIM8260E's QMI NAS neighbour set matches the AT `QENG` set (8 rows
   at 09:11). Expect a subset; do not "reconcile" the two into one table — the
   spec deliberately keeps one transport for rows and one for serving identity.
