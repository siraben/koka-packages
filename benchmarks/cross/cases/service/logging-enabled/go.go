package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
)

const maxRepetitions = 10_000_000

type countingWriter struct {
	records int
}

func (writer *countingWriter) Write(data []byte) (int, error) {
	if len(data) > 0 {
		writer.records++
	}
	return len(data), nil
}

func repetitions() int {
	if len(os.Args) != 2 {
		panic("usage: logging-enabled-go REPETITIONS")
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
	writer := &countingWriter{}
	logger := slog.New(slog.NewJSONHandler(writer, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	ctx := context.Background()

	for i := 0; i < reps; i++ {
		logger.LogAttrs(ctx, slog.LevelInfo, "request", attrs...)
	}
	fmt.Println(writer.records)
}
