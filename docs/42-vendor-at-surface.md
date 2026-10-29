# 42 — The vendor's AT surface: what `/bin/dialer` actually sends

**Date:** 2026-10-29 · **Device:** X16, `zlt-root` · **Trigger:** pulling the AT
command strings out of `/bin/dialer` (1 090 880 B, stripped, `.symtab` present)
after [38](38-atcmd-daemon-internals.md) showed the daemon side of the channel.

`docs/04` maps the commands **QManager issues**; this page is the complement —
the commands the **vendor's own code** issues, which is where the undocumented
surface lives. Everything below is either **[E]** (a string in the binary) or
**[M]** (a live read-back on the unit, read-only).

---

## 1. The NV family — this is the part worth having

Three distinct NV primitives, all reachable over AT **[E]**:

| Command | Shape | What it is |
|---|---|---|
| `AT+CNVR=<item>,0` | read | read NV item by **number**, answer is hex |
| `AT+CNVW=<item>,<idx>,<hex>` | write | write NV item by **number** (this is what `atcmd_daemon` emits for `AT+MODULE_SN`, [38](38-atcmd-daemon-internals.md) §4.1) |
| `AT+CNV=<efs-path>,<op>[,<hex>,<len>]` | read/write | NV item by **EFS path**, e.g. `AT+CNV=/nv/item_files/wcdma/rrc/wcdma_rrc_fast_return_to_lte_after_csfb,0,01,1` |

The dialer reads exactly four numbered items at runtime. Measured on this unit
**[M]** (read-only; each answered in ms and the channel stayed healthy):

| NV item | Response payload (hex → decoded) | Reading |
|---|---|---|
| **2497** | `4D5030363234303335334244423043` + zeros → **`<module-sn-redacted>`** | **the module serial number**: 15 bytes, exactly the length `set_module_sn_atcmd` demands, and the item that command writes |
| 3180 | `98A942862176` + zeros | 6 bytes — <mac-redacted>; **meaning unconfirmed** (MAC-shaped) |
| 4678 | `5C46B0AC7096` | 6 bytes — <mac-redacted>; **meaning unconfirmed** (MAC-shaped) |
| 6860 | `53322D3130444345` + zeros → **`S2-10DCE`** | 8 characters in a padded slot; looks like a board/SKU code, **unconfirmed** |

**This closes the loop from [38](38-atcmd-daemon-internals.md) §4.1**: NV 2497 is
the module SN, it is 15 raw bytes, and `AT+CNVR=2497,0` is its **read**
counterpart. Consequences:

- nobody needs to *write* `AT+MODULE_SN` to get the SN — one documented read does it;
- the write remains an unauthenticated NV write, so it stays on the do-not-touch
  list, with the EFS backup requirement in [17](17-backups-and-restore.md);
- the SN is now available to the UI/API without any NV access tool (see §6).

The `AT+CNV=<efs-path>` form is the interesting one for the modem work in
[33](33-modem-nv-and-ul-capability.md)/[36](36-qmi-direct-probe.md): it addresses
NV **by path**, which is what `scripts/efs-nv/` does over DIAG. It has not been
exercised here beyond reading the dialer's own literal, and it is a *write*
capable primitive — treat it with the same care as `qcom-efsd`.

## 2. The reboot policy is readable: `AT+CFAILUREMGRCFG?`

`docs/29` and `docs/05` describe the dialer rebooting the router after repeated AT
failures. The policy is a modem setting, and it can be read **[M]**:

```
AT+CFAILUREMGRCFG?   ->
+CFAILUREMGRCFG: 1,2,60,1800,5,3,120,1800,5,0,0
OK
```

Field names are not documented in the binary (the dialer only has the
`%d,%s` setter and the bare query **[E]**), so read it as: enabled (`1`), then two
trigger groups — `(2, 60, 1800, 5)` and `(3, 120, 1800, 5)` — and two trailing
zeros. Two groups matches the **two watchdogs** measured in
[29](29-wan-drops-and-band-switching.md); do not over-fit the individual numbers
until the field order is confirmed against a controlled change.

Two related strings in the dialer **[E]**, which define when it *won't* reboot:

```
[dialer] %s: Dialer reboot system cause AT send failed more than %d times.
[dialer] %s: Dialer can not reboot cause in mix WAN mode (%d) WAN priority(%s)...
[dialer] %s: Dialer reboot system cause modem unormal detected.
```

So there are **two independent reboot triggers** (AT-failure count, and "modem
abnormal"), and the AT one is **suppressed in mixed-WAN mode**. On a unit with a
wired WAN present, that suppression changes the failure mode from "reboots" to
"stays up with a dead modem", which is worth keeping in mind when diagnosing a
box that is up but offline.

## 3. The full surface, by family

Read-only / status **[E]**:

```
AT AT+CSQ AT+CESQ AT+CEREG? AT+CPSI? AT+CRSSI? AT+COPS? AT+CPIN? AT+CIMI
AT+CICCID AT+CGSN-ish (AT+SIMEI?) AT+CNUM AT+CLCC AT+CGACT? AT+CGDCONT?
AT+CGCONTRDP[=1] AT+CGAUTH? AT+CGPADDR AT+CCAINFO? AT+CNWINFO? AT+CBACKUPRESULT
AT+CRESTORECOUNT AT+SPCAPABILITY=53,0 AT+SPIC AT+VOLTESETTING? AT+CFAILUREMGRCFG?
```

Engineering/status soup (`SPENGMD` — vendor-private) **[E]**:

```
AT+SPENGMD=0,0,6   AT+SPENGMD=0,0,7   AT+SPENGMD=0,5,2   AT+SPENGMD=0,6,0
AT+SPENGMD=0,6,1   AT+SPENGMD=0,6,6
```

`0,5,2` is the RSSI page (`"(AcT=%d) ==> rssi(%sdBm)"` in the dialer's own
formatting) — and on this unit it **answers `ERROR`** **[M]**, so the dialer's
strings are a superset of what this firmware accepts. Do not assume a string in
`/bin/dialer` is a command this modem honours.

Write / policy (all **[E]**, none issued by us):

```
AT+CNVW=<item>,…                  NV write by number
AT+CNV=<path>,…                   NV write by path
AT+SPIMEI=0,"%s"                  IMEI write  (!)
AT+CFUN=1 / AT+CFUN=4             modem reset / RF off
AT+CLCK="SC",%d,"%s" / AT+CPWD    SIM lock / change PIN
AT+COPS=%d,2,"%s"[,%d]            manual PLMN
AT+CNMP=%d                        mode preference
AT+CSYSSEL="nr5g_disable",%d      NR disable
AT+CSYSSEL=%s                     band policy
AT+CCELLCFG=1,%s,%s / =0          LTE cell lock / unlock
AT+C5GCELLCFG="pci",%s,%s,%d,%d   NR cell lock
AT+C5GCELLCFG="unlock"
AT+CMCFG="autoselect"|"list"|"deactive",%s    carrier/network selection mode
AT+CGDCONT=… AT+CGAUTH=… AT+CGACT=…           PDP profile
AT+CUSD=1,"%s",15 / AT+CUSD=2     USSD send / cancel
AT+CAVIMS=0|1                     IMS/VoLTE on/off
AT+VOLTESETTING=%s                VoLTE settings
AT+SFUN=2|3|5                     SIM/function control
AT+SPCONFIGSIMSLOT=%s             SIM slot config
AT+CNWSEARCH="lte",120 / "nr5g",3 network scan (blocking)
AT+SPNCELLSCAN=%s                 neighbour scan
AT+CNDISFLOW AT+SPURSPEVA=8, AT+SPIC   flow/power/IC
```

Note what this list implies about **our** usage: every write we might want is in
the lower half — and `AT+SPIMEI` (IMEI write), `AT+CNVW`/`AT+CNV` (NV write) and
`AT+CLCK`/`AT+CPWD` (SIM lock/PIN) are the three families [17](17-backups-and-restore.md)
and [33](33-modem-nv-and-ul-capability.md) say must not be touched without a
verified rollback. Nothing here changes that.

> **`AT+CFUN?` — the read form — is not usable here.** It **hangs** on this
> firmware ([AGENTS](../AGENTS.md) §6, killed at 20 s with no reply), the same
> class as `AT+CSYSSEL=?`. So the write forms above are the only CFUN access: "what
> functional mode is the modem in" has to come from `AT+CPSI?`/`AT+CEREG?` or QMI
> ([36](36-qmi-direct-probe.md)), never from an AT query. `AT+CFUN=` does appear in
> [38](38-atcmd-daemon-internals.md) §5 — that is the daemon's `strstr` on the
> **command text** it is asked to send, not a query by the daemon itself.

## 4. What we can use tomorrow (all read-only)

| Use | Command | Status |
|---|---|---|
| Show the module serial number in the UI/API | `AT+CNVR=2497,0` → hex → 15 chars | **[M]** works, ms, no NV write |
| Read the modem reboot policy | `AT+CFAILUREMGRCFG?` | **[M]** works — closes the "what is the watchdog policy" gap in doc 29 |
| Read an NV item by EFS path | `AT+CNV=<path>,0` | **[E]** present in the dialer; not exercised |
| Read a numbered NV item | `AT+CNVR=<item>,0` | **[M]** for 2497/3180/4678/6860 |

If the SN is added to QManager, it belongs behind the existing AT shim
(`deploy-x16/atcli_smd11`) with the usual serialisation, and it must be cached like
the other slow-changing values — one extra AT command per poll is exactly the cost
[34](34-at-shim-cost.md) argued against.

## 5. Traps reconfirmed here

- `AT+CSYSSEL=?` appears in the dialer's strings, but [AGENTS.md](../AGENTS.md) §6
  and [05](05-the-at-problem.md) record it as a **hang risk**. Do not issue it
  because the vendor appears to; their call site may be behind a build flag.
- `AT+SPENGMD=0,5,2` → `ERROR` on this firmware (§3) — a reminder that the dialer
  targets several products (the SDK paths in [40](40-simcom-sdk-interface.md) say
  `SDX65_LE12`, [39](39-sockmsg-bus.md) says `sunsea-x62`).
- Every command in this page went through `/bin/atcmd` → `atcmd_daemon`, i.e. the
  serialised path, bounded with `timeout -s KILL`, with an `AT` sanity check
  afterwards. The four NV reads and the one policy query cost ~1 s of channel time
  each and left no state behind.

## 6. Reproduce

```sh
# the whole surface, from the binary
strings -a firmware-analysis/dialer | grep -E '^AT\+' | sort -u

# what it means for a specific command
strings -a firmware-analysis/dialer | grep -n 'CFAILUREMGR\|SPIMEI\|CNV'

# the live read-backs (read-only; each is bounded and followed by a sanity AT)
ssh zlt-root 'timeout -s KILL 20 /bin/atcmd "AT+CNVR=2497,0"'
ssh zlt-root 'timeout -s KILL 20 /bin/atcmd "AT+CFAILUREMGRCFG?"'
ssh zlt-root 'timeout -s KILL 10 /bin/atcmd AT'
```
