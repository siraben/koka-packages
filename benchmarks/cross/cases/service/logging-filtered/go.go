package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
)

const maxRepetitions = 10_000_000

func repetitions() int {
	if len(os.Args) != 2 {
		panic("usage: logging-go REPETITIONS")
	}
	n, err := strconv.Atoi(os.Args[1])
	if err != nil || n < 0 || n > maxRepetitions {
		panic("repetitions must be an integer from 0 through 10000000")
	}
	return n
}

func main() {
	reps := repetitions()
	attrs := []slog.Attr{
		slog.String("request-id", "r12345"),
		slog.String("method", "GET"),
		slog.String("path", "/items/42"),
		slog.String("status", "200"),
		slog.String("duration-ms", "3"),
		slog.String("peer", "127.0.0.1:51234"),
		slog.String("service", "notes"),
		slog.String("cached", "true"),
	}
	logger := slog.New(slog.NewJSONHandler(io.Discard, &slog.HandlerOptions{
		Level: slog.LevelError,
	}))
	ctx := context.Background()

	for i := 0; i < reps; i++ {
		logger.LogAttrs(ctx, slog.LevelInfo, "request", attrs...)
	}
	fmt.Println(reps)
}
