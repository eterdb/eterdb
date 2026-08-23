package main

import "testing"

func TestManifestEndLSN(t *testing.T) {
	manifest := []byte(`{
  "PostgreSQL-Backup-Manifest-Version": 1,
  "Files": [
    {"Path": "backup_label", "Size": 227, "Last-Modified": "2026-07-08 12:00:00 GMT"},
    {"Path": "PG_VERSION", "Size": 3, "Last-Modified": "2026-07-08 11:00:00 GMT"}
  ],
  "WAL-Ranges": [
    {"Timeline": 1, "Start-LSN": "0/2000028", "End-LSN": "0/2000158"}
  ],
  "Manifest-Checksum": "deadbeef"
}`)
	if got := manifestEndLSN(manifest); got != "0/2000158" {
		t.Fatalf("manifestEndLSN = %q, want 0/2000158", got)
	}
}

func TestManifestEndLSNMissingPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic on manifest without WAL-Ranges")
		}
	}()
	manifestEndLSN([]byte(`{"Files": []}`))
}

func TestLabelStartSegment(t *testing.T) {
	label := []byte(`START WAL LOCATION: 0/2000028 (file 000000010000000000000002)
CHECKPOINT LOCATION: 0/2000060
BACKUP METHOD: streamed
BACKUP FROM: primary
START TIME: 2026-07-08 12:00:00 UTC
LABEL: pg_basebackup base backup
START TIMELINE: 1
`)
	if got := labelStartSegment(label); got != "000000010000000000000002" {
		t.Fatalf("labelStartSegment = %q, want 000000010000000000000002", got)
	}
}

func TestLabelStartSegmentMissingPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic on label without START WAL LOCATION")
		}
	}()
	labelStartSegment([]byte("LABEL: something else\n"))
}
