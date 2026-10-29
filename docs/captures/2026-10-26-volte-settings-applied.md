# X16 VoLTE settings — change and immediate verification

Applied 2026-10-26 after the read-only baseline in `2026-10-26-volte-prechange.md`.

## Change

Saved and committed these `mdlcfg` values:

| Key | Before | After |
|---|---:|---:|
| `SYS_VOLTE_SW` | `0` | `1` |
| `USR_VOICE_TYPE` | `1` (VoIP selection) | `0` (VoLTE selection) |
| `SYS_VOICE_TYPE_AUTO_SW` | `0` | unchanged |
| `USR_VOIP_SW` | `0` | unchanged |

On-device pre-change backup and restore script:

- `/data/zlt-backups/20261026/volte-webrtc/mdlcfg-settings-before.txt`
- `/data/zlt-backups/20261026/volte-webrtc/restore-voice-settings.sh`

Rollback command:

```sh
sh /data/zlt-backups/20261026/volte-webrtc/restore-voice-settings.sh
```

## Immediate verification

- `mdlcfg -g` readback returned `SYS_VOLTE_SW=1`, `USR_VOICE_TYPE=0`, `SYS_VOICE_TYPE_AUTO_SW=0`, `USR_VOIP_SW=0`.
- `tz_phone` was running on the post-change check; `alsa_daemon` remained running. No VoIP client process was present.
- QManager units remained active; HTTP GET to `127.0.0.1:8080/` returned `200`.
- WAN route remained on `rmnet_data0`; the interface counters continued increasing.
- No reboot, service restart, AT call command, or call was issued. No call was placed.

The settings are saved. The live cellular call path and carrier IMS/VoLTE registration are **not yet verified**. A test call still requires explicit authorization and an agreed destination; carrier charges may apply. No further setting or service changes should be made until that test is planned.
