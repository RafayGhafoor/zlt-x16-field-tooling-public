# 46 — Switching to ROW_Commercial: attempted, not possible on this firmware

**Request:** move the modem's MBN/PDC profile to `ROW_Commercial`.
**Result: cannot be done on this unit** — the MBN surface is non-functional at both
layers, and nothing was changed by the attempt.

This page records the evidence so the next person does not repeat it, and corrects
two earlier notes that say `ROW_Commercial` is active.

---

## 1. What was there to begin with

The 2026-09-01 session left the packages on the box:

```
/data/zlt-mbn-recovery/mbn/ROW_Commercial.mbn      48436 bytes
/data/zlt-mbn-recovery/mbn/W_One_Commercial.mbn    44240 bytes
/data/zlt-mbn-recovery/bin/  + lib/                (the qmicli used then)
```

`docs/15` says "MBN untouched (`ROW_Commercial` still active from the 2026-09-01
session)", and `docs/12` says "`W_One_Commercial` was worse; `ROW_Commercial`
restored the original behaviour". Today's measurement contradicts the first:
**no software (MBN) config exists on the modem at all.**

## 2. The three layers, measured 2026-10-29

### AT — the path the vendor's own dialer is coded for

`strings /bin/dialer` shows the dialer issues exactly these, and carries error
strings for each (`[AT+CMCFG="autoselect",1] failed`, …):

```
AT+CMCFG="list"       AT+CMCFG="autoselect"       AT+CMCFG="deactive",%s
```

Live, through the shim:

```
AT+CMCFG="list"        -> ERROR
AT+CMCFG="autoselect"  -> ERROR
```

So the vendor's own MBN mechanism is not implemented on this firmware. (This is the
`+CMCFG` command `docs/04` maps as the SIMCom replacement for `+QMBNCFG`; the
mapping was right, the firmware does not answer.)

### QMI PDC — platform works, software is empty

```
--pdc-list-configs=platform   -> 2 configs, "SS-Olympic", one Active, one Inactive
--pdc-list-configs=software   -> empty (and qmicli 1.34 SEGFAULTS on the empty reply)
--pdc-load-config=/data/zlt-mbn-recovery/mbn/ROW_Commercial.mbn
                              -> segfault, "Uploaded 0 of 48436",
                                 "couldn't load config: InvalidQosId"
```

The load failed on its **first chunk** — zero of 48 436 bytes left the host — so the
modem was never touched and nothing needed rolling back. The data call stayed up
(`ping` ok, poller active) and was verified immediately after.

### A protocol detail worth keeping

`List Configs` answers through an **indication**, not an inline response: a
single-shot raw request (`qmi-probe raw 0x24 0x0024 …`) returns OK with no configs,
while qmicli — which registers the indication handler — gets the two platform
configs. That asymmetry explains "the probe says empty but qmicli says two", and it
means **PDC cannot be driven by the probe's one-shot transact**; it needs an
indication listener. (Not worth building unless PDC becomes usable for software
configs, which it is not.)

## 3. What this means

- **There is no path to `ROW_Commercial` on this build**: `+CMCFG` errors, PDC
  software has nothing loaded and refuses the upload.
- Because nothing uploaded, **there is no rollback to perform** and no risk was
  taken. Had it worked, the rollback was `--pdc-deactivate-config=software,<ID>`
  (returning to today's state: no software config) with the `.mbn` files preserved
  in `/data/zlt-mbn-recovery/mbn/`.
- It does not matter for the symptoms anyway: `docs/12` §3c already established that
  **no MBN swap improves the bearer behaviour** — `W_One_Commercial` made it worse
  and `ROW_Commercial` only restored the previous state.
- If a future firmware adds PDC software support, the attempt is one command with
  the `.mbn` already on the box; that is the only reason to keep them.

## 4. Correction to earlier notes

`docs/12` §3c and `docs/15` both describe `ROW_Commercial` as the active profile.
That was the conclusion of the September session and is no longer observable: on
2026-10-29 the modem reports **no software PDC configs**. Either the store was
reset since (firmware reflash, vendor `autoselect` attempt), or those sessions
operated on a layer that is not the PDC software type. Do not treat "ROW_Commercial
is active" as current fact.
