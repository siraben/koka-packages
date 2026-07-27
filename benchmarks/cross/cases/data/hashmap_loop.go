package main

import (
	"fmt"
	"os"
	"strconv"
)

const valueModulus = int64(1000003)

func requestedWork() int64 {
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
	return work
}

func main() {
	work := requestedWork()
	entries := make(map[int64]int64, int(work))
	for i := int64(0); i < work; i++ {
		entries[i] = (17*i + 3) % valueModulus
	}

	var checksum int64
	for i := work - 1; i >= 0; i-- {
		if value, found := entries[i]; found {
			checksum += value
		}
	}
	fmt.Println(checksum)
}
