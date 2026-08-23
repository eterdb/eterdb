package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testServer(t *testing.T, client *fakeClient, token string) (*httptest.Server, *memStore) {
	t.Helper()
	store := newMemStore()
	cfg := testCfg(t)
	cfg.apiToken = token
	run := newRunner(cfg, store) // not started: submit tests only check queueing
	srv := httptest.NewServer(newServer(cfg, client, store, run).routes())
	t.Cleanup(srv.Close)
	return srv, store
}

func do(t *testing.T, method, url, token, body string) (*http.Response, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var m map[string]any
	_ = json.NewDecoder(res.Body).Decode(&m)
	return res, m
}

// The auth contract: 401 + {"ok":false,"error":"unauthorized"} on /v1/*
// without the token; the root probe stays open.
func TestAuth(t *testing.T) {
	srv, _ := testServer(t, &fakeClient{}, "sekrit")
	res, body := do(t, "GET", srv.URL+"/v1/status", "", "")
	if res.StatusCode != 401 || body["error"] != "unauthorized" || body["ok"] != false {
		t.Fatalf("unauthorized shape wrong: %d %v", res.StatusCode, body)
	}
	res, _ = do(t, "GET", srv.URL+"/v1/status", "sekrit", "")
	if res.StatusCode != 200 {
		t.Fatalf("with token: %d", res.StatusCode)
	}
	res, _ = do(t, "GET", srv.URL+"/", "", "")
	if res.StatusCode != 200 {
		t.Fatalf("root probe should be open: %d", res.StatusCode)
	}
}

// THE exit-code contract: the engine message must ride verbatim in the body,
// with the TS status mapping (dependent→409, not found→404, else→500).
func TestErrorMappingContract(t *testing.T) {
	cases := []struct {
		msg  string
		code int
	}{
		{"undo refused: 2 dependent transactions exist", 409},
		{"txid 99 has no tracked writes", 404},
		{"relation not found", 404},
		{"connection refused", 500},
	}
	for _, c := range cases {
		srv, _ := testServer(t, &fakeClient{err: errors.New(c.msg)}, "")
		res, body := do(t, "POST", srv.URL+"/v1/undo", "", `{"txid":1}`)
		if res.StatusCode != c.code {
			t.Errorf("%q: status %d, want %d", c.msg, res.StatusCode, c.code)
		}
		if body["error"] != c.msg || body["ok"] != false {
			t.Errorf("%q: body %v, engine message must be verbatim", c.msg, body)
		}
	}
}

// txid must be accepted as number OR string (node-pg legacy).
func TestTxidNumberOrString(t *testing.T) {
	srv, _ := testServer(t, &fakeClient{}, "")
	for _, body := range []string{`{"txid":42}`, `{"txid":"42"}`} {
		res, m := do(t, "POST", srv.URL+"/v1/undo", "", body)
		if res.StatusCode != 200 || m["txid"] != float64(42) {
			t.Fatalf("body %s: %d %v", body, res.StatusCode, m)
		}
		if m["mode"] != "clean_only" {
			t.Fatalf("mode should default to clean_only, got %v", m["mode"])
		}
	}
}

func TestChangesQueryDefaults(t *testing.T) {
	srv, _ := testServer(t, &fakeClient{}, "")
	req, _ := http.NewRequest("GET", srv.URL+"/v1/changes?includeUndo=1&limit=7", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var rows []map[string]any
	_ = json.NewDecoder(res.Body).Decode(&rows)
	if len(rows) != 1 || rows[0]["limit_seen"] != float64(7) || rows[0]["include_undo"] != true {
		t.Fatalf("query params not threaded: %v", rows)
	}
}

func TestJobSubmitAndShape(t *testing.T) {
	srv, store := testServer(t, &fakeClient{}, "")
	res, body := do(t, "POST", srv.URL+"/v1/storage/recover-table", "", `{"table":"public.widgets"}`)
	if res.StatusCode != 202 || body["state"] != "queued" {
		t.Fatalf("submit: %d %v", res.StatusCode, body)
	}
	id := int64(body["job_id"].(float64))
	res, jb := do(t, "GET", srv.URL+"/v1/jobs/1", "", "")
	if res.StatusCode != 200 || jb["state"] != "queued" || jb["kind"] != "recover-table" {
		t.Fatalf("job get: %d %v", res.StatusCode, jb)
	}
	// invalid args → 400 before anything is queued
	res, _ = do(t, "POST", srv.URL+"/v1/storage/recover-column", "", `{"table":"t"}`)
	if res.StatusCode != 400 {
		t.Fatalf("bad args should 400, got %d", res.StatusCode)
	}
	// cancel queued → ok; second cancel → 409
	res, _ = do(t, "POST", srv.URL+"/v1/jobs/1/cancel", "", "")
	if res.StatusCode != 200 {
		t.Fatalf("cancel queued: %d", res.StatusCode)
	}
	if j, _ := store.Get(context.Background(), id); j.State != "canceled" {
		t.Fatalf("job not canceled: %s", j.State)
	}
	res, _ = do(t, "POST", srv.URL+"/v1/jobs/1/cancel", "", "")
	if res.StatusCode != 409 {
		t.Fatalf("re-cancel should 409, got %d", res.StatusCode)
	}
	// unknown job → 404
	res, _ = do(t, "POST", srv.URL+"/v1/jobs/999/cancel", "", "")
	if res.StatusCode != 404 {
		t.Fatalf("cancel of unknown job should 404, got %d", res.StatusCode)
	}
}

func TestJobsList(t *testing.T) {
	srv, store := testServer(t, &fakeClient{}, "")
	_, _ = store.Submit(context.Background(), "snapshot", nil)
	_, _ = store.Submit(context.Background(), "recover-table", map[string]any{"table": "t"})
	req, _ := http.NewRequest("GET", srv.URL+"/v1/jobs?kind=snapshot", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var rows []map[string]any
	_ = json.NewDecoder(res.Body).Decode(&rows)
	if len(rows) != 1 || rows[0]["kind"] != "snapshot" {
		t.Fatalf("filtered list wrong: %v", rows)
	}
}

// Storage submission without ETER_BACKUP_DIR must fail loudly, not enqueue.
func TestStorageUnconfigured(t *testing.T) {
	store := newMemStore()
	cfg := testCfg(t)
	cfg.backupDir = ""
	run := newRunner(cfg, store)
	srv := httptest.NewServer(newServer(cfg, &fakeClient{}, store, run).routes())
	defer srv.Close()
	res, body := do(t, "POST", srv.URL+"/v1/storage/snapshot", "", `{}`)
	if res.StatusCode != 500 || !strings.Contains(body["error"].(string), "ETER_BACKUP_DIR") {
		t.Fatalf("unconfigured storage: %d %v", res.StatusCode, body)
	}
}
