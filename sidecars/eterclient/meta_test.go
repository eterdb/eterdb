package eterclient

import "testing"

const (
	tenant  = "postgres://eter:eter@localhost:5432/eter"
	store   = "postgres://eter:eter@localhost:5433/eter_meta"
	tenant2 = "postgres://eter:eter@localhost:5432/eter?sslmode=disable" // same db, respelled
)

// RequireMetaURL enforces issue #67: a separate metadata store is mandatory in
// the deployment runtime unless single-DB is explicitly acknowledged.
func TestRequireMetaURL(t *testing.T) {
	cases := []struct {
		name         string
		meta         string // ETER_META_URL
		allow        string // ETER_ALLOW_SINGLE_DB
		wantErr      bool
		wantSeparate bool
		wantURL      string
	}{
		{name: "unset is a hard error", meta: "", allow: "", wantErr: true},
		{name: "unset + allow → single-DB tenant", meta: "", allow: "1", wantSeparate: false, wantURL: tenant},
		{name: "separate store", meta: store, allow: "", wantSeparate: true, wantURL: store},
		{name: "separate store even with allow", meta: store, allow: "1", wantSeparate: true, wantURL: store},
		{name: "meta == tenant is a hard error", meta: tenant, allow: "", wantErr: true},
		{name: "meta re-spells tenant is a hard error", meta: tenant2, allow: "", wantErr: true},
		{name: "meta == tenant + allow → single-DB", meta: tenant, allow: "1", wantSeparate: false, wantURL: tenant},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("ETER_META_URL", tc.meta)
			t.Setenv("ETER_ALLOW_SINGLE_DB", tc.allow)
			url, separate, err := RequireMetaURL(tenant)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got url=%q separate=%v", url, separate)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if separate != tc.wantSeparate {
				t.Fatalf("separate = %v, want %v", separate, tc.wantSeparate)
			}
			if url != tc.wantURL {
				t.Fatalf("url = %q, want %q", url, tc.wantURL)
			}
		})
	}
}

func TestAllowSingleDBTruthiness(t *testing.T) {
	for _, v := range []string{"1", "true", "TRUE", "yes", "on"} {
		t.Setenv("ETER_ALLOW_SINGLE_DB", v)
		if !allowSingleDB() {
			t.Fatalf("%q should be truthy", v)
		}
	}
	for _, v := range []string{"", "0", "false", "no", "off", "nope"} {
		t.Setenv("ETER_ALLOW_SINGLE_DB", v)
		if allowSingleDB() {
			t.Fatalf("%q should be falsy", v)
		}
	}
}
