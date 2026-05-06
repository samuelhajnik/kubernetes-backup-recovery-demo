package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
)

func (s *server) handleBackupStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r.Method, http.MethodGet)
		return
	}

	payload, err := loadBackupStatusPayload(s.backupStatusFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusOK, jsonResponse{
				"status":  "unknown",
				"message": "no backup has been executed yet",
			})
			return
		}
		if errors.Is(err, errInvalidBackupStatus) {
			writeError(w, http.StatusInternalServerError, "backup status file is invalid")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to read backup status")
		return
	}

	writeJSON(w, http.StatusOK, payload)
}

var errInvalidBackupStatus = errors.New("backup status file is invalid")

func loadBackupStatusPayload(path string) (any, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var payload any
	if err := json.Unmarshal(content, &payload); err != nil {
		return nil, errInvalidBackupStatus
	}
	return payload, nil
}
