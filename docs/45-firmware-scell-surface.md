# 38 — Looking for an LTE CA/SCell control inside the firmware

**Question:** the network's SCell management causes the churn (`docs/44`). Is there a
knob in the firmware — NV/EFS or a vendor QMI service — that turns LTE CA off or
pins it?

**Answer: not in EFS, and not in any standard QMI service.** Two leads remain, both
outside what has been read so far (vendor QMI services, modem code). Method and
evidence below, so the next session does not repeat the search.

---

## 1. EFS: nothing for LTE CA

Read live and read-only over DIAG/QRTR (`scripts/efs-nv/`; the helper answered
`{"transport":"qrtr 3:34","readonly":true}`):

| Path | Contents |
|---|---|
| `/nv/item_files/modem/lte` | `ML1`, `rrc` — no CA directory |
| `/nv/item_files/modem/lte/rrc` | `cap`, `efs` |
| `/nv/item_files/modem/lte/rrc/efs` | `irat_sib_freq_list` (324 B), `nr5g_fp_db` (1444 B) |
| `/nv/item_files/modem/lte/rrc/cap` | `diff_fdd_tdd_fgi_enable` (1 B, `0x01`) |
| `/nv/item_files/modem/lte/ML1` | `lte_ml1_l2nr_search_optimization` (2 B) |

That is the **entire** LTE RRC/ML1 surface: five items, none about carrier
aggregation. Compare `modem/mmode` (~30 policy items we already use: `lte_bandpref`,
`nr_band_pref`, `mode_pref`, …). So there is no "disable CA" or "SCell preference"
NV item on this firmware — the churn cannot be switched off in NV.

## 2. NR *is* controllable — and it is not our churn

`/nv/item_files/modem/nr5g/RRC`:

```
cap_add_bw                                    NR CA additional bandwidth
cap_control_nrca_3x_f_plus_t_band_combos      6 bytes, 01 01 01 01 01 01
cap_dss_control                               dynamic spectrum sharing
epsfb_blacklist_backup
failure_mgr_efs_list_cfg
```

`cap_control_nrca_3x_f_plus_t_band_combos` is a six-flag capability bitmap (NR-CA
"3x F+T band combos"), all enabled. Per `AGENTS.md` §6 capability items can only
**downgrade**, so this is a real NR-CA lever: clear flags and the modem stops
offering those combinations.

Irrelevant today, twice over: the churn is **LTE** SCell management, and
`endc_available` is 0 so no NR leg exists. It is the first thing to look at if NR
is ever enabled and its CA then flaps.

## 3. QMI services: 43 served, 10 outside the documented range

`qmi-probe sweep` asks the QRTR nameservice for every id 0x01–0xFF:

```
standard       : 0x01 WDS  0x02 DMS  0x03 NAS  0x04 QOS  0x05 PDS  0x07 VOICE
                 0x08 CAT  0x09 WMS  0x0A UIM  0x0B WDA  0x31 IMSP  0x33 IMSVT
unnamed        : 0x0C 0x0F 0x10 0x11 0x12 0x15 0x16 0x17 0x18 0x19 0x1A 0x1D
                 0x21 0x22 0x24 0x29 0x2A 0x2B 0x2F 0x30 0x37
above 0x3A     : 0x42 0x44 0x49 0x4A 0x4B 0x4C 0x4D 0x4E 0x55 0x56
```

The unnamed ids in 0x0C–0x37 are mostly services newer libqmi knows and our 1.34
does not. The **ten above 0x3A are the real unknown**: vendor services. Any
undocumented CA/SCell *set* control would live in one of them.

Next step, and it needs no IDL: send each unknown service its
`Get Supported Messages` request (id `0x001F` or `0x0021`, varies by service) and
dump the returned message-id list. A CA setter would show up as an id adjacent to a
known CA getter, or simply as a message NAS does not have.


## 5. "Get Supported Messages" is not implemented — and QMI has no CA setter

Two follow-ups, both run on 2026-10-29, both negative, and both worth recording so
nobody re-runs them.

**Every service refuses message 0x001E** (`Get Supported Messages`, the same id in
nas/dms/wds/voice/uim per libqmi's IDL):

```
0x03 NAS  -> result=1 error=0x0047  invalid-qmi-command
0x30      -> result=1 error=0x0039  invalid-message-id
0x33 0x42 0x44 -> result=1 error=0x0039  invalid-message-id
0x37      -> result=1 error=0x0003  internal
0x31      -> no reply (timed out; it is the AP-side instance, node 2)
```

So the vendor services cannot be inventoried remotely: the firmware implements no
message-list query. Learning what they do needs the modem image, host-side.

**QMI has exactly one carrier-aggregation message in its whole IDL**, and it is a
getter:

```
grep '"name".*"CA Info|Band Combination"' data/qmi-service-*.json
  -> nas: "Get LTE Cphy CA Info"   (0x00AC)
```

There is no `Set CA`, no band-combination write, no SCell control in the standard
QMI surface — which is consistent with the 3GPP model in `docs/44` §1: what gets
aggregated is the network's decision, reported to the UE, not configured by it.

**Conclusion for the original question:** an LTE CA/SCell off-switch does not exist
on any reachable surface of this device — not EFS (§1), not the documented QMI
services (§3, §5), not through the vendor services we can query. The only lever that
changes which carriers the network may aggregate remains band policy, which is what
`docs/44` §4 already proposed as the experiment.

## 4. The method that does not work here

Binary-grepping `/firmware/image/modem.b*` (130 MB) **on the device** fails twice
over: `modem.b24` (39 MB) contains no `/nv/item_files/...` strings at all, and the
attempt drove the 1-core box to load 9 for minutes. Image work belongs on a host —
pull one segment and run `strings`/`radare2` there.

That is also the less useful source: the EFS inventory above is what the modem
actually reads. Image analysis only earns its cost if the question becomes *which
code path* implements something (e.g. locating the handler for a vendor service),
which is a much larger job than this question warrants.

---

## 6. Deeper QMI pass: what the firmware will actually tell you

After the CA question was closed, the services that describe *why* things happen
were queried read-only with `qmi-probe raw <service> <msg>`. Results, with the
message ids taken from libqmi's IDL (not guessed):

| Service | Message | Result |
|---|---|---|
| DSD `0x2A` | `0x0024` Get System Status | **works**, 596 B |
| DSD `0x2A` | `0x0033` Get APN Info | refused, `0x11` missing-arg (needs input TLVs) |
| PDC `0x24` | `0x0024` List Configs | OK but **empty** — reports no configs at all |
| PDC `0x24` | `0x0022` Get Selected Config | refused, `0x11` missing-arg |
| SAR `0x11` | `0x0002` RF Get State | OK, state `0` (enum is vendor-numbered, no meaning attached) |
| NAS `0x03` | `0x001E` Get Supported Messages | refused, `0x47` invalid-qmi-command |
| vendor `0x30 0x33 0x42 0x44` | `0x001E` | refused, `0x39` invalid-message-id |

`DSD Get System Status` is the useful one. Its TLV `0x10` (Available Systems)
decodes with the IDL as one entry:

```
technology = 0 (3GPP)   rat = 3 (LTE)   so_mask = 0x11000
```

i.e. the modem's own view of what it can serve matches reality. The same reply also
carries TLVs `0x11`/`0x13` that the IDL does not define for this message and that
contain **APN strings** — which led to the finding below.

### The APN surface has three different carriers on it

| Source | APN |
|---|---|
| `AT+CGCONTRDP` (the live bearer, cid 6, 10.220.234.83) | **`Ufone.internet`** |
| `mdlcfg -g USR_APN_NAME` | `Ufone.internet` |
| DSD Get System Status TLVs | **`connect.mobinkworld.com`** (Jazz/Mobilink) |
| `AT+CGDCONT?` cids 1–5 | `GPRS.SWISSCOM.CH`, `HOS`, `event.swisscom.ch`, `IMS`, `SOS` |

So the firmware ships **Swisscom-derived default PDP profiles**, the dialer sets the
real APN at cid 6, and DSD reports a third (Mobilink) one from somewhere we have not
located — most likely a SIM-provided or availability table rather than the active
context, since the bearer demonstrably runs on cid 6.

Nothing here is the outage cause, but two things are worth knowing:

- the Swisscom/HOS/event.swisscom.ch contexts are **inherited firmware defaults** on
  a Pakistani SIM. If a fallback ever selects cid 5 or 1, the dial fails for an APN
  reason that has nothing to do with the network.
- DSD's APN is not the bearer's APN, so **do not read the APN from DSD** when
  diagnosing a failed dial — read `AT+CGCONTRDP` (live) or `USR_APN_NAME` (configured).

### Sweep range, for the record

`qmi-probe sweep` covers service ids `0x01–0xFF`. Several libqmi services live above
it — `OMA` `0xE2`, `FOX` `0xE3`, `GMS` `0xE7`, `GAS` `0xE8`, `ATR` `0xED`,
`SSC` `0x190` — so "43 services" is **everything up to 0xFF, not everything the
modem serves**. Extending the sweep to `0x1FF` is a one-constant change if a later
question needs those (FOX, for instance, exposes `Get Firmware Version` at
`0x555E`).
