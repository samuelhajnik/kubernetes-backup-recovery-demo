package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
)

func methodNotAllowed(w http.ResponseWriter, gotMethod string, allowedMethod string) {
	writeJSON(w, http.StatusMethodNotAllowed, jsonResponse{
		"error":          "method not allowed",
		"got":            gotMethod,
		"allowed_method": allowedMethod,
	})
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, jsonResponse{
		"error": msg,
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode response: %v", err)
	}
}

func getenvOrDefault(key, fallback string) string {
	val := strings.TrimSpace(os.Getenv(key))
	if val == "" {
		return fallback
	}
	return val
}
