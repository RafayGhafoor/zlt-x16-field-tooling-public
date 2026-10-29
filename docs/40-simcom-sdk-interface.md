# 40 — `libolinterface`: the SIMCom SDK, i.e. the modem API underneath AT

**Date:** 2026-10-29 · **Device:** X16, `zlt-root` · **Subject:**
`/lib/libolinterface.so.1.0.0` (266 148 B, **not stripped, DWARF present**) —
the library that actually speaks QMI to the SIM8260E.

Why this one matters: [38](38-atcmd-daemon-internals.md) showed the AT daemon is
one consumer of the modem, and it is **not** the important one. `libolinterface`
is the vendor's own modem API — data call, signal, SMS, voice, GNSS, mobile-AP —
and it contains **zero AT strings** **[E]**. The vendor's own apps drive the modem
over QMI; AT is a convenience layer for the CLI and the dialer.

Decompiled, annotated: `firmware-analysis/libolinterface.decomp{,.annotated}.c`
(6316 lines, 211 literals). Earlier partial work: `libol-datacall.c`,
`data_call_evt_cb.c`, `pdp-watchdogs.c` in the same directory.

---

## 1. Provenance and shape

`.debug_info` gives the source paths straight out of the vendor build tree **[E]**:

```
/home/zxs/SDX65_LE12/AP_KZ_230313/src/simcom/simcom-sdk/interface/basic/src/basic_clt.c
/home/zxs/SDX65_LE12/AP_KZ_230313/src/simcom/simcom-sdk/interface/audio/src/audio_clt.c
/home/zxs/SDX65_LE12/AP_KZ_230313/src/simcom/simcom-sdk/interface/gnss/src/gnss_clt.c
/home/zxs/SDX65_LE12/AP_KZ_230313/src/simcom/simcom-sdk/interface/mobileap/src/Sunsea_MobileAP.c
/home/zxs/SDX65_LE12/AP_KZ_230313/src/simcom/simcom-sdk/include/Sunsea_Audio.h
/home/zxs/SDX65_LE12/AP_KZ_230313/src/simcom/simcom-sdk/include/Sunsea_VCall.h
```

`SDX65_LE12` and `AP_KZ_230313` (2023-03-13) match the firmware lineage in
[35](35-modem-firmware-version.md) — this is **SIMCom's SDK for this exact
Qualcomm baseline**, shipped as a binary blob, with "Sunsea" as the module
vendor's brand (the same name that appears in `sunsea_dialer_config_lan_wan` and
`Sunsea_Basic_Init`).

`83` exported `Sunsea_*` entry points, grouped **[E]**:

| Group | # | Covers |
|---|---:|---|
| `Sunsea_MobileAP_*` | 18 | QCMAP: enable/disable the AP, IPv4/IPv6 state, roaming, IP-passthrough, WWAN statistics, IPv6 config |
| `Sunsea_Audio_*` | 17 | PCMIO: open/close, send PCM, start/stop play + record, mic gain, codec control, CSDVC, play/record state |
| `Sunsea_Gnss_*` | 13 | position mode, start/stop, XTRA injection, aiding-data delete |
| `Sunsea_DataCall_*` | 9 | start/stop, get info, profile get/set, statistics, IPPT |
| `Sunsea_VoiceCall_*` | 8 | start, answer, end, hold, multi-process, get state/info |
| `Sunsea_NW_*` / `Sunsea_Nw_*` | 6 | cell info, signal, RF band info, PLMN, registration, **IMS status** |
| `Sunsea_DM_*` | 4 | IMEI, version info, phone mode get/set |
| `Sunsea_UIM_*` | 3 | IMSI, ICCID, card status |
| `Sunsea_Basic_*` | 2 | `Sunsea_Basic_Init`, `Sunsea_Basic_SMS_Init` |
| `Sunsea_SMS_*` / `Sunsea_Sms_*` | 2 | `Sunsea_SMS_SendMsg`, `Sunsea_Sms_Init` |
| `Sunsea_mobileap_init` | 1 | — |

That surface is the answer to a question [36](36-qmi-direct-probe.md) left open
implicitly: **every value `qmicli` reads for us has a vendor API here**. Where we
use `--nas-get-signal-info`, the firmware calls `Sunsea_NW_GetSignal`; where we
use `--dms-get-ids`, it calls `Sunsea_DM_GetIMEI` / `Sunsea_UIM_GetIMSI`. Two
capabilities have **no AT equivalent at all** and are only reachable this way:
`Sunsea_NW_GetIMSStatus` (VoLTE/IMS registration) and `Sunsea_MobileAP_GetWWANStatistics`.

## 2. How it talks to the modem

- `qmi_client_init_instance` + `qmi_client_send_msg_sync` — the stock **libqmi_cci**
  client API (the same transport `qmicli` uses, [36](36-qmi-direct-probe.md));
- service objects from `libqmiservices.so.1`; the only one referenced by name here
  is `qcmap_msgr_get_service_object_internal_v01` (Linux bridge / mobile AP);
- `osm_requester_init(handle, name, cb)` (from `libmdlbase.so`) initialises the
  requester that the `*_clt.c` files share, and its log format
  `<ERRO> [F:%s,L:%d,sec:%ld,usec:%ld] >>> …` is what shows up in the vendor logs.

So this is **not** the AT channel and does not fight `atcmd_daemon` for it: it is
a second, independent path into the modem. That is consistent with what we measured
in [38](38-atcmd-daemon-internals.md): the dialer keeps working while AT is wedged.

## 3. The three callbacks — and where USSD actually comes from

```c
int Sunsea_Basic_Init(sms_rx_cb      my_sms_evt_cb,
                      vcall_evt_cb_t my_vcall_evt_cb,
                      data_call_evt_cb_t my_data_call_evt_cb);
```

`atcmd_daemon` calls it as `Sunsea_Basic_Init(sms_evt_cb, vcall_evt_cb, 0)` **[E]**
(`main` @ 0x13dc0). The library stores the pointers in globals and prints
`Sunsea_Sms_Init Success!!` / `Sunsea_VoiceCall_Init callback is NULL!!` — those
exact strings are in the binary, and `[SMS_MGR] Sunsea_Basic_Init success` is in
the daemon's boot log **[M]**.

This settles the USSD question left open in [38](38-atcmd-daemon-internals.md) §6.
`libolinterface` contains **no USSD/CUSD code** (`grep -c '^AT+'` = 0, no CUSD
strings) **[E]**, yet `atcmd_daemon`'s `vcall_evt_cb` receives
`notification_type` / `uss_dcs` / `uss_data`. Therefore:

> **USSD is delivered as a *voice-call indication*** by the SIMCom SDK's
> `SIMCOM_VCall_ind_cb` (a QMI VOICE service indication), not over AT and not by a
> dedicated USSD API. That is why the handler is called `vcall_evt_cb`, why
> `AT+CUSD` only appears in `/bin/dialer`'s strings rather than in the daemon, and
> why the daemon's USSD state machine talks to the rest of the system through
> `/tmp/.ussd_*` files instead of a bus message.

`vcall_evt_cb_t` is declared in `simcom-sdk/include/Sunsea_VCall.h` **[E]** (the
typedef survives in DWARF; the struct members are only visible as the offsets the
daemon reads: `+0x00` … notification_type at the third word, `uss_dcs` and a
`char uss_data[]` after it).

## 4. The audio path — and a struct we can now stop guessing

`Sunsea_Audio_*` moves PCM through **two POSIX shared-memory segments** created by
`create_pcmstream_socket()` **[E]**:

```c
shm_open("/pcm_stream_record", O_RDWR|O_CREAT, 0666);
shm_open("/pcm_stream_playbk", O_RDWR|O_CREAT, 0666);   /* + matching shm_unlink */
```

and the payload struct, from DWARF (`Sunsea_Audio.h:0x18`) **[E]**:

```c
typedef struct {                 /* pcm_stream_data, byte_size 5128 */
    int          valid;          /* 0x0000 */
    unsigned int len;            /* 0x0004 */
    char         data[5120];     /* 0x0008 */
} pcm_stream_data_s;
```

This is **exactly** the struct hand-written in
[`../router-fix/voip-bridge/x16-audio.c`](../router-fix/voip-bridge/x16-audio.c)
(`typedef struct { int valid; unsigned int len; char data[5120]; } pcm_stream_data_s;`)
— so the call-terminal module's ABI assumption is now confirmed against the
library's own debug info rather than inferred from a capture. Two threads do the
work (`audio_pcmstream_read_thread` / `audio_pcmstream_write_thread`) with a
semaphore (`create_pcmstream_sem`) and a mutex (`pcm_work_mutex`), and
`g_volte_pcm_in` / `g_pcm_out_size` are the globals the "PCMIO" tap is built on.

If the calls module ever needs a change (jitter, resampling, a second stream), this
is the layer to read — not the AT channel.

## 5. Who links it

Only three real programs on the unit **[M]**: `atcmd_daemon`, `dialer`, `tz_phone`
— plus four SIMCom **demo binaries that shipped in the image**:
`example_audio`, `example_basic`, `example_gnss`, `example_mobileap`
(`/bin/example_audio` etc.). Those demos are the vendor's own usage examples for
the SDK, on the device, executable.

That is worth keeping in mind for two reasons: it is a ready-made test harness if
we ever want to call the SDK ourselves (they are dynamically linked against the
same library), and it is four more privileged binaries in the attack surface of
[19](19-vulnerability-assessment.md).

## 6. Reproduce

```sh
scripts/decompile/decompile.sh firmware-analysis/libolinterface.so.1.0.0 libolinterface

# the exported API, grouped
nm -D --defined-only firmware-analysis/libolinterface.so.1.0.0 | grep Sunsea_ | \
  sed -E 's/^.*Sunsea_([A-Za-z]+)_.*/\1/' | sort | uniq -c | sort -rn

# the vendor's structs
dwarfdump -i firmware-analysis/libolinterface.so.1.0.0 | grep -A12 'DW_AT_name *pcm_stream_data$'
dwarfdump -i firmware-analysis/libolinterface.so.1.0.0 | grep -E 'DW_AT_name *(vcall_evt_cb_t|sms_rx_cb|data_call_evt_cb_t)$'
```
