package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: whole_read REPETITIONS FIXTURE")
		os.Exit(2)
	}
	repetitions, err := strconv.Atoi(os.Args[1])
	if err != nil || repetitions <= 0 {
		fmt.Fprintln(os.Stderr, "repetitions must be positive")
		os.Exit(2)
	}
	var totalBytes uint64
	var checksum uint64
	for i := 0; i < repetitions; i++ {
		data, err := os.ReadFile(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		totalBytes += uint64(len(data))
		checksum += uint64(len(data))
		checksum += uint64(data[0]) + uint64(data[len(data)-1])
	}
	if totalBytes%uint64(repetitions) != 0 {
		fmt.Fprintln(os.Stderr, "inconsistent byte count")
		os.Exit(1)
	}
	fmt.Printf("bytes=%d reps=%d checksum=%d\n",
		totalBytes/uint64(repetitions), repetitions, checksum)
}
