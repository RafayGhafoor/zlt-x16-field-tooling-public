#!/usr/bin/env python3
"""decode_nv.py -- turn nv-read.sh output into band lists a human can check.

Input is the JSONL produced by nv-read.sh (`<path>|<json>` per line).

Bitmask convention, verified against this modem rather than assumed:

  * the value is little-endian u32 words
  * band N is bit (N-1), so word w bit b is band 32*w + b + 1
  * `lte_bandpref` is 8 bytes (2 words), the NR preference items are 64 bytes

Cross-check that made this trustworthy: `lte_bandpref` decodes to
1:3:5:28:38:41, which is byte-for-byte the list `AT+CSYSSEL="lte_band"`
returns. If a decoder disagrees with the AT layer on that item, the decoder is
wrong -- not the modem.

Most /nv/item_files/modem/lte/rrc/efs/* names that appear inside the modem
image are firmware DEFAULTS; reading them live gives "bad length (0x15)".
That is reported here as "not present", which is a real finding, not an error.
"""

import base64
import json
import struct
import sys

BITMASKS = {
    "/nv/item_files/modem/mmode/lte_bandpref": 2,
    "/nv/item_files/modem/mmode/lte_bandpref_extn_65_256": 6,
    "/nv/item_files/modem/mmode/nr_band_pref": 16,
    "/nv/item_files/modem/mmode/nr_nsa_band_pref": 16,
}

# mode_pref bits as this modem uses them (0x50 = 0x10 | 0x40 observed live,
# with CNMP=109 = LTE+NR at the AT layer).
MODE_BITS = [
    (0x01, "1X"), (0x02, "HDR"), (0x04, "GSM"), (0x08, "WCDMA"),
    (0x10, "LTE"), (0x20, "TDSCDMA"), (0x40, "NR5G"), (0x80, "NR5G-SA"),
]


def decode_bands(raw: bytes, nwords: int):
    words = struct.unpack("<%dI" % nwords, raw[: 4 * nwords])
    out = []
    for wi, w in enumerate(words):
        for bit in range(32):
            if w & (1 << bit):
                out.append(32 * wi + bit + 1)
    return out


def main(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if "|" not in line:
                continue
            p, _, js = line.partition("|")
            try:
                rows.append((p, json.loads(js)))
            except json.JSONDecodeError:
                rows.append((p, {"ok": False, "error": "unparsable reply"}))

    width = max((len(p) for p, _ in rows), default=10)

    for p, r in rows:
        name = p.rsplit("/", 1)[-1]
        if not r.get("ok"):
            err = r.get("error", "")
            if "bad length" in err:
                note = "NOT PRESENT (firmware default only, not set on device)"
            else:
                note = err[:70]
            print(f"  {name:<{width}}  {note}")
            continue

        raw = base64.b64decode(r.get("data", ""))
        if p in BITMASKS:
            bands = decode_bands(raw, BITMASKS[p])
            print(f"  {name:<{width}}  bands {' '.join(str(b) for b in bands) if bands else '(none)'}"
                  f"   [{raw.hex()}]")
        elif name == "mode_pref" and len(raw) >= 4:
            v = struct.unpack("<I", raw[:4])[0]
            modes = [n for bit, n in MODE_BITS if v & bit]
            print(f"  {name:<{width}}  0x{v:02x} = {'+'.join(modes) if modes else '?'}")
        elif name == "nr5g_disable_mode":
            v = raw[0] if raw else -1
            meaning = {0: "NR enabled", 1: "NR DISABLED", 2: "NR SA disabled",
                       3: "NR NSA and SA disabled"}.get(v, "?")
            print(f"  {name:<{width}}  {v} = {meaning}")
        elif name == "ue_usage_setting":
            v = raw[0] if raw else -1
            print(f"  {name:<{width}}  {v} = "
                  f"{'data-centric' if v == 1 else 'voice-centric' if v == 0 else '?'}")
        else:
            print(f"  {name:<{width}}  {len(raw)} bytes   {raw[:24].hex()}"
                  f"{'...' if len(raw) > 24 else ''}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1])
