package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
)

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
	items, err := readItems(s.dataFile)
	s.mu.Unlock()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusOK, jsonResponse{
				"items": []any{},
				"count": 0,
			})
			return
		}
		if errors.Is(err, errStoredDataCorrupted) {
			writeError(w, http.StatusInternalServerError, "stored data is corrupted")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to read data")
		return
	}

	writeJSON(w, http.StatusOK, jsonResponse{
		"items": items,
		"count": len(items),
	})
}
