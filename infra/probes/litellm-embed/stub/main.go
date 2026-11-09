// Command stub stands in for an OpenAI-style embeddings upstream behind
// LiteLLM. It keeps each request body in $OUT/<n>.json and answers 576
// prompt tokens per input, the count ai gives an image, so the probe can
// tell pricing from the upstream's usage apart from LiteLLM counting the
// input's characters.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
)

func main() {
	out := os.Getenv("OUT")
	if out == "" {
		log.Fatal("OUT is required")
	}
	var n atomic.Int64
	http.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	http.HandleFunc("POST /v1/embeddings", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := os.WriteFile(filepath.Join(out, fmt.Sprintf("%d.json", n.Add(1))), body, 0o644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		var req struct {
			Model string          `json:"model"`
			Input json.RawMessage `json:"input"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		// OpenAI allows one string or a list of them.
		var inputs []string
		if err := json.Unmarshal(req.Input, &inputs); err != nil {
			var one string
			if err := json.Unmarshal(req.Input, &one); err != nil {
				http.Error(w, "input is neither a string nor a list of strings", http.StatusBadRequest)
				return
			}
			inputs = []string{one}
		}
		data := make([]map[string]any, len(inputs))
		for i := range inputs {
			data[i] = map[string]any{"object": "embedding", "index": i, "embedding": []float32{0.6, 0.8}}
		}
		tokens := 576 * len(inputs)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"object": "list", "model": req.Model, "data": data,
			"usage": map[string]int{"prompt_tokens": tokens, "total_tokens": tokens},
		})
	})
	log.Fatal(http.ListenAndServe(":8000", nil))
}
