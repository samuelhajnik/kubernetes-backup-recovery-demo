package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const (
	defaultDataFile         = "/data/data.jsonl"
	defaultAddr             = ":8080"
	defaultBackupStatusFile = "/backup/backup-status.json"
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

func main() {
	dataFile := getenvOrDefault("DATA_FILE_PATH", defaultDataFile)
	backupStatusFile := getenvOrDefault("BACKUP_STATUS_FILE_PATH", defaultBackupStatusFile)
	addr := getenvOrDefault("ADDR", defaultAddr)

	if err := ensureDataPath(dataFile); err != nil {
		log.Fatalf("failed to prepare data path: %v", err)
	}

	s := &server{dataFile: dataFile, backupStatusFile: backupStatusFile}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/write", s.handleWrite)
	mux.HandleFunc("/read", s.handleRead)
	mux.HandleFunc("/backup-status", s.handleBackupStatus)
	mux.HandleFunc("/freeze", s.handleFreeze)
	mux.HandleFunc("/unfreeze", s.handleUnfreeze)

	log.Printf("starting server on %s with data file %s", addr, dataFile)
	if err := http.ListenAndServe(addr, loggingMiddleware(mux)); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r.Method, http.MethodGet)
		return
	}

	writeJSON(w, http.StatusOK, jsonResponse{
		"status":    "ok",
		"data_file": s.dataFile,
		"frozen":    s.isFrozen(),
	})
}

func (s *server) handleWrite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, r.Method, http.MethodPost)
		return
	}

	defer r.Body.Close()

	var req writeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON payload")
		return
	}
	if req.Data == nil {
		writeError(w, http.StatusBadRequest, "field 'data' is required")
		return
	}

	line, err := json.Marshal(req.Data)
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to encode data")
		return
	}

	s.mu.Lock()
	if s.frozen {
		s.mu.Unlock()
		writeError(w, http.StatusConflict, "writes are temporarily frozen")
		return
	}
	err = appendLine(s.dataFile, line)
	s.mu.Unlock()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to persist data")
		return
	}

	writeJSON(w, http.StatusCreated, jsonResponse{
		"status": "written",
	})
}

func (s *server) handleFreeze(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, r.Method, http.MethodPost)
		return
	}

	s.mu.Lock()
	s.frozen = true
	s.mu.Unlock()

	writeJSON(w, http.StatusOK, jsonResponse{
		"status": "frozen",
	})
}

func (s *server) handleUnfreeze(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, r.Method, http.MethodPost)
		return
	}

	s.mu.Lock()
	s.frozen = false
	s.mu.Unlock()

	writeJSON(w, http.StatusOK, jsonResponse{
		"status": "unfrozen",
	})
}

func (s *server) handleRead(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r.Method, http.MethodGet)
		return
	}

	s.mu.Lock()
	content, err := os.ReadFile(s.dataFile)
	s.mu.Unlock()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusOK, jsonResponse{
				"items": []any{},
				"count": 0,
			})
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to read data")
		return
	}

	trimmed := strings.TrimSpace(string(content))
	if trimmed == "" {
		writeJSON(w, http.StatusOK, jsonResponse{
			"items": []any{},
			"count": 0,
		})
		return
	}
	lines := strings.Split(trimmed, "\n")

	items := make([]any, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var item any
		if err := json.Unmarshal([]byte(line), &item); err != nil {
			writeError(w, http.StatusInternalServerError, "stored data is corrupted")
			return
		}
		items = append(items, item)
	}

	writeJSON(w, http.StatusOK, jsonResponse{
		"items": items,
		"count": len(items),
	})
}

func (s *server) handleBackupStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r.Method, http.MethodGet)
		return
	}

	content, err := os.ReadFile(s.backupStatusFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusOK, jsonResponse{
				"status":  "unknown",
				"message": "no backup has been executed yet",
			})
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to read backup status")
		return
	}

	var payload map[string]any
	if err := json.Unmarshal(content, &payload); err != nil {
		writeError(w, http.StatusInternalServerError, "backup status file is invalid")
		return
	}
	writeJSON(w, http.StatusOK, payload)
}

func ensureDataPath(dataFile string) error {
	dir := filepath.Dir(dataFile)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	f, err := os.OpenFile(dataFile, os.O_CREATE|os.O_RDONLY, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}

func appendLine(path string, line []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	if _, err := f.Write(line); err != nil {
		return err
	}
	if _, err := f.WriteString("\n"); err != nil {
		return err
	}
	return nil
}

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
