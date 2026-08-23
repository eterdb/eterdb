// The HTTP surface: the /v1/* wire protocol the retired TS eter-server spoke
// (the CLI's hosted transport works against it unchanged) plus the net-new job
// endpoints. Handlers are programmed against the eterclient.EterClient
// interface and the jobStore seam so tests fake both.
//
// THE one byte-for-byte invariant is the error body: the CLI derives its
// stable exit codes by regex-matching the ENGINE'S OWN MESSAGE TEXT
// (`dependent transactions` → 4, `no tracked writes|not found` → 3), not the
// HTTP status, so sendError must echo engine messages verbatim in
// {"ok":false,"error":<msg>} and never rewrite them.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"

	"github.com/eterdb/eterdb/sidecars/eterclient"
)

type server struct {
	cfg    orchConfig
	client eterclient.EterClient
	store  jobStore
	run    *runner
}

// rawPreviewer lets /v1/undo/preview pass the engine's preview JSON through
// verbatim (the typed UndoPlan drops fields it doesn't model, e.g. ops).
// Implemented by *eterclient.DirectClient.
type rawPreviewer interface {
	PreviewRaw(ctx context.Context, txid int64) ([]byte, error)
}

// backupLister backs GET /v1/storage/backups. Implemented by *eterclient.DirectClient.
type backupLister interface {
	Backups(ctx context.Context) ([]map[string]any, error)
}

func newServer(cfg orchConfig, client eterclient.EterClient, store jobStore, run *runner) *server {
	return &server{cfg: cfg, client: client, store: store, run: run}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()

	// ---- the existing /v1 protocol (CLI hosted transport compatible) ----
	mux.HandleFunc("POST /v1/init", func(w http.ResponseWriter, r *http.Request) {
		res, err := s.client.Init(r.Context())
		s.reply(w, res, err)
	})
	mux.HandleFunc("POST /v1/track", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Table string `json:"table"`
		}
		if !decode(w, r, &body) {
			return
		}
		if err := s.client.Track(r.Context(), body.Table); err != nil {
			sendError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	mux.HandleFunc("POST /v1/track-all", func(w http.ResponseWriter, r *http.Request) {
		n, err := s.client.TrackAll(r.Context())
		s.reply(w, map[string]any{"tracked": n}, err)
	})
	mux.HandleFunc("GET /v1/changes", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		limit, _ := strconv.Atoi(q.Get("limit")) // 0 → DirectClient default (50)
		rows, err := s.client.Log(r.Context(), eterclient.LogOptions{
			Table:       q.Get("table"),
			Since:       q.Get("since"),
			Limit:       limit,
			IncludeUndo: q.Get("includeUndo") == "1",
		})
		s.replyRows(w, rows, err)
	})
	mux.HandleFunc("GET /v1/tx/{txid}", func(w http.ResponseWriter, r *http.Request) {
		txid, err := strconv.ParseInt(r.PathValue("txid"), 10, 64)
		if err != nil {
			badRequest(w, "invalid txid")
			return
		}
		rows, err := s.client.Show(r.Context(), txid)
		s.replyRows(w, rows, err)
	})
	mux.HandleFunc("POST /v1/undo/preview", func(w http.ResponseWriter, r *http.Request) {
		txid, _, ok := decodeTxid(w, r)
		if !ok {
			return
		}
		// Pass the engine's own preview JSON through verbatim when the client
		// supports it; the typed path is the fallback (tests' fakes).
		if rp, isRaw := s.client.(rawPreviewer); isRaw {
			b, err := rp.PreviewRaw(r.Context(), txid)
			if err != nil {
				sendError(w, err)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(b)
			return
		}
		plan, err := s.client.Preview(r.Context(), txid)
		s.reply(w, plan, err)
	})
	mux.HandleFunc("POST /v1/undo", func(w http.ResponseWriter, r *http.Request) {
		txid, mode, ok := decodeTxid(w, r)
		if !ok {
			return
		}
		res, err := s.client.Undo(r.Context(), txid, mode)
		s.reply(w, res, err)
	})
	mux.HandleFunc("POST /v1/cohort/preview", func(w http.ResponseWriter, r *http.Request) {
		sel, _, ok := decodeCohort(w, r)
		if !ok {
			return
		}
		res, err := s.client.PreviewCohort(r.Context(), sel)
		s.reply(w, res, err)
	})
	mux.HandleFunc("POST /v1/cohort/undo", func(w http.ResponseWriter, r *http.Request) {
		sel, mode, ok := decodeCohort(w, r)
		if !ok {
			return
		}
		res, err := s.client.UndoCohort(r.Context(), sel, mode)
		s.reply(w, res, err)
	})
	mux.HandleFunc("GET /v1/markers", func(w http.ResponseWriter, r *http.Request) {
		rows, err := s.client.Markers(r.Context())
		s.replyRows(w, rows, err)
	})
	mux.HandleFunc("POST /v1/markers", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Label string `json:"label"`
		}
		if !decode(w, r, &body) {
			return
		}
		id, err := s.client.Mark(r.Context(), body.Label)
		s.reply(w, map[string]any{"id": id}, err)
	})
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		res, err := s.client.Status(r.Context())
		s.reply(w, res, err)
	})

	// ---- storage jobs (net-new) ----
	for _, kind := range []string{"snapshot", "recover-table", "recover-rows", "recover-column", "as-of"} {
		mux.HandleFunc("POST /v1/storage/"+kind, func(w http.ResponseWriter, r *http.Request) {
			s.submitJob(w, r, kind)
		})
	}
	mux.HandleFunc("GET /v1/storage/backups", func(w http.ResponseWriter, r *http.Request) {
		bl, ok := s.client.(backupLister)
		if !ok {
			sendError(w, fmt.Errorf("backups listing not supported by this client"))
			return
		}
		rows, err := bl.Backups(r.Context())
		s.replyRows(w, rows, err)
	})
	mux.HandleFunc("GET /v1/jobs", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		limit, _ := strconv.Atoi(q.Get("limit"))
		jobs, err := s.store.List(r.Context(), q.Get("state"), q.Get("kind"), limit)
		if err != nil {
			sendError(w, err)
			return
		}
		if jobs == nil {
			jobs = []Job{}
		}
		writeJSON(w, http.StatusOK, jobs)
	})
	mux.HandleFunc("GET /v1/jobs/{id}", func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			badRequest(w, "invalid job id")
			return
		}
		job, err := s.store.Get(r.Context(), id)
		if err != nil {
			sendError(w, err)
			return
		}
		if job == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "job not found"})
			return
		}
		out := map[string]any{
			"id": job.ID, "kind": job.Kind, "args": job.Args, "state": job.State,
			"submitted_at": job.SubmittedAt, "started_at": job.StartedAt, "finished_at": job.FinishedAt,
			"output": job.Output, "error": job.Error, "progress": job.Progress,
			"events": s.run.jobEvents(id),
		}
		writeJSON(w, http.StatusOK, out)
	})
	mux.HandleFunc("POST /v1/jobs/{id}/cancel", func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			badRequest(w, "invalid job id")
			return
		}
		ok, err := s.run.cancel(r.Context(), id)
		if err != nil {
			sendError(w, err)
			return
		}
		if !ok {
			job, gerr := s.store.Get(r.Context(), id)
			if gerr == nil && job == nil {
				writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "job not found"})
				return
			}
			writeJSON(w, http.StatusConflict, map[string]any{"ok": false, "error": "job already finished"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "canceled": true})
	})

	// Root identity (handy smoke probe; carries no data, needs no token).
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"service": "eter-orchestrator"})
	})

	return s.auth(mux)
}

// auth guards /v1/* with the optional shared bearer token, byte-compatible
// with the TS server's hook (401 {"ok":false,"error":"unauthorized"}).
func (s *server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.apiToken != "" && len(r.URL.Path) >= 4 && r.URL.Path[:4] == "/v1/" {
			if r.Header.Get("Authorization") != "Bearer "+s.cfg.apiToken {
				writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "unauthorized"})
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// submitJob validates the args (the same argv mapping the runner uses),
// persists the job, pokes the runner, and 202s with the id.
func (s *server) submitJob(w http.ResponseWriter, r *http.Request, kind string) {
	if s.cfg.backupDir == "" {
		sendError(w, fmt.Errorf("storage not configured on the orchestrator (set ETER_BACKUP_DIR)"))
		return
	}
	var args map[string]any
	if !decode(w, r, &args) {
		return
	}
	if args == nil {
		args = map[string]any{}
	}
	if _, err := argv(kind, args); err != nil {
		badRequest(w, err.Error())
		return
	}
	id, err := s.store.Submit(r.Context(), kind, args)
	if err != nil {
		sendError(w, err)
		return
	}
	s.run.poke()
	writeJSON(w, http.StatusAccepted, map[string]any{"job_id": id, "state": "queued"})
}

// ---- shared helpers ----------------------------------------------------------

var (
	reDependent = regexp.MustCompile(`dependent transactions`)
	reNotFound  = regexp.MustCompile(`(?i)no tracked writes|not found`)
)

// sendError maps an engine/store error onto the TS server's status contract
// and echoes the message VERBATIM (the CLI's exit codes regex it).
func sendError(w http.ResponseWriter, err error) {
	msg := err.Error()
	code := http.StatusInternalServerError
	switch {
	case reDependent.MatchString(msg):
		code = http.StatusConflict
	case reNotFound.MatchString(msg):
		code = http.StatusNotFound
	}
	writeJSON(w, code, map[string]any{"ok": false, "error": msg})
}

func badRequest(w http.ResponseWriter, msg string) {
	writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": msg})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *server) reply(w http.ResponseWriter, v any, err error) {
	if err != nil {
		sendError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// replyRows writes a row list, normalizing nil → [] (the TS server always
// emitted arrays).
func (s *server) replyRows(w http.ResponseWriter, rows []map[string]any, err error) {
	if err != nil {
		sendError(w, err)
		return
	}
	if rows == nil {
		rows = []map[string]any{}
	}
	writeJSON(w, http.StatusOK, rows)
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.UseNumber()
	if err := dec.Decode(v); err != nil && err.Error() != "EOF" {
		badRequest(w, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

// decodeTxid reads {txid, mode?} accepting txid as number OR string (node-pg
// emitted bigints as strings; clients may echo them back).
func decodeTxid(w http.ResponseWriter, r *http.Request) (int64, eterclient.UndoMode, bool) {
	var body struct {
		Txid json.Number `json:"txid"`
		Mode string      `json:"mode"`
	}
	if !decode(w, r, &body) {
		return 0, "", false
	}
	txid, err := body.Txid.Int64()
	if err != nil {
		badRequest(w, "invalid txid")
		return 0, "", false
	}
	mode := eterclient.UndoMode(body.Mode)
	if body.Mode == "" {
		mode = eterclient.CleanOnly
	}
	return txid, mode, true
}

func decodeCohort(w http.ResponseWriter, r *http.Request) (eterclient.CohortSelector, eterclient.UndoMode, bool) {
	var body struct {
		Table       string         `json:"table"`
		Fingerprint string         `json:"fingerprint"`
		From        string         `json:"from"`
		To          string         `json:"to"`
		Predicate   map[string]any `json:"predicate"`
		Mode        string         `json:"mode"`
	}
	if !decode(w, r, &body) {
		return eterclient.CohortSelector{}, "", false
	}
	mode := eterclient.UndoMode(body.Mode)
	if body.Mode == "" {
		mode = eterclient.CleanOnly
	}
	return eterclient.CohortSelector{
		Table: body.Table, Fingerprint: body.Fingerprint,
		From: body.From, To: body.To, Predicate: body.Predicate,
	}, mode, true
}
