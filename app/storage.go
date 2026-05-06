package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

var errStoredDataCorrupted = errors.New("stored data is corrupted")

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

func readItems(path string) ([]any, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	trimmed := strings.TrimSpace(string(content))
	if trimmed == "" {
		return []any{}, nil
	}
	lines := strings.Split(trimmed, "\n")

	items := make([]any, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var item any
		if err := json.Unmarshal([]byte(line), &item); err != nil {
			return nil, errStoredDataCorrupted
		}
		items = append(items, item)
	}

	return items, nil
}
