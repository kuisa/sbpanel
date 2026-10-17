package main

import (
	"context"
	"os"
	"runtime"
	"time"
)

func timeoutCtx(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}

func goArch() string { return runtime.GOARCH }
