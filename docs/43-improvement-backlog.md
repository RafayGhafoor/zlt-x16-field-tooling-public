# 43 — Improvement backlog from the vendor-binary work (and what shipped)

**Date:** 2026-10-29/30 · **Origin:** [38](38-atcmd-daemon-internals.md)–
[42](42-vendor-at-surface.md) · **Status:** P1 and P2 shipped and verified on the
unit; P3 items are decisions, not tasks, and one of them is a *no*.

This page exists so the reasoning behind five device changes survives in one place,
and so the next person does not re-derive "which of these is safe".

---

## 1. Shipped

| # | Change | Commit | Evidence |
|---|---|---|---|
| P1.1 | `atcli_smd11` handles the daemon's two non-modem replies: the `<path> ATCMD_DAEMON_FILE_OK` spill (read the file, never pass the sentinel up) and `Atcmd_daemon get At_Response Error` (→ `ERROR`) | `5048f91d` | new suite `tests/unit_atcli_sentinels.sh` (13 assertions) |
| P1.1b | **`AT+CFUN?` refused** by the allowlist, and removed from the cellular settings CGI's `;`-chain | `5048f91d`, `eca9978a` | on device: deployed chain answers in **0.41 s** with `+QUIMSLOT: 1 / mode_pref,NR5G / nr5g_disable_mode,1 / roam_pref,1 / +QSIMDET: 0,1`; `tests/unit_cgi_parsers.sh` +5 assertions |
| P1.2 | `router-fix/atcmd-guard/` — 1-minute timer that repairs a dead indication thread or a missing daemon, rate-limited, logged to `/data/log/zlt-atcmd-guard.log` | `d790bb44` | forced recovery on device: `RESTART … kill -9 + start_atcmd_daemon` → new pid, `fd 5 → /dev/smd8`, `fd 6 → /dev/smd9`, `AT` OK, route + ping unchanged, daemon survives the oneshot cgroup; `tests/unit_atcmd_guard.sh` (8 assertions) |
| P1.3 | Diagnostic capture of `/proc/<atcmd_daemon>/fd`, the vendor log tail, `/tmp/.sockmsg` and `/tmp/.tmpsock` | `589bc1d6` | fragment run on the unit; both `zlt_x16_diagnose.py` and `docs/recon-x16.sh` |
| P1.4 | **Correction, not a fix** — see §2.3: the config credentials are plaintext, not hashes | this page | md5 comparison of `mdlcfg -e` against the documented stored value |
| P2 | `scripts/at-probe/` — read-only `sn` / `reboot` / `nv` / `health` | `060240a6` | run on the unit: SN `<module-sn-redacted>`, `+CFAILUREMGRCFG: 1,2,60,1800,5,3,120,1800,5,0,0`, `+CBACKUPRESULT: 1`, `+CRESTORECOUNT: 0` |

## 2. Findings that changed the plan

### 2.0 The guard's first deploy broke its own boot hook — and the fix is a rule

Worth recording first, because it was self-inflicted and `sh -n` cannot catch it.

The module inserts a line into `/etc/initscripts/StartTZApp`, and "at the top" was
implemented literally: the comment + hook went **above** `#!/bin/sh`. systemd runs
that file directly — `start_cfgd.service: ExecStop=/etc/initscripts/StartTZApp stop`
and TZApp runs it with `start` — so line 1 no longer being `#!...` means `execve()`
returns **ENOEXEC** and every hook in that file stops running: ssh, firewall tuning,
TTL, the IPACM wiring, the call bridge. The file still parsed, so `sh -n` said yes.

Fixed two ways: the boot wiring now lives in a **device-side controller**
(`router-fix/atcmd-guard/hook.sh install|remove|check`) instead of a nested ssh
string — the same shape `router-fix/ttl-normalise` uses, for the same reason — and
`tests/unit_atcmd_guard.sh` asserts the rule (6 assertions, including "install
repairs a file whose shebang was pushed off line 1" and "check refuses it").

**And a second way to break the same file, found on the same day:** rewriting it with
`{ … } > f.new && mv f.new f` leaves the new file at the umask default — **644** — while
`StartTZApp` is **755** because systemd `execve`s it. Both of my controllers called
`chmod --reference="$F" "$F.new" 2>/dev/null || true`, and **this busybox has no
`--reference`**, so the chmod silently did nothing. `StartTZApp` sat at 644 from 22:2x
until a pre-reboot audit caught it; `settings.sh` (a CGI, also 755) lost its bit the
same way at 22:0x. Both restored, both controllers now capture the mode with
`stat -c %a` and re-apply it, and both `--check`s assert `-x`.

**Rule:** inserting anything into a vendor script means "first executable line". If
a module's `--check` does not assert `head -1 == #!...` **and** `-x`, it is not
checking the two things that break boot.


### 2.1 `AT+CFUN?` was live, in a page, and in our own allowlist

The refreshed AGENTS.md §6 recorded that `AT+CFUN?` hangs. Two places were still
sending it, and one of them was ours:

- `deploy-x16/atcli_smd11` **allowed** it (`is_safe_cmd`), so any caller could wedge
  the channel by asking the "right" question;
- `qmanager/.../cellular/settings.sh` had it **inside a `;`-compound**, so one dead
  command took the whole chain's answer with it. `qcmd` holds
  `/tmp/qmanager_at.lock` for the duration, which means the hang was paid by the
  poller, the calls bridge and every other CGI — they cannot even see why.

The deployed copy carried it (2 occurrences in `/data/qmanager`). Both are fixed;
the functional mode is now an explicitly *assumed* 1, logged as such, with a note
that an honest value would come from QMI `--dms-get-operating-mode` (`docs/36`),
which has no AT equivalent.

### 2.2 Something already respawns `atcmd_daemon` — but not its URC thread

Killing the daemon (`kill -9`) brought a new one back in **~2 s**, with `ppid=1` and
the vendor's `/tmp/logs/EXE_DAEMON.log` inherited on its fd table. So the vendor does
have a supervisor (`exe_daemon`), which is why nobody noticed the daemon being
fragile.

Two consequences, both in the shipped guard:

- the guard's "process absent" trigger is a **safety net**, not the common case;
- the failure only a guard can catch is the one where the **process stays alive**
  and its indication thread dies (§1 of doc 38). That is the whole point of the
  `/dev/smd9` fd check.

Measured detail that the first version got wrong: a restarted daemon takes **1–2 s**
to open `/dev/smd9` after the pid appears (it opens `/dev/smd8`, reads
`SYS_VOLTE_SW`, then starts the reader). The guard judged on the pid alone and
logged `PARTIAL` on a recovery that had actually worked; it now waits up to 3 s for
the fd before deciding.

### 2.3 P1.4 was wrong: the config credentials are **plaintext**, not hashes

The hypothesis was that the "credential hashes" in `device-etc/` are
`util_replace_encode_decode` output — a keyless, reversible permutation
([41](41-vendor-crypto-lib.md) §2). The measurement says something simpler and worse:

```
$ mdlcfg -e | grep USR_WLAN2G_PASSWORD_0     ->  <wlan-psk-redacted>     (8 chars)
md5(<wlan-psk-redacted>) == md5(the value mdlcfg -e prints)
```

`mdlcfg -e` is **"export the config"**, not "decrypt": for this key it returns the
stored value byte-for-byte. So:

- the WLAN PSKs are **stored in clear** and are fleet-wide (`docs/19` V4 already
  said `<wlan-psk-redacted>` is identical on all four radios) — there is no encoding step to
  reverse and no key to steal;
- the AGENTS §7 phrase "credential *hashes*" is wrong and has been corrected: the
  snapshots in `device-etc/` are **plaintext-equivalent secrets**, so the existing
  "keep this repository local, scrub before pushing" rule is the *minimum*, not a
  precaution;
- whether *any* config item is encoded by `libmdlencrypt` is now unproven and not
  worth chasing — the exposure is already total for the values that matter.

### 2.4 The spill threshold is 8192 bytes, not 3980

`atcmdd_send_atcmd` is called with a buffer size that differs by caller: **0x2000
(8192) for CLI replies** (`id == 0xea60`, i.e. `/bin/atcmd`) and **0xf8c (3980) for
bus callers**. Doc 38 §3 quoted the bus figure; for us the CLI figure is the one
that applies. Neither is a problem today (every command we issue is small, and the
big ones are banned in AGENTS §6), which is why the shim fix is a guard against
future us rather than a live repair.

## 3. Deliberately not done (P3)

| Item | Why not, and what it would take |
|---|---|
| **IMS/VoLTE state from the SIMCom SDK** (`Sunsea_NW_GetIMSStatus`) | The only honest source — there is no AT equivalent ([40](40-simcom-sdk-interface.md) §1). It needs a small helper that `dlopen`s `libolinterface`, exactly the pattern `router-fix/voip-bridge/x16-audio.c` already proves. Do it when the Calls page needs to state "VoLTE registered" instead of inferring it. |
| **USSD over the daemon's `/tmp/.ussd_*` handshake** | Greenfield: QManager has no USSD feature at all, so this is a product decision, not a transport one. The protocol is decoded ([38](38-atcmd-daemon-internals.md) §6): `/tmp/.ussd_ret` holds the reply hex-encoded four nibbles per char, `/tmp/.ussd_need_reply` holds `0/1/2`. Note the files live in a world-writable directory — a feature built on them inherits that. |
| **Migrate the remaining 1 Hz polling from AT to QMI** | Already the default: AGENTS §3 records `scripts/qmi-probe` as the preferred backend for every `qmi_read.sh` read, with qmicli then AT as fallbacks. Nothing to change; this page only adds the reason (the vendor's own apps never use AT for data — [40](40-simcom-sdk-interface.md)). |
| **`AT+CFAILUREMGRCFG=0` (disable the modem-reboot policy)** | A **write** to modem policy. It would convert "reboots when the modem is unhappy" into "stays up, degraded" — which contradicts the recovery `docs/29` measured and would hide the fault the customer is reporting. Reads are free (`scripts/at-probe reboot`); the write needs a customer decision and a rollback plan, and I recommend against it. |
| **MobileAP WWAN statistics from the SDK** (`Sunsea_MobileAP_GetWWANStatistics`) | Same shape as the IMS item, lower value: per-interface counters we can already get from `/proc/net/dev`. Revisit only if a data-usage page needs per-bearer numbers. |

## 4. The "don't do this" list (P4)

Each of these is now *evidence-backed* rather than folklore; the pointer is what to
read before disagreeing.

| Don't | Why | Where |
|---|---|---|
| Build our own `sockmsg` AT client | the reply path is fixed, `listen(1)`, 5 × 100 ms retry; two concurrent callers cannot both work | [39](39-sockmsg-bus.md) §2, [38](38-atcmd-daemon-internals.md) §2 |
| Treat `/bin/dialer`'s command strings as a command list | `AT+SPENGMD=0,5,2` answers `ERROR` on this firmware, and `AT+CSYSSEL=?` is in those strings despite hanging | [42](42-vendor-at-surface.md) §3 |
| Rely on URCs for anything that matters | the indication thread can die silently while AT keeps answering — poll, or watch the fd | [38](38-atcmd-daemon-internals.md) §1 |
| Issue `AT+CFUN?`, `AT+CLAC`, `AT+CNBP?`, `AT+CSYSSEL=?` | all hang; the first was in our own allowlist until `5048f91d` | AGENTS §6, [42](42-vendor-at-surface.md) §3 |
| Write NV through AT (`AT+CNVW=`, `AT+CNV=<path>,…,<hex>,<len>`, `AT+MODULE_SN`) | unauthenticated write primitives; NV cannot be reinstalled from any vendor package | [42](42-vendor-at-surface.md) §1, [17](17-backups-and-restore.md) |
| Touch `AT+SPIMEI` (IMEI write), `AT+CLCK`/`AT+CPWD` (SIM lock/PIN) | unrecoverable device identity | [42](42-vendor-at-surface.md) §3 |
| Assume the config's "credential hashes" are hashes | measured: `mdlcfg -e` returns the stored value unchanged; the PSKs are plaintext and fleet-wide | §2.3 above |

## 5. What is still open

| Item | Note |
|---|---|
| `libmdlbase.so` (`osm_requester`, under `libolinterface`) | the last unread library in the modem path ([38](38-atcmd-daemon-internals.md) §9) |
| Who owns the `groups` pseudo-app id (3) | nothing on the box binds it ([39](39-sockmsg-bus.md) §3) |
| `qmi-probe`'s SCell **DECONFIGURED** state (an in-flight change in the tree) | once `watch` emits it, `scripts/flap-meter/analyze.sh` must type `:x` as an `scc-set` (a *release*), not an `scc-state` — otherwise the counts get worse, which is the opposite of the fix. Its test fixtures use only `:act` today, so the gate cannot catch it. |
