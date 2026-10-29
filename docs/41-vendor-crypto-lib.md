# 41 — `libmdlencrypt`: what is actually encrypted on this box (almost nothing)

**Date:** 2026-10-29 · **Device:** X16, `zlt-root` · **Subject:**
`/lib/libmdlencrypt.so` (121 760 B, BuildID `b4517532…`, **not stripped, DWARF
present**) and the question it answers: *are the AT or QMI payloads protected?*

Decompiled, annotated: `firmware-analysis/libmdlencrypt.decomp{,.annotated}.c`.
Pulled from the device with `ssh zlt-root 'cat /lib/libmdlencrypt.so' > …`.

---

## 1. The answer first

**No.** Nothing in the modem path is encrypted or obfuscated:

| Path | Evidence |
|---|---|
| AT commands/responses | `atcmd_daemon` lists `libmdlencrypt.so` in `DT_NEEDED` but **imports no symbol from it** — the only "encryption-looking" strings in it (`deco text:`, `deco failed: did't match any start symbol`) are the *framing* labels for splitting URCs on `\r\n\r\n` ([38](38-atcmd-daemon-internals.md) §7) **[E]** |
| QMI | `libolinterface` contains **zero** AT/crypto strings and talks to the modem through `qmi_client_send_msg_sync` in the clear ([40](40-simcom-sdk-interface.md)) **[E]** |
| Config, passwords, package integrity | **this is what the library is for** — 40 binaries link it (§3) |

So the `deco` naming that made this library look relevant was a red herring; the
flag was worth clearing once, and this is the clearing.

## 2. What is in the library

Sources named in `.debug_info` **[E]** — it is a portable crypto toolkit, not
vendor-specific except for the last two files:

```
aes256.c  des.c  des3.c  md5.c  sha256.c  base64.c  hash.c  pbkdf2.c
tz_encrypt_common.c  tz_encrypt_rand.c
```

Exports **[E]**:

| Family | Entry points |
|---|---|
| AES | `AES256_ENCRYPT`, `AES256_DECRYPT` |
| DES / 3DES | `des_encrypt/decrypt`, `des_cbc_encrypt/decrypt`, `des_set_key`, `des_self_test`, `des3_encrypt/decrypt`, `des3_cbc_encrypt/decrypt`, `des3_set_2keys`, `des3_set_3keys`, `des3_encode/decode`, `des3_get_mac` |
| Hashes | `MD5Init/Update/Final/Sum`, `sha256_init/update/final/transform/sha256Sum`, `hash_string_calculate_hash_val` |
| Encodings | `base64_encode/decode`, `hex2char`, `hex2mem`, `mem2hex`, `bytes2hexstr`, `strToByte`, `util_is_base64_string` |
| Vendor layer | `util_get_initial_lookup_index_for_one_key`, `util_replace_encode_decode`, `util_get_md5_checksum_for_one_file`, `util_get_md5_checksum_for_one_string` |

Three of those are worth characterising, because the names suggest more than they do:

- **`util_replace_encode_decode()` is a keyless, self-inverse byte permutation** **[E]**:
  for a byte `b`, `b < '0'` → `0x2F - b`; `b < '{'` → `0xAA - b`; otherwise `b`.
  Applying it twice returns the input (both branches map their input range onto
  itself). This is obfuscation, not encryption — it is the "encrypted" password
  field you can decode with a five-line script and no secret.
- **`hash_string_calculate_hash_val()` is the classic PJW/ELF string hash** **[E]**
  (`h = c + h*16`, fold at `0xf0000000`) — a name→id mapper, not a password hash.
- **`des3_encode(key, in, out, len)` takes the key from the caller** **[E]** — the
  library holds **no** built-in key, so the strength of whatever the vendor
  protects is decided entirely by the calling binary (and where it keeps its key).
  `des_self_test()` exists but nothing calls it at runtime.

`pbkdf2.c` + `tz_encrypt_rand.c` show a KDF and a PRNG were built for the vendor
layer; whether any binary uses them is per-consumer, and that is where an audit
would have to go next.

## 3. Who links it (40 binaries) **[M]**

Everything that touches a stored secret or a downloaded package:

```
atcmd atcmd_daemon button_daemon cfg_init clat_prefix_detect configloader
configmaker configtools devinfo dialer exe_daemon firewalltoolc firewalltools flagd
flow_ctrl fota idu_cmd lan_mgr lanrecord ledctrl_daemon macwriter mdlcfg mdlcfgd
netcwmpd packtoolpro parent_control passguard sms_mgr sub-snmp timer_reboot
tz_phone tz_upgrade_client tzphonebook tzupdate vpn_mgr xtcfutils
/usr/sbin/logc /usr/sbin/voipclient /usr/sbin/voipguard
```

Read that as the map of *where credentials and signed artefacts live*:
`passguard`, `configtools`/`mdlcfg`/`mdlcfgd` (the config store), `netcwmpd`
(TR-069 — ACS credentials), `fota`/`tzupdate`/`tz_upgrade_client`/`packtoolpro`
(package integrity), `voipclient`/`voipguard` (SIP credentials). It also appears
in `atcmd` and `atcmd_daemon` purely because the vendor links a common set with
`--no-as-needed`; neither imports a symbol from it.

Note for [19](19-vulnerability-assessment.md): `device-etc/` in this repo keeps
vendor config snapshots that contain "credential hashes" by design. Given §2,
those are worth re-reading as *probably* `util_replace_encode_decode` output
(reversible) rather than MD5 — that would be a finding, and it is a five-minute
check against the actual config file, not a reverse-engineering project.

## 4. Reproduce

```sh
scripts/decompile/decompile.sh firmware-analysis/libmdlencrypt.so libmdlencrypt

# is a binary's use of it real, or just DT_NEEDED?
nm -D --defined-only firmware-analysis/libmdlencrypt.so | grep -E ' [Tt] '
nm -D --undefined-only firmware-analysis/atcmd_daemon | grep -iE 'des|aes|md5|sha|base64'

# the sources the vendor built
dwarfdump -i firmware-analysis/libmdlencrypt.so | grep -oE 'DW_AT_name +[a-z0-9_]+\.c$' | sort -u
```
