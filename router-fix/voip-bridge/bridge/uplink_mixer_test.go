package main

import (
	"encoding/binary"
	"testing"
	"time"
)

func pcmFrame(v int16) []byte {
	b := make([]byte, frameBytes)
	for i := 0; i < frameSamples; i++ {
		binary.LittleEndian.PutUint16(b[i*2:], uint16(v))
	}
	return b
}

func pcmSamples(v int16, samples int) []byte {
	b := make([]byte, samples*2)
	for i := 0; i < samples; i++ {
		binary.LittleEndian.PutUint16(b[i*2:], uint16(v))
	}
	return b
}

func sampleAt(b []byte, i int) int16 {
	return int16(binary.LittleEndian.Uint16(b[i*2:]))
}

func TestUplinkMixerAlignsAndDoesNotAttenuateOneSpeakerForMutedPeer(t *testing.T) {
	m := newUplinkMixer()
	if !m.Add(1) || !m.Add(2) {
		t.Fatal("could not add two peers")
	}
	m.Push(1, pcmFrame(1200))
	m.Push(2, pcmFrame(0)) // a connected muted track
	out, contributors := m.NextFrame()
	if contributors != 1 {
		t.Fatalf("contributors=%d, want 1", contributors)
	}
	if got := sampleAt(out, 0); got != 1200 {
		t.Fatalf("muted peer attenuated the talker: sample=%d, want 1200", got)
	}
}

func TestUplinkMixerAveragesTwoTalkersToAvoidClipping(t *testing.T) {
	m := newUplinkMixer()
	m.Add(1)
	m.Add(2)
	m.Push(1, pcmFrame(12000))
	m.Push(2, pcmFrame(12000))
	out, contributors := m.NextFrame()
	if contributors != 2 {
		t.Fatalf("contributors=%d, want 2", contributors)
	}
	if got := sampleAt(out, 0); got != 12000 {
		t.Fatalf("sum should be averaged: sample=%d, want 12000", got)
	}
}

func TestUplinkMixerPadsLatePeerAndBoundsParticipantCount(t *testing.T) {
	m := newUplinkMixer()
	for i := uint64(0); i < mixMaxPeers; i++ {
		if !m.Add(i) {
			t.Fatalf("could not add peer %d", i)
		}
	}
	if m.Add(mixMaxPeers) {
		t.Fatal("accepted more peers than the bounded mixer supports")
	}
	m.Push(0, pcmFrame(1000))
	out, contributors := m.NextFrame()
	if contributors != 1 || sampleAt(out, 0) != 1000 {
		t.Fatalf("late peers changed the frame: contributors=%d sample=%d", contributors, sampleAt(out, 0))
	}
	if got := len(out); got != frameBytes {
		t.Fatalf("frame length=%d, want %d", got, frameBytes)
	}
}

func TestUplinkMixerBuffersTenMillisecondPacketsIntoPhoneFrames(t *testing.T) {
	m := newUplinkMixer()
	m.Add(1)
	m.PushRTP(1, 1, 0, pcmSamples(1400, 80))
	out, contributors := m.NextFrame()
	if contributors != 0 || sampleAt(out, 0) != 0 {
		t.Fatalf("a half-frame must wait, not be played as a half-silence frame")
	}
	m.PushRTP(1, 2, 80, pcmSamples(1400, 80))
	out, contributors = m.NextFrame()
	if contributors != 1 || sampleAt(out, 0) != 1400 || sampleAt(out, 159) != 1400 {
		t.Fatalf("two 10ms packets should become one 20ms frame: contributors=%d first=%d last=%d",
			contributors, sampleAt(out, 0), sampleAt(out, 159))
	}
}

func TestUplinkMixerReordersRTPBeforeModemFrame(t *testing.T) {
	m := newUplinkMixer()
	m.Add(1)

	m.PushRTP(1, 10, 0, pcmFrame(1000))
	if got, n := m.NextFrame(); n != 1 || sampleAt(got, 0) != 1000 {
		t.Fatalf("first packet: contributors=%d sample=%d", n, sampleAt(got, 0))
	}

	// Sequence 12 arrives before 11. The mixer waits briefly instead of sending
	// 12's speech in the slot where 11 belongs.
	m.PushRTP(1, 12, 320, pcmFrame(3000))
	if got, n := m.NextFrame(); n != 0 || sampleAt(got, 0) != 0 {
		t.Fatalf("out-of-order packet played early: contributors=%d sample=%d", n, sampleAt(got, 0))
	}
	m.PushRTP(1, 11, 160, pcmFrame(2000))
	if got, n := m.NextFrame(); n != 1 || sampleAt(got, 0) != 2000 {
		t.Fatalf("reordered packet: contributors=%d sample=%d", n, sampleAt(got, 0))
	}
	if got, n := m.NextFrame(); n != 1 || sampleAt(got, 0) != 3000 {
		t.Fatalf("packet after reorder: contributors=%d sample=%d", n, sampleAt(got, 0))
	}
}

func TestUplinkMixerTurnsLostRTPIntoSilenceThenResumes(t *testing.T) {
	m := newUplinkMixer()
	m.Add(1)
	m.PushRTP(1, 20, 0, pcmFrame(1000))
	m.NextFrame()
	m.PushRTP(1, 22, 320, pcmFrame(3000)) // sequence 21 was lost

	m.NextFrame() // starts the 40ms reorder window
	time.Sleep(mixReorderWait + 10*time.Millisecond)
	gap, n := m.NextFrame() // one 20ms silence slot for the missing packet
	if n != 0 || sampleAt(gap, 0) != 0 {
		t.Fatalf("lost packet did not become silence: contributors=%d sample=%d", n, sampleAt(gap, 0))
	}
	resumed, n := m.NextFrame()
	if n != 1 || sampleAt(resumed, 0) != 3000 {
		t.Fatalf("audio did not resume after gap: contributors=%d sample=%d", n, sampleAt(resumed, 0))
	}
}
