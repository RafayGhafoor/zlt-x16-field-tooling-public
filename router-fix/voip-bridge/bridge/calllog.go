// calllog.go — a small, durable call history.
//
// The records are built by the poller from the modem's own AT+CLCC entries, not
// from what the UI did: a call placed from the vendor app, from another browser,
// or received while nobody was looking all land here the same way. That is the
// point of a call log on a router — it is the record of the device's calls, not
// of one page's actions.
//
// Storage is JSON lines at /data/webrtc/log/calls.jsonl (bounded, rewritten
// atomically). JSONL rather than a single JSON array so a truncated write can
// only ever cost the last line, never the whole history.

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// CallRecord is one call as the modem saw it.
//
// `AnsweredAt == 0` means the call never reached the answered state — the
// difference between "nobody picked up" and "the call failed" is the outcome
// string, which is decided when the call ends.
type CallRecord struct {
	ID         uint64 `json:"id"`
	Number     string `json:"number"`
	Direction  string `json:"direction"`  // outgoing | incoming
	StartedAt  int64  `json:"started_at"` // unix seconds
	AnsweredAt int64  `json:"answered_at"`
	EndedAt    int64  `json:"ended_at"`
	Seconds    int    `json:"seconds"` // talk time, 0 when never answered
	Outcome    string `json:"outcome"` // answered | no_answer | missed | failed
}

const (
	outcomeAnswered = "answered"
	outcomeNoAnswer = "no_answer"
	outcomeMissed   = "missed"
	outcomeFailed   = "failed"
)

type callLog struct {
	mu      sync.Mutex
	path    string
	max     int
	entries []CallRecord
	nextID  uint64
}

func newCallLog(path string, max int) *callLog {
	l := &callLog{path: path, max: max}
	l.load()
	return l
}

func (l *callLog) load() {
	f, err := os.Open(l.path)
	if err != nil {
		return
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		var r CallRecord
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			continue // a torn line from a power cut: skip it, keep the rest
		}
		if r.ID >= l.nextID {
			l.nextID = r.ID + 1
		}
		l.entries = append(l.entries, r)
	}
	if len(l.entries) > l.max {
		l.entries = l.entries[len(l.entries)-l.max:]
	}
}

// Add appends one finished call and rewrites the file atomically.
func (l *callLog) Add(r CallRecord) CallRecord {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.nextID++
	r.ID = l.nextID
	l.entries = append(l.entries, r)
	if len(l.entries) > l.max {
		l.entries = l.entries[len(l.entries)-l.max:]
	}
	l.persistLocked()
	return r
}

// List returns the newest `limit` calls (all of them when limit <= 0).
func (l *callLog) List(limit int) []CallRecord {
	l.mu.Lock()
	defer l.mu.Unlock()

	out := make([]CallRecord, len(l.entries))
	copy(out, l.entries)
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt > out[j].StartedAt })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

func (l *callLog) Count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries)
}

func (l *callLog) Clear() error {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.entries = nil
	if err := os.Remove(l.path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// persistLocked writes the whole file. It is called once per finished call, so
// the cost is one small rewrite per hang-up rather than per packet.
func (l *callLog) persistLocked() {
	if err := os.MkdirAll(filepath.Dir(l.path), 0o755); err != nil {
		return
	}
	tmp := l.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	for _, r := range l.entries {
		b, err := json.Marshal(r)
		if err != nil {
			continue
		}
		if _, err := w.Write(append(b, '\n')); err != nil {
			break
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return
	}
	if err := f.Close(); err != nil {
		return
	}
	_ = os.Rename(tmp, l.path)
}

// formatSeconds is the UI's business, but the bridge is the only place that
// knows a talk time, so it also answers "how long was that" without the page
// recomputing timezone-sensitive arithmetic.
func formatSeconds(sec int) string {
	if sec <= 0 {
		return "0:00"
	}
	m := sec / 60
	s := sec % 60
	if m >= 60 {
		return fmt.Sprintf("%d:%02d:%02d", m/60, m%60, s)
	}
	return fmt.Sprintf("%d:%02d", m, s)
}
