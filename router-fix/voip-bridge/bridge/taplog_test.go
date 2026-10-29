package main

import (
	"strings"
	"testing"
)

func TestKeepFiltersVendorNoise(t *testing.T) {
	tl := &tapLog{}
	keep := []string{
		"[pcm] PCMIO_Open rc=0 mode=3 dir=2 rate=8000 frame=320",
		"[dl] cb #1 len=320 total=320",
		"<INFO> [F:Sunsea_Audio_PCMIO_SendPcm,L:1109] >>> Sunsea_Audio_PCMIO_SendPcm: status has changed -----> stop writing",
		"<ERRO> [F:audio_pcmstream_read_thread,L:810] >>> audio_pcmstream_read_thread-810: Timeout.",
	}
	drop := []string{
		"<API> [F:Sunsea_Audio_PCMIO_Open,L:970,sec:1793011320,usec:411244] is called!!",
		"diag:successfully connected to socket 5",
		"<TEST> [F:Sunsea_Audio_PCMIO_SendPcm,L:1092,sec:1793011320,usec:472909]",
		"<API> [F:create_pcmstream_sem,L:698] is called!!",
	}
	for _, l := range keep {
		if !tl.keep(l) {
			t.Errorf("should keep: %s", l)
		}
	}
	for _, l := range drop {
		if tl.keep(l) {
			t.Errorf("should drop: %s", l)
		}
	}
}

func TestPumpWritesOnlyKeptLinesAndRotates(t *testing.T) {
	dir := t.TempDir()
	tl := newTapLog(dir + "/audio.log")
	defer tl.Close()

	var sb strings.Builder
	for i := 0; i < 200000; i++ { // enough vendor noise to force a rotation
		sb.WriteString("<API> [F:Sunsea_Audio_PCMIO_SendPcm,L:1092,sec:1,usec:1] is called!!\n")
	}
	sb.WriteString("[pcm] PCMIO_Open rc=0\n")
	tl.pump(strings.NewReader(sb.String()))

	if tl.lines != 1 {
		t.Fatalf("kept %d lines, want 1", tl.lines)
	}
	if tl.drops == 0 {
		t.Fatal("nothing was dropped — filter is not active")
	}
}
