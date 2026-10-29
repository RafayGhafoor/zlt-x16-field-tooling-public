# efs-nv — read (and safely back up) the modem's EFS/NV on a ZLT X16

The X16's SIM8260E keeps its real radio policy in **EFS NV**, not in the MBN.
This module gives read access to it from a Linux/macOS host, plus a backup path
that must be used before any write.

```
scripts/efs-nv/
├── build.sh      cross-compile qcom-efsd + efscli for armv7 (zig, static)
├── efscli.c      ~60-line client for the helper's abstract-socket JSON protocol
├── nv-read.sh    dump the radio-policy items and decode them
├── backup.sh     snapshot NV (item-wise, or --raw whole partition)
└── decode_nv.py  bitmask -> band lists
```

```sh
./build.sh                                   # once
./backup.sh --raw                           # full efs2 partition (~13 MB)
./backup.sh                                 # restorable item-wise snapshot
./nv-read.sh                                # read + decode current policy
./nv-read.sh --item /nv/item_files/...      # add one more item
```

## Why it needed porting

Upstream [`qcom-efs-browser`](https://github.com/catxeon/qcom-efs-browser) ships
an **aarch64-only** Android helper. This router is **armv7l with glibc 2.31**, so
the prebuilt binary cannot run, and its `build.sh` needs the Android NDK.

Two changes make it work:

1. **`zig cc -target arm-linux-musleabihf -static`** — no NDK, no sysroot.
2. **static musl** — a default zig glibc build links against 2.34 and dies on the
   device with ``/lib/libc.so.6: version `GLIBC_2.33' not found``.

The helper talks **DIAG over QRTR** (service 4097). This box has **no
`/dev/diag`**, but `qrtr-ns` is running and the modem publishes DIAG on node 3,
so it works. Confirmed live:

```
{"ok":true,"transport":"qrtr 3:35","subsys":19,"readonly":true}
```

## The one thing that will waste your afternoon

**Abstract unix sockets match on the exact length of the name.** The helper binds
with `offsetof(sun_path) + 1 + strlen(name)`; a client that passes
`sizeof(struct sockaddr_un)` gets `ECONNREFUSED` even though `/proc/net/unix`
shows the socket and the daemon is alive. `efscli.c` matches the length.

## Backup modes (and why `image` is not one of them)

The helper's `image` command — a logical dump of a whole subtree — is
**rejected by this modem**: `fs-image open: ... bad command (0x13)`. So:

| Mode | What it is | When |
|---|---|---|
| `backup.sh` | per-item bytes + sha256 for every policy item | before each write |
| `backup.sh --raw` | `dd if=/dev/mtd3` — the whole `efs2` partition, 13 MB | once, before a round of changes |

`backup.sh` verifies sha256 on both sides and writes a `MANIFEST.txt` that marks
each item `PRESENT` / `ABSENT` / `ERROR`. An `ABSENT` item needs no rollback —
it was never set.

## What is actually in NV on this firmware

Measured, and cross-checked against the AT layer:

| Item | Value | Meaning |
|---|---|---|
| `mmode/lte_bandpref` | `[1, 3, 5, 28, 38, 41]` | **exactly** what `AT+CSYSSEL="lte_band"` reports |
| `mmode/lte_bandpref_extn_65_256` | all zero | no bands ≥65 |
| `mmode/nr_band_pref` | `[1, 8, 40, 41, 78]` | matches `nsa_nr5g_band` |
| `mmode/nr_nsa_band_pref` | `[1, 8, 40, 41, 78]` | identical |
| `mmode/mode_pref` | `0x50` | LTE (0x10) + NR5G (0x40) |
| `mmode/nr5g_disable_mode` | `1` | **NR disabled** |
| `mmode/ue_usage_setting` | `1` | data-centric |
| `mmode/lte_disable_duration` | `0` | no LTE disable timer |
| `nr5g/RRC/cap_dss_control` | `1` | DSS disabled |
| `nr5g/RRC/cap_control_nrca_3x_f_plus_t_band_combos` | `01 01 01 01 01 01` | combo control table |

The bitmask convention above is *verified*, not assumed: `lte_bandpref` decodes
to `1:3:5:28:38:41`, byte-identical to the AT read. If a decoder disagrees with
the AT layer on that item, the decoder is wrong.

### Traps

- **Most `/nv/item_files/modem/lte/rrc/efs/*` names do not exist.** They show up
  as strings inside the modem image because they are the *firmware defaults*;
  reading them live returns `bad length (0x15)`. Of the 22 `nr5g/RRC/cap_*`
  items only **two** are present. A name in a firmware image is not an item.
- **`bad length (0x15)` means "not set", not "broken".** That distinction is the
  finding in half these investigations.
- **NV capability items can only DOWNGRADE.** Everything the EFS browser exposes
  ("Disable UL MIMO", "Disable NR UL-CA", …) *writes a restrictive value*. There
  is no NV write that **adds** a capability the UE firmware does not advertise.
  Absent item = unrestricted = firmware default. So "enable UL CA for B3+n41"
  is not an NV knob; at best you confirm nothing is restricting it.

## Safety

`qcom-efsd` starts **read-only** unless given `-rw`; neither `nv-read.sh` nor
`backup.sh` passes it. Nothing in this module writes NV. If a future change needs
a write, take `backup.sh` first and keep the `.bin` files.
