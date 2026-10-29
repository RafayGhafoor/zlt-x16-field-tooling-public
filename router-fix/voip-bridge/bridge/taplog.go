// taplog.go — a size-capped, noise-filtering log sink for the PCM tap helper.
//
// The vendor library behind libolinterface.so.1 logs every internal function call
// to stderr (`<API> [F:...] is called!!`). Measured on this device that is about
// 24 kB/s while a call is up — ~85 MB/hour — and /data has ~130 MB free. Writing
// it verbatim is not an option, so the supervisor reads the helper's output line
// by line and keeps only what is worth keeping:
//
//   - the helper's own diagnostics (they start with '[')
//   - the handful of vendor messages that describe a state change we act on
//     ("stop writing", the read-thread timeout, stream open/close)
//
// Everything else is dropped. The file is also rotated at tap open and again
// mid-call if it grows past the cap, so a long call cannot eat the volume.

package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const tapLogMaxBytes = 512 * 1024

// vendorKeep are the vendor messages that carry information: they mark the PCM
// stream starting, stalling or being torn down, which is exactly what a
// supervisor needs in order to explain a silent call.
var vendorKeep = []string{
	"stop writing",
	"Timeout",
	"no echo",
	"pcmstream recv close",
	"pcmstream send close",
	"pcmstream not working",
	"recv pcm len",
	"record_release",
	"playbk_release",
	"Failed to",
	"PCMIO_Close",
	"StartPlay",
	"StopPlay",
}

type tapLog struct {
	mu    sync.Mutex
	path  string
	f     *os.File
	bytes int64
	drops int
	lines int
}

func newTapLog(path string) *tapLog {
	t := &tapLog{path: path}
	t.open()
	return t
}

func (t *tapLog) open() {
	_ = os.MkdirAll(filepath.Dir(t.path), 0o755)
	if fi, err := os.Stat(t.path); err == nil && fi.Size() > tapLogMaxBytes {
		_ = os.Rename(t.path, t.path+".1")
	}
	f, err := os.OpenFile(t.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.f = nil
		return
	}
	t.f = f
	if fi, err := f.Stat(); err == nil {
		t.bytes = fi.Size()
	}
	fmt.Fprintf(f, "\n=== %s tap log opened ===\n", time.Now().Format(time.RFC3339))
}

func (t *tapLog) rotateLocked() {
	if t.f == nil {
		return
	}
	_ = t.f.Close()
	t.f = nil
	_ = os.Rename(t.path, t.path+".1")
	t.bytes = 0
	t.open()
	if t.f != nil {
		fmt.Fprintf(t.f, "=== rotated at %s (%d dropped lines so far) ===\n",
			time.Now().Format(time.RFC3339), t.drops)
	}
}

func (t *tapLog) keep(line string) bool {
	if strings.HasPrefix(line, "[") {
		return true
	}
	for _, k := range vendorKeep {
		if strings.Contains(line, k) {
			return true
		}
	}
	return false
}

// pump reads the helper's combined output until EOF and writes the kept lines.
func (t *tapLog) pump(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 256*1024)
	for sc.Scan() {
		line := sc.Text()
		if !t.keep(line) {
			t.drops++
			continue
		}
		t.mu.Lock()
		if t.f == nil {
			t.mu.Unlock()
			continue
		}
		if t.bytes > tapLogMaxBytes {
			t.rotateLocked()
		}
		if t.f != nil {
			n, _ := t.f.WriteString(line + "\n")
			t.bytes += int64(n)
			t.lines++
		}
		t.mu.Unlock()
	}
}

func (t *tapLog) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.f != nil {
		fmt.Fprintf(t.f, "=== tap log closed at %s: %d lines kept, %d vendor lines dropped ===\n",
			time.Now().Format(time.RFC3339), t.lines, t.drops)
		_ = t.f.Close()
		t.f = nil
	}
}

// sessionSummary is what an operator actually wants from a call's audio: did
// audio flow in both directions, and how long did the stream last.
func (t *tapLog) sessionSummary(dlFrames, ulFrames uint64, started time.Time) string {
	var b bytes.Buffer
	fmt.Fprintf(&b, "tap summary: %s of audio, dl=%d frames, ul=%d frames, %d vendor lines dropped",
		time.Since(started).Round(time.Second), dlFrames, ulFrames, t.drops)
	return b.String()
}
