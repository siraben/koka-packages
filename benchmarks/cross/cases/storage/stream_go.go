package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
)

const chunkSize = 65536

func arguments() (int, string, error) {
	if len(os.Args) != 3 {
		return 0, "", fmt.Errorf("usage: stream_go REPETITIONS FIXTURE")
	}
	repetitions, err := strconv.Atoi(os.Args[1])
	if err != nil || repetitions <= 0 {
		return 0, "", fmt.Errorf("repetitions must be positive")
	}
	return repetitions, os.Args[2], nil
}

func onePass(path string) (int64, uint64, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}

	reader := bufio.NewReaderSize(file, chunkSize)
	buffer := make([]byte, chunkSize)
	var seen int64
	var checksum uint64
	for {
		n, readErr := io.ReadFull(reader, buffer)
		if readErr != nil && readErr != io.ErrUnexpectedEOF && readErr != io.EOF {
			_ = file.Close()
			return 0, 0, readErr
		}
		if n > 0 {
			checksum += uint64(n)
			checksum += uint64(buffer[0]) + uint64(buffer[n-1])
		}
		seen += int64(n)
		if readErr == io.ErrUnexpectedEOF || readErr == io.EOF {
			break
		}
	}
	if err := file.Close(); err != nil {
		return 0, 0, err
	}
	return seen, checksum, nil
}

func main() {
	repetitions, path, err := arguments()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var totalBytes int64
	var checksum uint64
	for i := 0; i < repetitions; i++ {
		seen, partial, err := onePass(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		totalBytes += seen
		checksum += partial
	}
	if totalBytes%int64(repetitions) != 0 {
		fmt.Fprintln(os.Stderr, "inconsistent byte count")
		os.Exit(1)
	}
	fmt.Printf("bytes=%d reps=%d checksum=%d\n",
		totalBytes/int64(repetitions), repetitions, checksum)
}
