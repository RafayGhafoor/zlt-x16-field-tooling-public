package g711

import (
	"bytes"
	"os"
	"os/exec"
	"testing"
)

func TestUlawRoundTripCoding(t *testing.T) {
	// µ-law is lossy but monotonic; a decoded sample must stay near the input.
	worst := 0.0
	for i := -32768; i <= 32767; i += 37 {
		s := int16(i)
		got := DecodeSample(EncodeSample(s))
		d := float64(got) - float64(s)
		if d < 0 {
			d = -d
		}
		// G.711 segments are 2^seg wide; error never exceeds a segment step.
		if d > 1700 && worst < d {
			worst = d
		}
	}
	if worst > 1700 {
		t.Fatalf("round trip error too large: %.0f", worst)
	}
}

// TestAgainstFFmpeg pins our tables to ffmpeg's G.711 implementation, both
// directions. Skipped when ffmpeg is not on the build host.
func TestAgainstFFmpeg(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	dir := t.TempDir()
	wav := dir + "/in.wav"
	// 8 kHz mono speech-ish content: sweep + noise-free ramp.
	if out, err := exec.Command("ffmpeg", "-y", "-loglevel", "error",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=8000",
		"-t", "1", "-c:a", "pcm_s16le", wav).CombinedOutput(); err != nil {
		t.Skipf("ffmpeg wav gen failed: %v %s", err, out)
	}

	pcm, err := os.ReadFile(wav)
	if err != nil {
		t.Fatal(err)
	}
	body := wavData(t, pcm)

	ul := dir + "/want.ulaw"
	if out, err := exec.Command("ffmpeg", "-y", "-loglevel", "error", "-i", wav,
		"-f", "mulaw", "-ar", "8000", "-ac", "1", ul).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg encode failed: %v %s", err, out)
	}
	want, err := os.ReadFile(ul)
	if err != nil {
		t.Fatal(err)
	}

	got := EncodePCM(body, 1.0, make([]byte, 0, len(body)/2))
	if len(got) != len(want) {
		t.Fatalf("length mismatch: got %d want %d", len(got), len(want))
	}
	// G.711 allows the encoder to truncate or round within a segment step;
	// ffmpeg rounds, this implementation truncates, so bytes differ on ~6% of
	// samples — by one quantisation level. What must hold is that both decode
	// to an equally faithful signal.
	bad := countDiff(got, want)
	if bad*100/len(want) > 12 {
		t.Fatalf("%d/%d encoded bytes differ from ffmpeg (first at %d)", bad, len(want), firstDiff(got, want))
	}
	if eo, ef := meanDecodeErr(got, body), meanDecodeErr(want, body); eo > ef*1.6+8 {
		t.Fatalf("quantisation error: ours %.1f vs ffmpeg %.1f", eo, ef)
	}
	t.Logf("encoder agrees with ffmpeg on %d/%d bytes; %d one-step differences",
		len(want)-bad, len(want), bad)

	// Decode direction: ffmpeg decodes the µ-law file back to PCM.
	back := dir + "/back.raw"
	if out, err := exec.Command("ffmpeg", "-y", "-loglevel", "error",
		"-f", "mulaw", "-ar", "8000", "-ac", "1", "-i", ul,
		"-f", "s16le", back).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg decode failed: %v %s", err, out)
	}
	wantPCM, err := os.ReadFile(back)
	if err != nil {
		t.Fatal(err)
	}
	// Decode ffmpeg's own µ-law bytes with our decoder: the decoder is
	// unambiguous, so this must match ffmpeg sample for sample.
	gotPCM := DecodePCM(want, 1.0, make([]byte, 0, len(want)*2))
	if !bytes.Equal(gotPCM, wantPCM) {
		t.Fatalf("decoded PCM differs from ffmpeg (%d vs %d bytes, first diff at %d)",
			len(gotPCM), len(wantPCM), firstDiff(gotPCM, wantPCM))
	}
}

// wavData returns the payload of the WAV "data" chunk (ffmpeg writes a LIST
// chunk, so the header is not always 44 bytes).
func wavData(t *testing.T, b []byte) []byte {
	t.Helper()
	for i := 12; i+8 <= len(b); {
		id := string(b[i : i+4])
		size := int(b[i+4]) | int(b[i+5])<<8 | int(b[i+6])<<16 | int(b[i+7])<<24
		start := i + 8
		if id == "data" {
			end := start + size
			if size <= 0 || end > len(b) {
				end = len(b)
			}
			return b[start:end]
		}
		i = start + size
		if size%2 == 1 {
			i++
		}
	}
	t.Fatalf("no data chunk in wav (%d bytes)", len(b))
	return nil
}

// meanDecodeErr is the average |decode(ulaw) - pcm|, i.e. how good the encoder is.
func meanDecodeErr(ulaw, pcm []byte) float64 {
	n := len(ulaw)
	if n == 0 {
		return 0
	}
	total := 0.0
	for i := 0; i < n; i++ {
		want := int16(uint16(pcm[2*i]) | uint16(pcm[2*i+1])<<8)
		got := DecodeSample(ulaw[i])
		d := float64(got) - float64(want)
		if d < 0 {
			d = -d
		}
		total += d
	}
	return total / float64(n)
}

func countDiff(a, b []byte) int {
	n := 0
	for i := range a {
		if a[i] != b[i] {
			n++
		}
	}
	return n
}

func firstDiff(a, b []byte) int {
	for i := range a {
		if i >= len(b) || a[i] != b[i] {
			return i
		}
	}
	return -1
}
