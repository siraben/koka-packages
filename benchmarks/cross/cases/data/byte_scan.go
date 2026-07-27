package main

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
)

const (
	segmentSize        = 32768
	segmentCount       = 256
	inputSize          = segmentSize * segmentCount
	delimiter          = byte('|')
	checksumMultiplier = uint64(1000003)
	checksumModulus    = uint64(1000000007)
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

func makeInput() []byte {
	segment := bytes.Repeat([]byte{'a'}, segmentSize)
	segment[len(segment)-1] = delimiter
	input := make([]byte, 0, inputSize)
	for i := 0; i < segmentCount; i++ {
		input = append(input, segment...)
	}
	return input
}

func scan(input []byte) uint64 {
	from := 0
	var total uint64
	for from < len(input) {
		offset := bytes.IndexByte(input[from:], delimiter)
		if offset < 0 {
			break
		}
		index := from + offset
		total += uint64(index + 1)
		from = index + 1
	}
	return total
}

func main() {
	work := requestedWork()
	input := makeInput()
	var checksum uint64
	for rep := uint64(0); rep < work; rep++ {
		checksum = (checksum*checksumMultiplier + scan(input)) % checksumModulus
	}
	fmt.Println(checksum)
}
