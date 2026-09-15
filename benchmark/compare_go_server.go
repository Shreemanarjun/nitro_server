// Go net/http side for compare.dart — serves the same routes, byte-identical,
// so the same client can assert and benchmark Go alongside nitro/shelf/dart:io.
// Started by compare.dart via `go run`; prints "LISTENING <port>" then serves.
// WebSocket is not implemented here (Go has no stdlib WS); compare.dart leaves
// Go out of the WS cases, exactly as it does shelf.
//
// Byte-exactness notes (the client compares raw bytes):
//   * JSON is built by hand so key order and Dart's double formatting
//     (whole doubles print as "N.0") match jsonEncode, which encoding/json
//     would not.
//   * /work's records use the literal name "item-$i" (Dart's source escapes
//     the '$'), the same for every record.
package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

var helloBody = []byte("hello world!")
var jsonBody = []byte(`{"id":42,"name":"nitro","tags":["a","b","c"]}`)

// workBody matches Dart jsonEncode of 200 records: {id,name,tags,score} in that
// order, score = i*1.5 with Dart's double formatting (whole -> "N.0").
func workBody() []byte {
	var b strings.Builder
	b.WriteByte('[')
	for i := 0; i < 200; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		score := float64(i) * 1.5
		var s string
		if score == float64(int64(score)) {
			s = strconv.FormatInt(int64(score), 10) + ".0"
		} else {
			s = strconv.FormatFloat(score, 'f', -1, 64)
		}
		fmt.Fprintf(&b, `{"id":%d,"name":"item-$i","tags":["a","b"],"score":%s}`, i, s)
	}
	b.WriteByte(']')
	return []byte(b.String())
}

func fileBytes() []byte {
	buf := make([]byte, 64*1024)
	for i := range buf {
		buf[i] = byte((i * 31) & 0xff)
	}
	return buf
}

// queryJSON encodes a query string as Dart's jsonEncode(queryParameters) does:
// a JSON object in the query's field order.
func queryJSON(raw string) []byte {
	var b strings.Builder
	b.WriteByte('{')
	first := true
	for _, pair := range strings.Split(raw, "&") {
		if pair == "" {
			continue
		}
		k, v, _ := strings.Cut(pair, "=")
		kd, _ := url.QueryUnescape(k)
		vd, _ := url.QueryUnescape(v)
		if !first {
			b.WriteByte(',')
		}
		first = false
		writeJSONString(&b, kd)
		b.WriteByte(':')
		writeJSONString(&b, vd)
	}
	b.WriteByte('}')
	return []byte(b.String())
}

func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
}

func writeBytes(w http.ResponseWriter, body []byte, contentType string) {
	if contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
}

func main() {
	batch := flag.Bool("batch-events", false, "coalesce SSE events into one write")
	flag.Parse()

	work := workBody()
	file := fileBytes()
	var eventChunks [][]byte
	var eventsAll []byte
	for i := 0; i < 20; i++ {
		c := []byte(fmt.Sprintf("data: %d\n\n", i))
		eventChunks = append(eventChunks, c)
		eventsAll = append(eventsAll, c...)
	}

	handler := func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case r.Method == "POST" && p == "/echo":
			body, _ := io.ReadAll(r.Body)
			writeBytes(w, body, "application/octet-stream")
		case p == "/events":
			w.Header().Set("Content-Type", "text/event-stream")
			if *batch {
				writeBytes(w, eventsAll, "text/event-stream")
			} else {
				fl, _ := w.(http.Flusher)
				for _, c := range eventChunks {
					w.Write(c)
					if fl != nil {
						fl.Flush()
					}
				}
			}
		case strings.HasPrefix(p, "/users/"):
			writeBytes(w, []byte("user "+p[len("/users/"):]), "text/plain")
		case strings.HasPrefix(p, "/files/"):
			writeBytes(w, []byte("wild:"+p), "text/plain")
		case p == "/q":
			writeBytes(w, queryJSON(r.URL.RawQuery), "application/json")
		case p == "/mw", p == "/static", p == "/hello":
			writeBytes(w, helloBody, "text/plain")
		case p == "/json":
			writeBytes(w, jsonBody, "application/json")
		case p == "/work":
			writeBytes(w, work, "application/json")
		case p == "/file":
			writeBytes(w, file, "application/octet-stream")
		default:
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte("not found"))
		}
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Println("BIND-FAIL", err)
		return
	}
	port := ln.Addr().(*net.TCPAddr).Port
	fmt.Printf("LISTENING %d\n", port)
	http.Serve(ln, http.HandlerFunc(handler))
}
