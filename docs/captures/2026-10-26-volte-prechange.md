# X16 VoLTE bridge — pre-change snapshot

Collected 2026-10-26 before changing any voice configuration. The general read-only recon was run from `docs/recon-x16.sh`; this focused snapshot omits device serials, subscriber identifiers, phone numbers, MAC addresses, and credentials. This checkout has no `.git` directory, so the capture is saved in `docs/captures/` but cannot be git-committed here.

## Current voice configuration

| Key | Value |
|---|---:|
| `SYS_VOLTE_SW` | `0` |
| `USR_VOICE_TYPE` | `1` (vendor script selects VoIP for `1`, VoLTE otherwise when auto mode is off) |
| `SYS_VOICE_TYPE_AUTO_SW` | `0` |
| `USR_VOIP_SW` | `0` |

The existing vendor scripts select `tz_phone` only when VoLTE is enabled and the selected voice type is VoLTE (or automatic selection is enabled). VoIP and VoLTE are separate vendor paths.

## Audio and call-path evidence

- Kernel: Linux `5.4.210-perf`, `armv7l`; SDX65/SDXLEMUR.
- Audio services observed: `agm_server.service`, `alsa.service`, and `init_audio.service` active/exited as expected. `alsa_daemon` was running. No `tz_phone`, `voipclient`, or `voipguard` process was running.
- ALSA exposes `/dev/snd` PCM nodes, but `/proc/asound/pcm` labels the primary MI2S endpoints as `msm-stub-*`; the X28 `hw:0,0` / `hw:0,12` assumptions do not apply.
- `/etc/audio_platform_info_extcodec.xml` maps HPCM voice input/output use cases to PCM IDs 13–16.
- `/bin/tz_phone` contains vendor `Sunsea_Audio_PCMIO_Open`, `Sunsea_Audio_PCMIO_SendPcm`, and close symbols, plus call-control symbols. This is evidence of a vendor PCM interface, not proof that a third-party bridge can safely use it concurrently.
- `/usr/bin/hal_voice_test` contains HPCM record/playback test functionality; it was **not run** because it starts a voice stream/call path.
- `/etc/mixer_paths.xml` defines voice speaker and microphone routes. Physical/usable ODU audio routes remain to be verified.

## Network and service state

- QManager owns TCP port 8080; an HTTPS WebRTC service must use another port or an explicitly designed integration.
- Current router/data service state was collected by recon. Sensitive identifiers and addresses are intentionally excluded from this focused note.
- A prior read-only AT capture showed an IMS PDP context configured but inactive at that time. It needs fresh verification after a safe service enable; no modem AT voice command was attempted because the QManager allowlist does not permit it.

## Change and test boundaries

No device setting, service, or modem state was changed during collection. No call was placed. The configuration values above are the rollback values for this proposed change. A live cellular test remains separate: it must use an authorized test destination and may incur carrier charges.
