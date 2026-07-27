package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

const maxRepetitions = 1_000_000

func repetitions() int {
	if len(os.Args) != 2 {
		panic("usage: json-parse-go REPETITIONS")
	}
	n, err := strconv.Atoi(os.Args[1])
	if err != nil || n < 0 || n > maxRepetitions {
		panic("repetitions must be an integer from 0 through 1000000")
	}
	return n
}

func main() {
	reps := repetitions()
	values := make([]int, 2000)
	for i := range values {
		values[i] = i
	}
	document, err := json.Marshal(values)
	if err != nil {
		panic(err)
	}

	checksum := 0
	for i := 0; i < reps; i++ {
		var parsed []int
		if err := json.Unmarshal(document, &parsed); err != nil {
			panic(err)
		}
		if len(parsed) == 0 {
			panic("parsed JSON was not a non-empty array")
		}
		checksum++
	}
	fmt.Println(checksum)
}
