// TechEmpower-style TFB server — Go net/http. /json + /plaintext.
// GOMAXPROCS = all cores (Go's default); keep-alive is net/http default.
package main

import (
	"encoding/json"
	"net/http"
)

type message struct {
	Message string `json:"message"`
}

var plaintext = []byte("Hello, World!")

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write(plaintext)
	})
	mux.HandleFunc("/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// Serialize per request (TFB /json is a serialization test).
		b, _ := json.Marshal(message{"Hello, World!"})
		w.Write(b)
	})
	println("PORT 8080")
	http.ListenAndServe("127.0.0.1:8080", mux)
}
