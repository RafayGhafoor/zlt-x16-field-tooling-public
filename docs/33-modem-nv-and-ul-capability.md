# 33 — Modem NV: what is actually set, and what optimisation headroom exists

Measured 2026-10-28 on the live unit (Ufone / 410-03) using
`scripts/efs-nv/` over **DIAG on QRTR node 3**. Read-only throughout; a
sha256-verified backup was taken first (`scripts/efs-nv/backup.sh`).

This page exists because "can we tune NV to get more upload / more CA?" is a
recurring question, and the answer is mostly *no* — for a structural reason
worth recording once.

---

## 1. The structural limit: NV capability items only DOWNGRADE

Every `cap_*` item under `modem/nr5g/RRC/` (and the toggles
`qcom-efs-browser`/mtbtool expose as "Disable UL MIMO", "Disable NR UL-CA",
"Disable DSS", …) works by **writing a restrictive value**. There is no NV write
that *adds* a capability the UE firmware does not already advertise.

Consequences:

- **An absent item is not a limit.** Absent = no override = firmware default.
  Half the tempting items here are absent, and that is the *good* state.
- "Enable UL CA for B3+n41" is **not an NV knob**. It is a UE-capability +
  network-grant question.
- Writing one of these tables to a value we cannot validate is a downgrade at
  best and a broken attach at worst. This page therefore recommends none.

The bitmask decode is verified, not assumed: `lte_bandpref` decodes to
`1:3:5:28:38:41`, byte-identical to what `AT+CSYSSEL="lte_band"` reports.

## 2. What is actually set

| Path (under `/nv/item_files/`) | Value | Meaning |
|---|---|---|
| `modem/mmode/lte_bandpref` | `[1,3,5,28,38,41]` | LTE policy — **no B8** |
| `modem/mmode/lte_bandpref_extn_65_256` | zeros | no bands ≥65 |
| `modem/mmode/nr_band_pref` | `[1,8,40,41,78]` | NR policy |
| `modem/mmode/nr_nsa_band_pref` | `[1,8,40,41,78]` | identical |
| `modem/mmode/mode_pref` | `0x50` | LTE (0x10) + NR5G (0x40) |
| `modem/mmode/nr5g_disable_mode` | `1` | **NR disabled** |
| `modem/mmode/ue_usage_setting` | `1` | data-centric |
| `modem/mmode/lte_disable_duration` | `0` | no LTE disable timer |
| `modem/lte/ML1/lte_ml1_l2nr_search_optimization` | `01 01` | NR search optimisation set |
| `nr5g/RRC/cap_dss_control` | `1` | DSS disabled |
| `nr5g/RRC/cap_control_nrca_3x_f_plus_t_band_combos` | `01 01 01 01 01 01` | 3× combo control |
| `mcs/trm/ant_div_switch_master` | `02 ×7, 00 ×7` | antenna diversity **on** |
| `mcs/trm/trm_ant_port_override_mode` | `0xFF` | **no** antenna-port override |
| `mcs/trm/ant_div_switch_init` | `00` | — |
| `nr5g/RRC/cap_add_bw` | 24-entry table | per-band additional-bandwidth capability |
| `nr5g/RRC/failure_mgr_efs_list_cfg` | 2 entries, `0x3C`/`0x78` | NR failure blacklist **60 s / 120 s** |

Cross-check on the RF side, same session: four chains reporting and balanced —
`AT+CRSRP: LTE,-73,-72,-76,-75`, `AT+CSINR: LTE,12,11,11,10`. So the front end is
not the uplink problem, and `ant_div_switch_master` agrees.

## 3. The empty trees (the actual answer to "can we tune coexistence?")

These exist but are **zero-length** — nothing is configured, firmware defaults
apply:

```
mcs/lmtsmgr/coex/{coex_simulation_input, desense_ind_thresholds, force_filter_path,
                  idle_mode_hopping_rxpwr_limit, set_prio_tbl_action,
                  spur_sim_input, tile_emulation_input}    size 0
mcs/lmtsmgr/endc/endc_config                               size 0
```

`coex/desense` returns `efs errno=22` (present but unreadable/empty).

So there is **no coexistence or EN-DC tuning to correct** — and inventing these
tables from a phone-oriented tool, on a 1-core router with no way to validate the
result, is not a reasonable trade.

## 4. What that leaves — the only two real levers

1. **NR is switched off** (`nr5g_disable_mode=1`), which is why `AT+C5GREG: 0,0`
   and why the n41 uplink question is moot: with no NR leg there is no n41 carrier
   to carry uplink at all. `mode_pref=0x50` *permits* NR, so this is a policy
   flip, not a capability limit. Two parts, because the vendor dialer re-applies
   it: clear the item **and** stop `USR_YOCTO_ORCA_SCG_LIMIT_SW` (the dialer
   drives `AT+CSYSSEL="nr5g_disable",%d`).
2. **B8 (900 MHz) is absent from the LTE policy** in both NV and AT. Ufone runs
   LTE on B8 and local reports describe Ufone CA settling on B3+B8, which this UE
   can never form while B8 is excluded.

Both are reversible, both need a backup + a measurement window, and neither is
applied here.

## 5. Honest limits of this page

- `cap_add_bw` and `failure_mgr_efs_list_cfg` are vendor-internal layouts. Their
  *presence*, size and first fields are recorded; the per-field semantics are
  **not** verified, so nothing is claimed about tuning them.
- The NR failure blacklist (60 s / 120 s) is a plausible contributor to "slow to
  attach after a failure", but it is a firmware default with no documented
  override here — recorded as an observation, not a recommendation.
- Raw NV images and backups are **not** committed (they carry identity and
  calibration): they live in `scripts/efs-nv/backup.sh` output directories.
