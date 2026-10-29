package main

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestAcquireATLockHonoursOtherQManagerClient(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qmanager_at.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o666)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 130*time.Millisecond)
	defer cancel()
	start := time.Now()
	got, err := acquireATLock(ctx, path)
	if got != nil {
		got.Close()
		t.Fatal("acquired lock while another AT client held it")
	}
	if err == nil {
		t.Fatal("expected deadline while lock was held")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("lock wait exceeded deadline by too much: %s", elapsed)
	}

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	got, err = acquireATLock(context.Background(), path)
	if err != nil {
		t.Fatalf("failed to acquire released shared AT lock: %v", err)
	}
	_ = syscall.Flock(int(got.Fd()), syscall.LOCK_UN)
	_ = got.Close()
}
