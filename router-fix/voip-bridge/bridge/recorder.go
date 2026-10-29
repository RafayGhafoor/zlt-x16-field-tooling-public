// recorder.go — call recording, as one stereo WAV per call.
//
// Left is the far end, right is this browser's microphone. That layout is a
// deliberate choice over two files or a mixdown:
//
//   - a mixdown cannot answer "what did they actually say" once both sides talk
//     at once, which is the one thing a call recording is opened to check;
//   - two files have to be re-aligned by hand to listen to a conversation;
//   - any player can play a stereo WAV, and a browser can separate the channels
//     later if it needs to.
//
// The two directions arrive independently (tap callback and WebRTC RTP), so they
// are buffered and interleaved on a 20 ms clock by a writer goroutine. A side
// that is silent — the far end before the browser connects, or the mic when it is
// muted — writes silence rather than nothing, so the channel pairing never drifts.

package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	recFrameSamples = 160 // 20 ms at 8 kHz, one stereo frame pair
	recRingSamples  = 8000 * 4
)

// Recorder writes one file per answered call and enforces retention.
type Recorder struct {
	mu      sync.Mutex
	dir     string
	enabled bool
	keep    int
	cur     *recSession
	lastErr string
}

type recSession struct {
	number    string
	direction string
	path      string
	f         *os.File
	started   time.Time
	samples   uint32

	downBuf []int16
	upBuf   []int16

	stop  chan struct{}
	done  chan struct{}
	mu    sync.Mutex
	final bool
}

func NewRecorder(dir string, enabled bool, keep int) *Recorder {
	if keep <= 0 {
		keep = 50
	}
	_ = os.MkdirAll(dir, 0o755)
	return &Recorder{dir: dir, enabled: enabled, keep: keep}
}

func (r *Recorder) Enabled() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.enabled
}

func (r *Recorder) SetEnabled(on bool) {
	r.mu.Lock()
	r.enabled = on
	r.mu.Unlock()
	if !on {
		r.Stop()
	}
}

func (r *Recorder) Recording() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cur != nil
}

var unsafeName = regexp.MustCompile(`[^0-9A-Za-z+*#_-]+`)

// Start opens a new recording for a call that has just been answered.
func (r *Recorder) Start(number, direction string) {
	r.mu.Lock()
	if !r.enabled || r.cur != nil {
		r.mu.Unlock()
		return
	}
	num := unsafeName.ReplaceAllString(strings.TrimSpace(number), "")
	if num == "" {
		num = "unknown"
	}
	dir := unsafeName.ReplaceAllString(direction, "")
	if dir == "" {
		dir = "call"
	}
	name := fmt.Sprintf("%s_%s_%s.wav", time.Now().Format("20060102-150405"), dir, num)
	path := filepath.Join(r.dir, name)

	f, err := os.Create(path)
	if err != nil {
		r.lastErr = err.Error()
		r.mu.Unlock()
		return
	}

	sess := &recSession{
		number: number, direction: direction, path: path, f: f,
		started: time.Now(), stop: make(chan struct{}), done: make(chan struct{}),
	}
	if err := writeWAVHeader(f); err != nil {
		f.Close()
		_ = os.Remove(path)
		r.lastErr = err.Error()
		r.mu.Unlock()
		return
	}
	r.cur = sess
	r.mu.Unlock()

	go sess.run(r)
}

// WriteDown feeds the far end's audio (left channel).
func (r *Recorder) WriteDown(pcm []byte) {
	r.mu.Lock()
	s := r.cur
	r.mu.Unlock()
	if s == nil {
		return
	}
	s.push(&s.downBuf, pcm)
}

// WriteUp feeds the browser's audio (right channel).
func (r *Recorder) WriteUp(pcm []byte) {
	r.mu.Lock()
	s := r.cur
	r.mu.Unlock()
	if s == nil {
		return
	}
	s.push(&s.upBuf, pcm)
}

func (s *recSession) push(dst *[]int16, pcm []byte) {
	if len(pcm) < 2 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Drop on overflow rather than grow without bound: a stalled writer must not
	// turn a 10-minute call into an out-of-memory on a 645 MB device.
	if len(*dst) > recRingSamples {
		*dst = (*dst)[len(*dst)-recRingSamples:]
	}
	for i := 0; i+1 < len(pcm); i += 2 {
		*dst = append(*dst, int16(uint16(pcm[i])|uint16(pcm[i+1])<<8))
	}
}

func (s *recSession) take(dst *[]int16, n int) []int16 {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]int16, n)
	if len(*dst) >= n {
		copy(out, (*dst)[:n])
		*dst = (*dst)[n:]
		return out
	}
	copy(out, *dst)
	*dst = (*dst)[:0]
	return out // remainder is silence
}

func (s *recSession) run(r *Recorder) {
	defer close(s.done)
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()

	frame := make([]byte, recFrameSamples*4) // L,R interleaved S16
	for {
		select {
		case <-s.stop:
			// Flush what is buffered so the tail of the call is not lost.
			for {
				s.mu.Lock()
				remaining := len(s.downBuf) + len(s.upBuf)
				s.mu.Unlock()
				if remaining == 0 {
					break
				}
				s.writeFrame(frame)
			}
			return
		case <-ticker.C:
			s.writeFrame(frame)
		}
	}
}

func (s *recSession) writeFrame(frame []byte) {
	down := s.take(&s.downBuf, recFrameSamples)
	up := s.take(&s.upBuf, recFrameSamples)
	for i := 0; i < recFrameSamples; i++ {
		binary.LittleEndian.PutUint16(frame[i*4:], uint16(down[i]))
		binary.LittleEndian.PutUint16(frame[i*4+2:], uint16(up[i]))
	}
	if _, err := s.f.Write(frame); err != nil {
		return
	}
	s.samples += recFrameSamples
}

// Stop finishes the current recording: the WAV header is patched with the real
// sizes, because a file whose header still claims zero is rejected by players.
func (r *Recorder) Stop() {
	r.mu.Lock()
	s := r.cur
	r.cur = nil
	r.mu.Unlock()
	if s == nil {
		return
	}

	close(s.stop)
	<-s.done

	s.mu.Lock()
	s.final = true
	s.mu.Unlock()

	dataBytes := s.samples * 4
	if _, err := s.f.Seek(4, 0); err == nil {
		if _, err := s.f.Write(wavChunkSize(dataBytes + 36)); err != nil {
			r.setErr(err.Error())
		}
	}
	if _, err := s.f.Seek(40, 0); err == nil {
		if _, err := s.f.Write(wavChunkSize(dataBytes)); err != nil {
			r.setErr(err.Error())
		}
	}
	if err := s.f.Close(); err != nil {
		r.setErr(err.Error())
	}
	r.enforceRetention()
	r.pruneEmpty(s)
}

func (r *Recorder) setErr(e string) {
	r.mu.Lock()
	r.lastErr = e
	r.mu.Unlock()
}

// pruneEmpty removes a recording that captured nothing at all (a call answered
// and dropped in the same second), so the list does not fill with 0-second files.
func (r *Recorder) pruneEmpty(s *recSession) {
	if s.samples == 0 {
		_ = os.Remove(s.path)
	}
}

func (r *Recorder) enforceRetention() {
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		return
	}
	type f struct {
		name string
		mod  time.Time
	}
	var files []f
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".wav") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		files = append(files, f{e.Name(), info.ModTime()})
	}
	if len(files) <= r.keep {
		return
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.After(files[j].mod) })
	for _, old := range files[r.keep:] {
		_ = os.Remove(filepath.Join(r.dir, old.name))
	}
}

// ---------------------------------------------------------------- listing ---

// RecordingInfo is one row for the page: enough to identify the call without
// opening the file.
type RecordingInfo struct {
	Name      string `json:"name"`
	Number    string `json:"number"`
	Direction string `json:"direction"`
	StartedAt int64  `json:"started_at"`
	Seconds   int    `json:"seconds"`
	Bytes     int64  `json:"bytes"`
}

var recNameRe = regexp.MustCompile(`^([0-9]{8}-[0-9]{6})_(outgoing|incoming|call)_([0-9A-Za-z+*#_-]*)\.wav$`)

func (r *Recorder) List() []RecordingInfo {
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		return nil
	}
	out := make([]RecordingInfo, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := recNameRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		t, _ := time.ParseInLocation("20060102-150405", m[1], time.Local)
		// 44-byte header, 4 bytes per stereo frame at 8 kHz.
		seconds := 0
		if info.Size() > 44 {
			seconds = int((info.Size() - 44) / 32000)
		}
		out = append(out, RecordingInfo{
			Name: e.Name(), Number: m[3], Direction: m[2],
			StartedAt: t.Unix(), Seconds: seconds, Bytes: info.Size(),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt > out[j].StartedAt })
	return out
}

// PathFor resolves a request name to a file inside the recordings directory.
// The name is matched against the recording pattern BEFORE touching the
// filesystem, so a crafted name cannot walk out of the directory.
func (r *Recorder) PathFor(name string) (string, bool) {
	if !recNameRe.MatchString(name) {
		return "", false
	}
	p := filepath.Join(r.dir, name)
	if _, err := os.Stat(p); err != nil {
		return "", false
	}
	return p, true
}

func (r *Recorder) Delete(name string) bool {
	p, ok := r.PathFor(name)
	if !ok {
		return false
	}
	return os.Remove(p) == nil
}

// --------------------------------------------------------------- wav bits ---

func wavChunkSize(n uint32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, n)
	return b
}

func writeWAVHeader(f *os.File) error {
	h := make([]byte, 0, 44)
	h = append(h, []byte("RIFF")...)
	h = append(h, wavChunkSize(36)...)
	h = append(h, []byte("WAVEfmt ")...)
	h = append(h, wavChunkSize(16)...)
	h = append(h, []byte{1, 0}...)               // PCM
	h = append(h, []byte{2, 0}...)               // 2 channels
	h = append(h, wavChunkSize(sampleRate)...)   // sample rate
	h = append(h, wavChunkSize(sampleRate*4)...) // byte rate (2ch * 2B)
	h = append(h, []byte{4, 0}...)               // block align
	h = append(h, []byte{16, 0}...)              // bits per sample
	h = append(h, []byte("data")...)
	h = append(h, wavChunkSize(0)...)
	_, err := f.Write(h)
	return err
}

// unusedJSON keeps the file honest about what it serialises if a caller wants
// the raw session, without adding an import that is otherwise dead.
var _ = json.Marshal
var _ = strconv.Itoa
