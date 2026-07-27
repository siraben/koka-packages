package main

import (
	"fmt"
	"os"
	"strconv"
)

const (
	appendsPerRepetition = 80000
	outputSize           = 800000
	checksumMultiplier   = uint64(1000003)
	checksumModulus      = uint64(1000000007)
)

var chunk = []byte("0123456789")

func requestedWork() uint64 {
	if len(os.Args) < 2 {
		return 1
	}
	work, err := strconv.ParseInt(os.Args[1], 10, 64)
	if err != nil {
		return 1
	}
	if work < 0 {
		return 0
	}
	return uint64(work)
}

func oneRepetition() uint64 {
	output := make([]byte, 0, outputSize)
	for i := 0; i < appendsPerRepetition; i++ {
		output = append(output, chunk...)
	}
	if len(output) == 0 {
		return uint64(len(output))
	}
	return uint64(len(output) + 1)
}

func main() {
	work := requestedWork()
	var checksum uint64
	for rep := uint64(0); rep < work; rep++ {
		checksum = (checksum*checksumMultiplier + oneRepetition()) % checksumModulus
	}
	fmt.Println(checksum)
}
