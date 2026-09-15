package main
import ("fmt";"net/http";"runtime")
func main() {
	body := []byte("hello")
	h := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write(body)
	}
	http.HandleFunc("/hello", h)
	http.HandleFunc("/static", h)
	port := 8099
	fmt.Printf("LISTENING %d gomaxprocs=%d\n", port, runtime.GOMAXPROCS(0))
	http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", port), nil)
}
