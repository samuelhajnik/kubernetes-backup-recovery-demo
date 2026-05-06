package main

import (
	"log"
	"net/http"
	"sync"
)

type server struct {
	dataFile         string
	backupStatusFile string
	mu               sync.Mutex
	frozen           bool
}

type writeRequest struct {
	Data any `json:"data"`
}

type jsonResponse map[string]any

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/write", s.handleWrite)
	mux.HandleFunc("/read", s.handleRead)
	mux.HandleFunc("/backup-status", s.handleBackupStatus)
	mux.HandleFunc("/freeze", s.handleFreeze)
	mux.HandleFunc("/unfreeze", s.handleUnfreeze)
	return loggingMiddleware(mux)
}

func (s *server) start(addr string) error {
	log.Printf("starting server on %s with data file %s", addr, s.dataFile)
	return http.ListenAndServe(addr, s.routes())
}

func (s *server) isFrozen() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.frozen
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}
