# scripts/decompile — vendor ARM binary → annotated C

Two small pieces, no dependencies beyond Ghidra and Python 3:

| File | Role |
|---|---|
| `decompile.sh` | driver: imports the ELF into a throwaway Ghidra project, decompiles every function, then annotates |
| `DumpDecomp.java` | Ghidra headless post-script: walks `getFunctions(true)`, writes the C for each named by address and size |
| `annotate.py` | resolves the ARM PIC *literal-pool* strings the decompiler prints as arithmetic |

```sh
./decompile.sh ../../firmware-analysis/atcmd_daemon atcmd_daemon 122e4
./decompile.sh ../../firmware-analysis/atcmd atcmd
```

Writes, beside the binary:

```
<name>.decomp.c              raw decompilation
<name>.decomp.annotated.c    same, with `// 0x5xxx "literal"` on the string users
```

`GHIDRA_HOME=/path/to/ghidra` overrides auto-detection (Homebrew cask, `/opt/ghidra`,
`/usr/share/ghidra`, `~/ghidra` are tried).

## Why `annotate.py` exists

These binaries are `-fPIC`, and GCC's ARM pattern for a string constant is two
instructions:

```asm
ldr   r1, [pc, #0x1c4]   ; r1 = 0x40aa     (a dword in .text, the "literal pool")
add   r1, pc             ; r1 = pc + r1 = &"…"   (in .rodata)
```

Both decompilers faithfully render that as a sum of two addresses, so you get

```c
savelog(1, DAT_000141e0 + 0x141d2, DAT_000141d4 + 0x14084);   // which strings?
```

`annotate.py` computes `dword(pool) + pc` for every pair in the dump, checks that the
result starts a printable C string, and appends it. Ghidra imports a PIE at an
arbitrary image base (**0x10000** for the X16 binaries) while the pool dwords are
link-time offsets, so the script auto-detects the base (`--base 0` for r2ghidra
output, which loads at 0) and also tolerates the `p = base - 1; *++p` idiom by
trying up to 3 bytes past the computed address.

`atcmd_daemon`: 190 literals resolved, `atcmd`: 8 — that is the whole point of the
exercise; the interesting behaviour in these binaries is *which string it compares*
(`AT+MODULE_SN`, `AT+TOZEDSMS`, `SYS_USSD_SW`) and *which path it writes*
(`/tmp/.atcmd_daemon_transfer`, `/tmp/.ussd_ret`).

## When the binary has DWARF — read it before decompiling

Some of these ELFs are **not stripped and carry `.debug_info`** (`libmdlsockmsg.so`,
`libolinterface.so.1.0.0`, `libmdlencrypt.so`). Then the vendor's own headers are
recoverable — struct layouts, field names, enum values and the build paths — which
beats any decompilation. `dwarfdump` (libdwarf) works; the Homebrew `llvm-dwarfdump`
is currently broken (missing `libz3`).

```sh
# struct layout with the vendor's field names
dwarfdump -i libmdlsockmsg.so | grep -A40 'DW_AT_name *tSOCK_MSG$'

# enum constants (this is how the 55 sockmsg app ids were recovered)
dwarfdump -i libmdlsockmsg.so | grep -E 'DW_AT_name +APP_ID_' -A1

# which sources the vendor built, and where (provenance + build date)
dwarfdump -i libolinterface.so.1.0.0 | grep -oE 'DW_AT_name +[a-zA-Z0-9_./+-]+\.(c|h)$' | sort -u
```

`DW_AT_decl_file` on a member is the header path, e.g.
`/home/tzsoft/sunsea-x62/tozed/tzproc/mdllibs/libsockmsg/sockmsg.h` — that is how
[39](../../docs/39-sockmsg-bus.md) and [40](../../docs/40-simcom-sdk-interface.md)
got their meaning.

A `.rodata` table referenced by a known symbol is worth decoding too: `app_items`
in `libmdlsockmsg.so` is `tAPP_ITEM[]` (stride `0x68`), and reading it as
`{int id; char name[100]}` produced the complete socket-name table without any
disassembly.

## The `EXTRA_FUNCS` argument

Ghidra sometimes refuses to create a function whose tail follows a literal pool, and
then silently decompiles only the head — `vcall_evt_cb` in `atcmd_daemon` came back
as four lines (`memcpy` + `return`) until `122e4` was forced. When a decompiled
function looks too short for its `size`, look for the pool dword between two
`push {…, lr}` sequences and pass the address after it, comma-separated, as the
third argument. Addresses are in the **dump's** address space (Ghidra's, so already
biased by 0x10000 for these binaries).

Forcing a boundary does not change the binary — the project is deleted on exit.

## Cross-checking a dump against the running daemon

The vendor log calls carry `__FUNCTION__` and `__LINE__`:

```
2026-10-29 17:53:14 [atcmd_daemon] (atcmdd_send_atcmd, 871): Received AT cmd:[AT+CFUN=4]
```

`0x367 == 871` matches the decompiled `savelog(0, …, "atcmdd_send_atcmd", 0x367, …)`,
which is how we know a dump corresponds to the firmware in the field and not to a
nearby build. Do that before writing anything based on a dump.
