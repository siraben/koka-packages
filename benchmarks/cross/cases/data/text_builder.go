package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	appendsPerRepetition = 80000
	outputSize           = 800000
	checksumMultiplier   = uint64(1000003)
	checksumModulus      = uint64(1000000007)
	chunk                = "0123456789"
)

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
	var output strings.Builder
	output.Grow(outputSize)
	for i := 0; i < appendsPerRepetition; i++ {
		output.WriteString(chunk)
	}
	n := output.Len()
	result := output.String()
	if len(result) == 0 {
		return uint64(n)
	}
	return uint64(n + 1)
}

func main() {
	work := requestedWork()
	var checksum uint64
	for rep := uint64(0); rep < work; rep++ {
		checksum = (checksum*checksumMultiplier + oneRepetition()) % checksumModulus
	}
	fmt.Println(checksum)
}
