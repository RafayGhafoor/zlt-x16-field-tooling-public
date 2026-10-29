# X16 authorized VoLTE call/audio smoke test

Performed 2026-10-26 at the user's request. The destination is deliberately omitted from this local capture.

## Actions and results

- Generated a short spoken greeting as mono, 16-bit, 8 kHz PCM WAV and staged it temporarily at `/tmp/x16-hello.wav`.
- Issued one outgoing `ATD<number>;` via the vendor `/bin/atcmd` entry point. The modem client returned `OK`; that confirms command acceptance, not that the destination answered.
- Tried the vendor Qualcomm voice/HPCM playback utility once: `hal_voice_test -n 1 -p /tmp/x16-hello.wav`.
- The utility opened a voice stream and wrote four 4096-byte blocks, then failed with `write failed -22` and remained running. It was terminated by PID; no broad `killall` was used.
- Sent one `ATH` hangup via `/bin/atcmd`; it returned `OK`.
- Removed the temporary WAV from `/tmp`.

## After-test health

- No `hal_voice_test` process remained.
- QManager services remained active and HTTP on `127.0.0.1:8080` returned `200`.
- The default WAN route remained on `rmnet_data0`, and its counters continued increasing.
- No reboot, dialer restart, QCMAP restart, or modem-profile/firmware change was made.

## Conclusion

The X16 accepted an outgoing dial command and its Qualcomm voice tool began playback, but the tool returned `EINVAL` (`-22`) before completing. It is **not verified** that the remote party answered or heard the greeting. The player appears to have a format/stream/route mismatch or a second voice-stream contention issue. Do not repeat a billed call until the HPCM playback failure is diagnosed. The configuration rollback remains at `/data/zlt-backups/20261026/volte-webrtc/restore-voice-settings.sh`.

## Second attempt (call-control confirmed, audio still blocked)

- Dial accepted; `AT+CLCC` progressed `state 2` (dialing) -> `state 3` (alerting) -> `state 0` (active, answered by the user).
- With the call active, tried the host-PCM voice path: `hal_voice_test -n 1 -t 2 -p <48k stereo wav> -r /tmp/x16-dl.wav -l 20`.
- Downlink capture failed on every cycle: `start error returned from qahw_stream_read, in_buffer_size:1920`. The tool ignores the error and keeps writing its buffer, which produced a 171 MB junk file in `/tmp`; it was deleted immediately (tmpfs, 493 MB free afterwards).
- Uplink injection failed earlier with `write failed -22` (EINVAL) on both 8 kHz mono and 48 kHz stereo input.
- `ATH` ended the call; `AT+CLCC` returned empty afterwards. No audio tool left running.

### Conclusion

Call control over VoLTE works. The blocker is the **host-PCM (HPCM) audio bridge**, not dialing:
the DSP still routes call audio to the ODU's internal codec path, and neither the in-call playback
device nor the HPCM capture stream opens with `hal_voice_test`'s default parameters. The HPCM
usecases exist in `/etc/audio_platform_info_extcodec.xml` (PCM ids 13-16) but those are AGM/audio-PCM
endpoints that are not exposed as plain ALSA nodes, so `arecord`/`aplay`-style access is not available
here. Enabling them requires the AGM path (`libagm` / `libagmmixer` metadata, i.e. what `agmvoiceui`
uses), not the X28 style `hw:X,Y` devices.
