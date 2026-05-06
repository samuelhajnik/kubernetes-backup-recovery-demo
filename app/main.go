package main

import "log"

const (
	defaultDataFile         = "/data/data.jsonl"
	defaultAddr             = ":8080"
	defaultBackupStatusFile = "/backup/backup-status.json"
)

func main() {
	dataFile := getenvOrDefault("DATA_FILE_PATH", defaultDataFile)
	backupStatusFile := getenvOrDefault("BACKUP_STATUS_FILE_PATH", defaultBackupStatusFile)
	addr := getenvOrDefault("ADDR", defaultAddr)

	if err := ensureDataPath(dataFile); err != nil {
		log.Fatalf("failed to prepare data path: %v", err)
	}

	s := &server{dataFile: dataFile, backupStatusFile: backupStatusFile}
	if err := s.start(addr); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}
