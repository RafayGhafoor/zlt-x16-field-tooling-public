package main

import (
	"os"
	"path/filepath"
	"testing"
)

func rec(number string, started, answered int64) CallRecord {
	return CallRecord{Number: number, Direction: "outgoing", StartedAt: started, AnsweredAt: answered}
}

func TestCallLogPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log", "calls.jsonl")

	l := newCallLog(path, 10)
	a := l.Add(rec("111", 100, 104))
	if a.ID == 0 {
		t.Fatal("Add did not assign an ID")
	}
	l.Add(rec("222", 200, 210))

	// A fresh instance must read back what the first one wrote — that is what
	// makes the history survive the bridge being restarted.
	l2 := newCallLog(path, 10)
	if got := l2.Count(); got != 2 {
		t.Fatalf("reloaded %d entries, want 2", got)
	}
	list := l2.List(0)
	if list[0].Number != "222" {
		t.Fatalf("newest first expected, got %q", list[0].Number)
	}
	if list[0].ID <= list[1].ID {
		t.Fatalf("IDs must increase: %d then %d", list[0].ID, list[1].ID)
	}
}

func TestCallLogCapsAndClears(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "calls.jsonl")

	l := newCallLog(path, 3)
	for i := 0; i < 10; i++ {
		l.Add(rec("1", int64(i), int64(i)))
	}
	if got := l.Count(); got != 3 {
		t.Fatalf("kept %d entries, want the cap of 3", got)
	}
	if got := l.List(2); len(got) != 2 {
		t.Fatalf("limit ignored: got %d", len(got))
	}

	if err := l.Clear(); err != nil {
		t.Fatal(err)
	}
	if l.Count() != 0 {
		t.Fatal("Clear left entries behind")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("Clear should remove the file")
	}
	if got := newCallLog(path, 3).Count(); got != 0 {
		t.Fatalf("cleared log came back with %d entries", got)
	}
}

func TestCallLogSurvivesTornLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "calls.jsonl")
	if err := os.WriteFile(path, []byte(`{"id":1,"number":"111","started_at":5}`+"\n"+`{"id":2,"numb`), 0o644); err != nil {
		t.Fatal(err)
	}
	l := newCallLog(path, 10)
	if l.Count() != 1 {
		t.Fatalf("torn line took the whole file down: %d entries", l.Count())
	}
	if l.nextID != 2 {
		t.Fatalf("nextID = %d, want 2 (IDs must not be reused)", l.nextID)
	}
}

func TestFormatSeconds(t *testing.T) {
	for _, tc := range []struct {
		in   int
		want string
	}{{0, "0:00"}, {9, "0:09"}, {75, "1:15"}, {3725, "1:02:05"}} {
		if got := formatSeconds(tc.in); got != tc.want {
			t.Errorf("formatSeconds(%d) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
