# 22 — VoLTE call audio in userspace (bridge path to WebRTC)

Status: **API recovered, tap opens, playback call hangs.** Call control works;
the PCM tap attaches from an ordinary process, but the vendor play path blocks
inside `alsa_daemon` and has not yet delivered audio to the far end.

Companion captures: `docs/captures/2026-10-26-volte-prechange.md`,
`...-volte-settings-applied.md`, `...-volte-audio-test.md`.

---

## 1. What was tried and why it failed

| Approach | Result |
|---|---|
| `arecord`/`aplay` on `hw:0,X` (X28 style) | impossible — those tools are absent, and card 0 exposes `msm-stub-*` / `snd-soc-dummy-dai` endpoints, not a call-audio device |
| `hal_voice_test -p file.wav` (QTI in-call playback) | `write failed -22` (EINVAL) |
| `hal_voice_test -t 2 -r out.wav` (QTI host PCM) | `start error` on every `qahw_stream_read(1920)`; the tool ignores the error and writes garbage (171 MB in `/tmp`, deleted) |
| `example_audio` → *Pcm Stream → Enable Call Voice PCM* with no call | segfault |

`hal_voice_test` drives the QAHW voice stream directly, which is not the path
this firmware's telephony stack uses for a VoLTE call on the ODU.

## 2. The real audio architecture on this box

```
tz_phone (vendor VoLTE app, /bin/tz_phone)
   │  Sunsea_Audio_PCMIO_Open / SendPcm / Close      ← libolinterface.so.1
   ▼
/tmp/alsa_server_socket   (unix socket, root:radio)
   ▼
alsa_daemon (/usr/bin/alsa_daemon, built from simcom/alsa-daemon/src/alsa_voice.c)
   │  registers QMI_VOICE indications, manages AUDIO_STREAM_VOICE_CALL,
   │  VOIP_RX/TX flags, acdb voice calibration
   ▼
agm_server (/usr/bin/agm_server -s)  →  AGM  →  libagm*  →  ADSP → modem voice
```

Library/binary inventory confirmed present on the device:

```
/usr/lib/libolinterface.so.1.0.0     ← the PCM tap API
/usr/lib/libagm.so, libagmmixer.so, libagmclientwrapper.so, libagmserverwrapper.so
/usr/lib/libagm_pcm_plugin.so, libagm_pcm_passthrough_plugin.so, libagm_mixer*.so
/usr/lib/libtinyalsa.so, libaudioroute.so.0
/usr/bin/agm_server, /usr/bin/alsa_daemon
/usr/bin/example_audio, /usr/bin/hal_voice_test, /usr/bin/agmvoiceui
```

`example_audio` is the vendor's own factory harness for exactly this
(`1. Play 2. Record 3. Volume 4. Pcm Stream → Enable/Disable Call Voice PCM`),
and its default fixture is `/cache/piano_8K_16bit_1ch.wav` — **8 kHz, 16-bit,
mono**, which is the format the voice PCM path expects.

## 3. Recovered API (from DWARF in `libolinterface.so.1.0.0`)

`libolinterface.so.1.0.0` ships full debug info
(`../../simcom/simcom-sdk/interface/audio/src/audio_clt.c`, header
`simcom/simcom-sdk/include/Sunsea_Audio.h`). Extracted contract:

```c
typedef enum { PCM_CHANNEL_MONO = 1, PCM_CHANNEL_STEREO = 2, PCM_CHANNEL_MAX = 3 } PCM_CHANNEL_E;
typedef enum { PCM_SAMPLE_RATE_8K = 1, PCM_SAMPLE_RATE_16K = 2, PCM_SAMPLE_RATE_MAX = 3 } PCM_SAMPLE_RATE_E;
typedef enum { ENDIAN_LITTLE = 0, ENDIAN_BIG = -1 } PCM_FORMAT_E;
typedef enum { PCM_FRAME_SIZE_NONE = 0, PCM_FRAME_SIZE_320 = 1, PCM_FRAME_SIZE_640 = 2,
               PCM_FRAME_SIZE_1280 = 3, PCM_FRAME_SIZE_MAX = 4 } PCM_FRAME_SIZE_E;
typedef enum { PCMIO_WORKMODE_NONE = 0, PCMIO_WORKMODE_INPUT = 1,
               PCMIO_WORKMODE_OUTPUT = 2, PCMIO_WORKMODE_INPUT_OUTPUT = 3 } PCMIO_WORKMODE_E;
typedef enum { PCMIO_DIRECTION_NONE = 0, PCMIO_DIRECTION_LOCAL = 1,
               PCMIO_DIRECTION_REMOTE = 2, PCMIO_DIRECTION_BOTH = 3,
               PCMIO_DIRECTION_MAX = 4 } PCMIO_DIRECTION_E;

typedef struct { int valid; unsigned int len; char data[5120]; } pcm_stream_data, pcm_stream_data_s; /* 5128 B */

typedef void (*pcmio_output_ind_cb)(const pcm_stream_data_s *data);

typedef struct { PCM_CHANNEL_E channels; PCM_SAMPLE_RATE_E sample_rate;
                 PCM_FORMAT_E format; PCM_FRAME_SIZE_E frame_size; } PCMIO_INPUT_ATTR_S;      /* 16 B */

typedef struct { PCM_CHANNEL_E channels; PCM_SAMPLE_RATE_E sample_rate;
                 PCM_FORMAT_E format; PCM_FRAME_SIZE_E frame_size;
                 pcmio_output_ind_cb output_cb; } PCMIO_OUTPUT_ATTR_S;                          /* 20 B */

typedef struct { PCMIO_WORKMODE_E work_mode; PCMIO_DIRECTION_E work_dir;
                 PCMIO_INPUT_ATTR_S input_attr; PCMIO_OUTPUT_ATTR_S output_attr; } PCMIO_ATTR_S; /* 44 B */

int Sunsea_Audio_PCMIO_Open(PCMIO_ATTR_S *pcm_attr_req);
int Sunsea_Audio_PCMIO_SendPcm(pcm_stream_data *pcm_data);
int Sunsea_Audio_PCMIO_Close(void);
```

Also exported and useful: `Sunsea_Audio_StartPlay / StopPlay / GetPlayState`,
`Sunsea_Audio_StartRecord / StopRecord / GetRecordState`,
`Sunsea_Audio_SetClvl / GetClvl` (volume 0–5), `Sunsea_Audio_SetCsdvc` (codec).

**Why this matters:** `PCMIO_OUTPUT_ATTR_S.output_cb` is an async callback that
delivers downlink PCM into our process, and `PCMIO_SendPcm` injects uplink PCM.
That is precisely the tap a WebRTC bridge needs — no WAV scraping, no polling.

`PCMIO_DIRECTION_LOCAL/REMOTE/BOTH` selects between the local codec path and the
network (remote party) path. A browser bridge wants **REMOTE** (or BOTH while
`tz_phone` still owns the codec).

## 4. Consequence for the X28 design

The X28 project's shape survives, but the audio leg changes:

```
Browser --WebRTC/Opus--> bridge --PCMIO_SendPcm(8k mono)--> alsa_daemon --> VoLTE uplink
Browser <--WebRTC/Opus-- bridge <--output_cb(8k mono)------ alsa_daemon <-- VoLTE downlink
```

Call control also differs: the X28 shelled out to `atcmd 'ATD…'`. Here the
vendor's own path is `tz_phone` → `Sunsea_VoiceCall_Start` (QMI voice), while raw
`ATD`/`ATH` via `/bin/atcmd` **does work** and was verified end to end
(`AT+CLCC`: 2 → 3 → 0, callee answered).

Build target: ARMv7 hard-float, glibc 2.31 (not the X28's arm64/musl).
`zig cc -target arm-linux-gnueabihf` is available on the build host.

## 5. Next steps (in order, no calls until step 3)

1. Build a minimal probe (see `router-fix/voip-bridge/`) that dlopens
   `libolinterface.so.1`, calls `PCMIO_Open(INPUT_OUTPUT, REMOTE, 8k mono,
   frame 320/640)`, logs the return code, then `PCMIO_Close()`.
   Run it **without a call** only to measure the failure mode.
2. Verify linking/ABI on the device (`ldd`-free: check `LD_TRACE_LOADED_OBJECTS`
   or just run it), confirm no crash and no audio-daemon disruption.
3. One authorized live call to validate:
   - uplink: `SendPcm` of the greeting → callee hears it
   - downlink: `output_cb` fires with non-silent PCM → record to a WAV locally
   and inspect on the host.
4. Only then adapt the X28 Go/Pion bridge: Opus 48k ⇄ 8k PCM resample, ARMv7
   build, QManager port 8080 conflict (use another port), boot wiring via a hook
   at the top of `/etc/initscripts/StartTZApp` (not a systemd unit under
   `/etc/systemd/system` — those are invisible at boot).

## 6. Risks / open questions

- `tz_phone` may hold the voice PCM tap exclusively; the bridge may need to run
  instead of it (stop `tz_phone`, or use `PCMIO_DIRECTION_REMOTE` alongside).
  SYS_VOLTE_SW gates `tz_phone` at boot, so this is a supported vendor switch.
- `alsa_daemon` is the only broker; a malformed PCMIO request could affect voice
  but not the data call. Do not restart `alsa_daemon` while a call is up.
- Frame size 320/640/1280 samples at 8 kHz = 40/80/160 ms; the bridge needs
  20 ms Opus frames, so expect buffering/re-chunking.
- Nothing here touches modem firmware, MBN/PDC, or the PDP context.


## 7. Hardware results (2026-10-26)

Probe source: `router-fix/voip-bridge/sunsea-pcm-probe.c`
(built with `zig cc -target arm-linux-gnueabihf.2.31`; the plain
`arm-linux-gnueabihf` target produces GLIBC_2.34 symbols and will not run on
this glibc 2.31 device).

| Test | Result |
|---|---|
| `PCMIO_Open(INPUT_OUTPUT, REMOTE, 8k mono, frame 640)` + `Close`, no call | **rc=0 / rc=0** — socket + semaphores created, read/write threads started, daemons and WAN unaffected |
| Same, with `SendPcm` at real-time pace, during an answered call | every send logs `status has changed -----> stop writing` — data is discarded; downlink callback fired once (320 B) |
| `StartPlay(/tmp/x16-hello8k.wav, 2)` after `PCMIO_Open`, during an answered call | **blocks** inside the daemon call; killed by `timeout` after 22 s (rc 143), no audio at the far end |
| `StartPlay` again with `tz_phone` stopped | same block; `tz_phone` restarted afterwards |

Conclusions:

1. Attaching to the voice tap is safe and reversible — no daemon restart, no
   crash, no WAN impact. That was the main unknown and it is now resolved.
2. The vendor play/record path is **not** usable as a black box: `StartPlay`
   never returns while the modem voice stream has no audio usecase armed, so it
   cannot be driven blind from a script.
3. `SendPcm` is the right primitive for a bridge (pace control, no file
   dependency), but the write thread refuses data (`stop writing`) until the
   play state is started — and starting it is exactly the call that blocks.
4. Therefore the remaining work is to arm the AGM voice usecase directly
   (`libagm` / `libagmmixer`: `set_agm_stream_metadata`,
   `connect_agm_audio_intf_to_stream`, as `agmvoiceui` does), instead of asking
   `alsa_daemon` to start a file playback.

### Safety notes learned the hard way

- `timeout N` is not enough for these calls: the vendor library blocks with
  signals masked, so use `timeout -k 2 N` **and** an explicit `kill -9` sweep of
  `sunsea-pcm-probe` afterwards.
- Never leave a probe running: the earlier crash-loop left one process alive for
  minutes, which is what stalled the SSH session.
- `hal_voice_test -r <file>` writes garbage of unbounded size when the read
  fails (171 MB observed in tmpfs). Do not run it without a size guard.

## 8. Why the vendor play path blocks (working hypothesis, 2026-10-26)

Raw `ATD` via `/bin/atcmd` creates a real modem call, but it bypasses the
vendor's own call stack. `tz_phone` is the process that drives
`Sunsea_VoiceCall_*` and, with it, the QMI voice stream that `alsa_daemon` turns
into an AGM voice usecase. With `ATD`, `tz_phone` never enters its dial path, so
no voice usecase is armed — which is exactly the state in which
`PCMIO_SendPcm` logs `stop writing` and `StartPlay` blocks forever.

This is consistent with every observation so far:

- `PCMIO_Open` succeeds without a call (the transport is always available).
- `SendPcm` is accepted but dropped (no armed stream).
- `StartPlay` blocks (the daemon waits for a stream that never appears).
- Audio on the far end is silent because nothing is ever routed there.

### The vendor UI is present and is the supported dial path

The device ships a voice UI at `/tzwww/html/voice` plus the vendor CGI
`/tzwww/cgi-bin/http.cgi`. Voice configuration keys exist in `mdlcfg`
(`IDU_WEB_USER_LOGIN_NAME`, `IDU_WEB_USER_LOGIN_PWD`, `SYS_WEB_*`,
`SYS_LIBCOMMLOG_MOD_EN_TZ_PHONE`, `SYS_LIBCOMMLOG_MOD_EN_VOIPCLIENT`).

Recommended next step, in order:

1. Read the vendor voice page plus `x16-main.js` to find the exact CGI request
   that originates a call (the enum has `AUTO_DIAL:222`, `VOICE_BASIC_CONFIG:295`,
   `VOLTE_CONFIG:296`; the call command itself is still unidentified).
2. Dial through that CGI (session cookie from the vendor UI) instead of `ATD`,
   so `tz_phone` owns the call and arms the voice usecase.
3. Re-run `sunsea-pcm-probe --play-file ...` in that state. If `StartPlay`
   returns 0 and the callee hears the greeting, the bridge is feasible exactly
   as designed in §4.
4. Only then build the WebRTC/Opus side (ARMv7, separate port from 8080, boot
   hook at the top of `/etc/initscripts/StartTZApp`).

Do **not** use `ATD` for further audio experiments: it cannot arm the audio path.

## 9. Attempt log and current verdict (2026-10-26, end of session)

| Attempt | Dial path | Audio attempt | Result |
|---|---|---|---|
| 1 | `ATD` | `hal_voice_test -p` 4 s after dial | `write failed -22`; call had not been answered yet |
| 2 | `ATD` | `hal_voice_test -t 2 -r` during answered call | `qahw_stream_read` start error on every cycle; 171 MB junk file written |
| 3 | `ATD` | `PCMIO_Open` + paced `SendPcm` | sends accepted but logged `stop writing`; one 320 B downlink callback |
| 4 | `ATD` | `StartPlay` (no `PCMIO_Open`) | blocked, `timeout` killed it (rc 143) |
| 5 | `ATD` | `PCMIO_Open` + `StartPlay`, `tz_phone` running | **blocked again and survived SIGTERM** — process had to be `kill -9`'d; script never reached step B |
| — | vendor CGI | not attempted for dialling | `/tzwww/html/voice/voipCall.js` only configures SIP/call-barring; **the vendor UI has no dial command** |

### Verdict

- Call control (`ATD`/`ATH`/`CLCC`) works and is reliable.
- Every userspace audio route tried so far **fails or blocks**:
  QAHW voice streams reject writes, `SendPcm` is dropped, and the vendor
  `StartPlay` request blocks indefinitely — with `tz_phone` both running and
  stopped, and with the PCM tap both opened and not opened.
- `StartPlay` blocks inside the library with signals masked, so `timeout`
  (SIGTERM) cannot reap it; only `kill -9` works. This alone makes the vendor
  file path unusable from a script.

### What this means for the original goal

Browser ⇄ cellular calls on this X16 needs the AGM voice stream to be armed from
userspace (libagm/libagmmixer metadata, the `agmvoiceui` path) before either
PCMIO primitive works. That is a substantially larger piece of work than adapting
the X28 bridge, and it is **not yet proven possible on this firmware**: the
signals so far are consistent with the ODU firmware routing call audio
exclusively inside the DSP/`alsa_daemon` pair and not offering a byte stream to
ordinary processes.

### Recommended before spending more calls

1. Confirm offline (no call) that `agmvoiceui` can open the `PCM_RT_PROXY`
   interface and set stream metadata; if that cannot be done without a live
   voice stream, the remaining path is RE of `alsa_daemon`'s protocol on
   `/tmp/alsa_server_socket`.
2. If neither yields a stream, park the feature: the honest answer to "is the
   X28 bridge portable to the X16?" is *call control yes, call audio not
   demonstrated*.

## 10. Decisive finding: this ODU has no wired audio backend

Enumerated from the running kernel (no call, no changes):

```
# /sys/kernel/debug/asoc/components
soc:qcom,msm-stub-codec
snd-soc-dummy
snd-soc-dummy

# /sys/kernel/debug/asoc/dais
msm-stub-rx
msm-stub-tx
snd-soc-dummy-dai
```

The `sound-tavil` machine driver (`qcom,sdx-asoc-snd-tavil`) registered a card
built **only from stub and dummy components**. `wcd934x_dlkm`, `snd_soc_rt5616`
and `snd_soc_nau8810` are loaded but **no real codec DAI is attached to the
card** — consistent with an ODU that has no speaker, microphone or codec wiring.

This single fact explains every audio failure observed:

| Symptom | Cause |
|---|---|
| `agmvoiceui` → `Invalid mixer control: CODEC_DMA-LPAIF_VA-TX-0 rate ch fmt` then `Failed to set device media config` | that mixer control does not exist on a stub-only card |
| `hal_voice_test` voice-stream write → `EINVAL` | no backend DAI can accept the stream |
| `has_voice_test` HPCM read → `start error` | no capture backend |
| `PCMIO_SendPcm` → `stop writing` | `alsa_daemon` has no stream to attach the tap to |
| `StartPlay` blocks forever | the daemon waits on a voice stream that is never created |

`/proc/asound/pcm` tells the same story: the PCM endpoints are
`msm-stub-rx-0`, `msm-stub-tx-1` and `snd-soc-dummy-dai-*`. The HPCM usecases in
`/etc/audio_platform_info_extcodec.xml` (PCM ids 13–16) describe backends this
board never instantiates.

### Conclusion

**Browser ⇄ cellular call audio is not achievable from userspace on this X16 as
shipped.** The X28 design depends on ALSA/host-PCM endpoints that carry real call
audio; here the machine driver exposes stubs only, so there is no PCM carrier to
bridge into WebRTC. Fixing it would need a vendor change to the DSP audio
routing / machine driver (real codec or a properly configured AGM host-PCM
backend) — not something reachable by configuration, a module, or a userspace
daemon.

What *does* work and is documented here: VoLTE call control (`ATD`/`ATH`/
`AT+CLCC`), VoLTE enablement via `SYS_VOLTE_SW`/`USR_VOICE_TYPE`, and a benign,
reversible way to attach to the vendor PCM tap (`PCMIO_Open` returns 0) for
future use if the vendor ever exposes a backend.

Recommendation: park the WebRTC audio bridge for this ODU. The X28 project
remains valid on hardware whose audio card has real call-audio endpoints.
