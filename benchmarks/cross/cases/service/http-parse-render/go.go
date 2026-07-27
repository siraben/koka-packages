package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
)

const (
	maxRepetitions = 10_000_000
	requestWire    = "POST /items/42?verbose=1 HTTP/1.1\r\n" +
		"Host: example.test\r\n" +
		"Content-Type: text/plain\r\n" +
		"Content-Length: 11\r\n" +
		"Connection: close\r\n\r\n" +
		"hello world"
)

func repetitions() int {
	if len(os.Args) != 2 {
		panic("usage: http-go REPETITIONS")
	}
	n, err := strconv.Atoi(os.Args[1])
	if err != nil || n < 0 || n > maxRepetitions {
		panic("repetitions must be an integer from 0 through 10000000")
	}
	return n
}

func main() {
	reps := repetitions()
	var checksum int64
	for i := 0; i < reps; i++ {
		request, err := http.ReadRequest(bufio.NewReader(strings.NewReader(requestWire)))
		if err != nil {
			panic(err)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			panic(err)
		}
		request.Body.Close()

		responseBody := []byte("accepted")
		response := &http.Response{
			StatusCode:    http.StatusCreated,
			ProtoMajor:    1,
			ProtoMinor:    1,
			Header:        make(http.Header),
			Body:          io.NopCloser(bytes.NewReader(responseBody)),
			ContentLength: int64(len(responseBody)),
			Close:         true,
			Request:       request,
		}
		response.Header.Set("Content-Type", "text/plain")
		response.Header.Set("X-Request-Id", "r12345")
		var rendered bytes.Buffer
		if err := response.Write(&rendered); err != nil {
			panic(err)
		}
		marker := 0
		if rendered.Len() > 0 {
			marker = 1
		}
		item := len(request.Method) + len(request.URL.Path) + len(request.URL.RawQuery) +
			len(body) + http.StatusCreated + len(responseBody) + marker
		checksum += int64(item)
	}
	fmt.Println(checksum)
}
