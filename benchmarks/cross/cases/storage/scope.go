package main

import (
	"fmt"
	"os"
	"strconv"
)

func oneScope(path string) (count int, err error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer func() {
		closeErr := file.Close()
		if err == nil {
			err = closeErr
		}
	}()
	var octet [1]byte
	count, err = file.Read(octet[:])
	return count, err
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: scope SCOPES FIXTURE")
		os.Exit(2)
	}
	scopes, err := strconv.Atoi(os.Args[1])
	if err != nil || scopes <= 0 {
		fmt.Fprintln(os.Stderr, "scope count must be positive")
		os.Exit(2)
	}
	checksum := 0
	for i := 0; i < scopes; i++ {
		count, err := oneScope(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		checksum += count
	}
	fmt.Printf("scopes=%d bytes=%d checksum=%d\n", scopes, checksum, checksum)
}
