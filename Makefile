.PHONY: test verify run-demo

test:
	go test ./...

verify:
	go test ./...
	go vet ./...
	bash -n scripts/run-backup-recovery-demo.sh

run-demo:
	./scripts/run-backup-recovery-demo.sh --compare
