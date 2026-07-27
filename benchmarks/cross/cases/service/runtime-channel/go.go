package main

import (
	"fmt"
	"os"
	"strconv"
)

const maxHandoffs = 10_000_000

func handoffs() int {
	if len(os.Args) != 2 {
		panic("usage: channel-go HANDOFFS")
	}
	n, err := strconv.Atoi(os.Args[1])
	if err != nil || n < 0 || n > maxHandoffs {
		panic("handoffs must be an integer from 0 through 10000000")
	}
	return n
}

func main() {
	count := handoffs()
	channel := make(chan int, 256)
	go func() {
		for value := 0; value < count; value++ {
			channel <- value
		}
		close(channel)
	}()

	var checksum int64
	for value := range channel {
		checksum += int64(value)
	}
	fmt.Println(checksum)
}
