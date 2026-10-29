package main

import (
	"encoding/binary"
	"os"
	"testing"
)

func TestRecorderWritesPlayableStereoWAV(t *testing.T) {
	dir := t.TempDir()
	r := NewRecorder(dir, true, 5)

	r.Start("03154308207", "outgoing")
	if !r.Recording() {
		t.Fatal("Start did not mark the recorder active")
	}

	// Two seconds of "far end" (L) and silence from the mic (R), 20 ms at a time.
	frame := make([]byte, 320)
	for i := 0; i < 100; i++ {
		for j := 0; j < 160; j++ {
			v := int16(1000)
			binary.LittleEndian.PutUint16(frame[j*2:], uint16(v))
		}
		r.WriteDown(frame)
	}
	r.Stop()

	list := r.List()
	if len(list) != 1 {
		t.Fatalf("list has %d recordings, want 1", len(list))
	}
	info := list[0]
	if info.Number != "03154308207" || info.Direction != "outgoing" {
		t.Fatalf("metadata wrong: %+v", info)
	}

	path, ok := r.PathFor(info.Name)
	if !ok {
		t.Fatal("PathFor rejected a name List produced")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) < 44 {
		t.Fatalf("file too small: %d bytes", len(b))
	}
	// The header must have been patched: an unpatched one claims 0 bytes and
	// players refuse it.
	riff := binary.LittleEndian.Uint32(b[4:8])
	data := binary.LittleEndian.Uint32(b[40:44])
	if int(riff) != len(b)-8 {
		t.Fatalf("RIFF size %d, want %d", riff, len(b)-8)
	}
	if int(data) != len(b)-44 {
		t.Fatalf("data size %d, want %d", data, len(b)-44)
	}
	if info.Seconds <= 0 {
		t.Fatalf("seconds = %d, want > 0", info.Seconds)
	}
}

func TestRecorderSkipsWhenDisabledAndRejectsBadNames(t *testing.T) {
	dir := t.TempDir()
	r := NewRecorder(dir, false, 5)
	r.Start("111", "outgoing")
	if r.Recording() {
		t.Fatal("recording started while disabled")
	}
	if _, ok := r.PathFor("../../etc/passwd"); ok {
		t.Fatal("PathFor accepted a traversal attempt")
	}
	if _, ok := r.PathFor("not-a-recording.wav"); ok {
		t.Fatal("PathFor accepted a name that is not a recording")
	}
}
