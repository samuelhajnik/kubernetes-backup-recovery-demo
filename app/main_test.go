package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHandleHealthReturnsReadyShape(t *testing.T) {
	s := newTestServer(t)

	res := performRequest(t, s.handleHealth, http.MethodGet, "/health", "")
	if res.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, res.Code)
	}

	var payload map[string]any
	decodeResponseJSON(t, res, &payload)

	if payload["status"] != "ok" {
		t.Fatalf("expected status=ok, got %v", payload["status"])
	}
	if payload["data_file"] != s.dataFile {
		t.Fatalf("expected data_file=%s, got %v", s.dataFile, payload["data_file"])
	}
	if payload["frozen"] != false {
		t.Fatalf("expected frozen=false, got %v", payload["frozen"])
	}
}

func TestWriteReadPersistenceAndMonotonicCount(t *testing.T) {
	s := newTestServer(t)

	writes := []string{
		`{"data":{"id":"evt-1","value":"alpha"}}`,
		`{"data":{"id":"evt-1","value":"alpha"}}`,
		`{"data":{"id":"evt-2","value":"beta"}}`,
	}

	for i, body := range writes {
		writeRes := performRequest(t, s.handleWrite, http.MethodPost, "/write", body)
		if writeRes.Code != http.StatusCreated {
			t.Fatalf("write %d: expected status %d, got %d", i, http.StatusCreated, writeRes.Code)
		}

		readRes := performRequest(t, s.handleRead, http.MethodGet, "/read", "")
		if readRes.Code != http.StatusOK {
			t.Fatalf("read after write %d: expected status %d, got %d", i, http.StatusOK, readRes.Code)
		}

		var payload struct {
			Items []map[string]any `json:"items"`
			Count int              `json:"count"`
		}
		decodeResponseJSON(t, readRes, &payload)

		want := i + 1
		if payload.Count != want {
			t.Fatalf("after write %d: expected count=%d, got %d", i, want, payload.Count)
		}
		if len(payload.Items) != want {
			t.Fatalf("after write %d: expected %d items, got %d", i, want, len(payload.Items))
		}
	}

	// Also verify bytes were persisted in the underlying data file.
	content, err := os.ReadFile(s.dataFile)
	if err != nil {
		t.Fatalf("failed reading data file: %v", err)
	}
	if got, want := strings.Count(strings.TrimSpace(string(content)), "\n")+1, len(writes); got != want {
		t.Fatalf("expected %d persisted lines, got %d", want, got)
	}
}

func TestHandleWriteRejectsWhileFrozen(t *testing.T) {
	s := newTestServer(t)
	s.frozen = true

	res := performRequest(t, s.handleWrite, http.MethodPost, "/write", `{"data":{"id":"evt-1"}}`)
	if res.Code != http.StatusConflict {
		t.Fatalf("expected status %d, got %d", http.StatusConflict, res.Code)
	}

	var payload map[string]any
	decodeResponseJSON(t, res, &payload)
	if payload["error"] != "writes are temporarily frozen" {
		t.Fatalf("expected frozen write error, got %v", payload["error"])
	}
}

func TestHandleReadFailsOnCorruptedStoredData(t *testing.T) {
	s := newTestServer(t)
	if err := os.WriteFile(s.dataFile, []byte("{\"ok\":1}\nnot-json\n"), 0o644); err != nil {
		t.Fatalf("failed to seed corrupted file: %v", err)
	}

	res := performRequest(t, s.handleRead, http.MethodGet, "/read", "")
	if res.Code != http.StatusInternalServerError {
		t.Fatalf("expected status %d, got %d", http.StatusInternalServerError, res.Code)
	}

	var payload map[string]any
	decodeResponseJSON(t, res, &payload)
	if payload["error"] != "stored data is corrupted" {
		t.Fatalf("expected corruption error, got %v", payload["error"])
	}
}

func TestHandleBackupStatusVerificationCases(t *testing.T) {
	t.Run("missing status file reports unknown", func(t *testing.T) {
		s := newTestServer(t)
		res := performRequest(t, s.handleBackupStatus, http.MethodGet, "/backup-status", "")

		if res.Code != http.StatusOK {
			t.Fatalf("expected status %d, got %d", http.StatusOK, res.Code)
		}

		var payload map[string]any
		decodeResponseJSON(t, res, &payload)
		if payload["status"] != "unknown" {
			t.Fatalf("expected status=unknown, got %v", payload["status"])
		}
	})

	t.Run("valid restore verification payload passes through", func(t *testing.T) {
		s := newTestServer(t)
		statusJSON := `{"operation":"restore","status":"success","checksum_valid":true,"message":"restore completed and checksum verified"}`
		if err := os.WriteFile(s.backupStatusFile, []byte(statusJSON), 0o644); err != nil {
			t.Fatalf("failed writing status file: %v", err)
		}

		res := performRequest(t, s.handleBackupStatus, http.MethodGet, "/backup-status", "")
		if res.Code != http.StatusOK {
			t.Fatalf("expected status %d, got %d", http.StatusOK, res.Code)
		}

		var payload map[string]any
		decodeResponseJSON(t, res, &payload)
		if payload["status"] != "success" {
			t.Fatalf("expected status=success, got %v", payload["status"])
		}
		if payload["checksum_valid"] != true {
			t.Fatalf("expected checksum_valid=true, got %v", payload["checksum_valid"])
		}
	})

	t.Run("invalid status json fails clearly", func(t *testing.T) {
		s := newTestServer(t)
		if err := os.WriteFile(s.backupStatusFile, []byte("{invalid-json"), 0o644); err != nil {
			t.Fatalf("failed writing invalid status file: %v", err)
		}

		res := performRequest(t, s.handleBackupStatus, http.MethodGet, "/backup-status", "")
		if res.Code != http.StatusInternalServerError {
			t.Fatalf("expected status %d, got %d", http.StatusInternalServerError, res.Code)
		}

		var payload map[string]any
		decodeResponseJSON(t, res, &payload)
		if payload["error"] != "backup status file is invalid" {
			t.Fatalf("expected invalid status error, got %v", payload["error"])
		}
	})
}

func TestAppendLineReturnsErrorForInvalidStoragePath(t *testing.T) {
	invalidFile := filepath.Join(t.TempDir(), "missing-dir", "data.jsonl")
	err := appendLine(invalidFile, []byte(`{"id":"evt-1"}`))
	if err == nil {
		t.Fatal("expected appendLine to fail for non-existing parent directory")
	}
}

// TestFileBackupRestoreRoundTrip simulates copy-out → delete live file → copy-back without Kubernetes.
func TestFileBackupRestoreRoundTrip(t *testing.T) {
	base := t.TempDir()
	dataFile := filepath.Join(base, "data", "data.jsonl")
	if err := ensureDataPath(dataFile); err != nil {
		t.Fatalf("ensureDataPath: %v", err)
	}
	lines := [][]byte{
		[]byte(`{"verify":"local-restore","n":1}`),
		[]byte(`{"verify":"local-restore","n":2}`),
	}
	for _, line := range lines {
		if err := appendLine(dataFile, line); err != nil {
			t.Fatalf("appendLine: %v", err)
		}
	}
	before, err := os.ReadFile(dataFile)
	if err != nil {
		t.Fatalf("read before backup: %v", err)
	}
	backupFile := filepath.Join(base, "backup", "snap.jsonl")
	if err := os.MkdirAll(filepath.Dir(backupFile), 0o755); err != nil {
		t.Fatalf("mkdir backup: %v", err)
	}
	if err := os.WriteFile(backupFile, before, 0o644); err != nil {
		t.Fatalf("write backup: %v", err)
	}
	if err := os.Remove(dataFile); err != nil {
		t.Fatalf("remove live data: %v", err)
	}
	restored, err := os.ReadFile(backupFile)
	if err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if err := os.WriteFile(dataFile, restored, 0o644); err != nil {
		t.Fatalf("restore copy: %v", err)
	}
	after, err := os.ReadFile(dataFile)
	if err != nil {
		t.Fatalf("read after restore: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("bytes mismatch after restore:\nwant %q\ngot  %q", string(before), string(after))
	}
}

func newTestServer(t *testing.T) *server {
	t.Helper()

	baseDir := t.TempDir()
	dataFile := filepath.Join(baseDir, "data", "data.jsonl")
	statusFile := filepath.Join(baseDir, "backup", "backup-status.json")

	if err := ensureDataPath(dataFile); err != nil {
		t.Fatalf("failed to prepare data file path: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(statusFile), 0o755); err != nil {
		t.Fatalf("failed to prepare backup status path: %v", err)
	}

	return &server{
		dataFile:         dataFile,
		backupStatusFile: statusFile,
	}
}

func performRequest(t *testing.T, handler http.HandlerFunc, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()

	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}

	rr := httptest.NewRecorder()
	handler(rr, req)
	return rr
}

func decodeResponseJSON(t *testing.T, rr *httptest.ResponseRecorder, out any) {
	t.Helper()
	if err := json.Unmarshal(rr.Body.Bytes(), out); err != nil {
		t.Fatalf("failed decoding json response: %v; body=%s", err, rr.Body.String())
	}
}
