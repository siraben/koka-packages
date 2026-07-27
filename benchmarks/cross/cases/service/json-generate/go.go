package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

const maxRepetitions = 10_000_000

func repetitions() int {
	if len(os.Args) != 2 {
		panic("usage: json-go REPETITIONS")
	}
	n, err := strconv.Atoi(os.Args[1])
	if err != nil || n < 0 || n > maxRepetitions {
		panic("repetitions must be an integer from 0 through 10000000")
	}
	return n
}

func main() {
	reps := repetitions()
	values := make([]int, 2000)
	for i := range values {
		values[i] = i
	}

	var checksum int64
	for i := 0; i < reps; i++ {
		encoded, err := json.Marshal(values)
		if err != nil {
			panic(err)
		}
		checksum += int64(len(encoded))
	}
	fmt.Println(checksum)
}
