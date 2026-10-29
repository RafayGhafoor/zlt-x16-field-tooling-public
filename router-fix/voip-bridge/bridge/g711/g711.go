// Package g711 is the G.711 µ-law codec (WebRTC's mandatory PCMU audio codec).
//
// Using PCMU instead of Opus is the central design decision of this bridge: the
// X16's call audio is already 8 kHz mono S16_LE, and every WebRTC browser speaks
// µ-law at 8 kHz natively, so the bridge is a pure-Go cgo-free binary with no
// resampling in either direction.
package g711

// Standard G.711 µ-law, as in ITU-T G.711 / Sun's reference implementation.
const (
	ulawBias = 0x84
	ulawClip = 32635
)

var ulawSegEnd = [8]int{0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF, 0x3FFF, 0x7FFF}

// ulawEncode converts one linear 16-bit sample to a µ-law byte.
func EncodeSample(pcm int16) byte {
	mask := byte(0xFF)
	s := int(pcm)
	if s < 0 {
		s = -s
		mask = 0x7F
	}
	if s > ulawClip {
		s = ulawClip
	}
	s += ulawBias

	seg := 0
	for ; seg < 8; seg++ {
		if s <= ulawSegEnd[seg] {
			break
		}
	}
	if seg >= 8 {
		return 0x7F ^ mask
	}
	uval := byte(seg<<4) | byte((s>>(seg+3))&0x0F)
	return uval ^ mask
}

// ulawDecode converts one µ-law byte back to a linear 16-bit sample.
func DecodeSample(u byte) int16 {
	u = ^u
	t := (int(u&0x0F) << 3) + ulawBias
	t <<= (u & 0x70) >> 4
	var v int
	if u&0x80 != 0 {
		v = ulawBias - t
	} else {
		v = t - ulawBias
	}
	if v > 32767 {
		v = 32767
	} else if v < -32768 {
		v = -32768
	}
	return int16(v)
}

// pcmToUlaw encodes a little-endian S16 buffer into µ-law.
// `gain` is applied first (uplink level control).
func EncodePCM(pcm []byte, gain float64, out []byte) []byte {
	out = out[:0]
	for i := 0; i+1 < len(pcm); i += 2 {
		s := int16(uint16(pcm[i]) | uint16(pcm[i+1])<<8)
		if gain != 1.0 {
			v := float64(s) * gain
			switch {
			case v > 32767:
				v = 32767
			case v < -32768:
				v = -32768
			}
			s = int16(v)
		}
		out = append(out, EncodeSample(s))
	}
	return out
}

// ulawToPCM decodes µ-law into little-endian S16, applying `gain`.
func DecodePCM(ul []byte, gain float64, out []byte) []byte {
	out = out[:0]
	for _, b := range ul {
		s := DecodeSample(b)
		if gain != 1.0 {
			v := float64(s) * gain
			switch {
			case v > 32767:
				v = 32767
			case v < -32768:
				v = -32768
			}
			s = int16(v)
		}
		out = append(out, byte(uint16(s)), byte(uint16(s)>>8))
	}
	return out
}
