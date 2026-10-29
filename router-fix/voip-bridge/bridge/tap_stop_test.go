package main

import (
	"os/exec"
	"testing"
	"time"
)

func TestStopTapWaitsForGracefulPCMIOCloseInsteadOfFixedThreeSecondKill(t *testing.T) {
	cmd := exec.Command("sh", "-c", "sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	b := &bridge{tapCmd: cmd, tapDone: done}
	go func() {
		_ = cmd.Wait()
		close(done)
	}()

	started := time.Now()
	b.stopTap()
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("graceful SIGTERM took %s; stop should return on Wait, not a fixed timer", elapsed)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stopTap returned before the helper was reaped")
	}
}
