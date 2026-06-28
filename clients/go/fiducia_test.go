package fiducia

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type recordedCall struct {
	Method string
	Path   string
	Body   map[string]any
}

func recordingServer(t *testing.T) (*httptest.Server, *[]recordedCall) {
	t.Helper()
	calls := []recordedCall{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := map[string]any(nil)
		if r.Body != nil && r.ContentLength != 0 {
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode request body: %v", err)
			}
		}
		calls = append(calls, recordedCall{
			Method: r.Method,
			Path:   r.URL.RequestURI(),
			Body:   body,
		})
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	return server, &calls
}

func requireLastCall(t *testing.T, calls *[]recordedCall, expected recordedCall) {
	t.Helper()
	if len(*calls) == 0 {
		t.Fatalf("expected recorded call, got none")
	}
	got := (*calls)[len(*calls)-1]
	gotJSON, _ := json.Marshal(got)
	expectedJSON, _ := json.Marshal(expected)
	if string(gotJSON) != string(expectedJSON) {
		t.Fatalf("call mismatch\ngot:  %s\nwant: %s", gotJSON, expectedJSON)
	}
}

func TestCoordinationRoutesMatchNodeContract(t *testing.T) {
	server, calls := recordingServer(t)
	defer server.Close()
	client := New(server.URL)

	if _, err := client.LockGet("orders/42"); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{"GET", "/v1/locks?key=orders%2F42", nil})

	if _, err := client.TryLock("orders/42", AcquireOpts{Holder: "worker-a"}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/locks/acquire",
		Body:   map[string]any{"key": "orders/42", "holder": "worker-a", "wait": false},
	})

	if _, err := client.MustLockMany(AcquireManyOpts{Keys: []string{"orders/42", "inventory/sku-7"}, Holder: "worker-a", TTLMs: 30000}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/locks/acquire",
		Body: map[string]any{
			"keys":   []any{"orders/42", "inventory/sku-7"},
			"holder": "worker-a",
			"ttl_ms": float64(30000),
			"wait":   true,
		},
	})

	if _, err := client.LockRelease("orders/42", ReleaseOpts{Holder: "worker-a", FencingToken: 11}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/locks/release",
		Body:   map[string]any{"holder": "worker-a", "fencing_token": float64(11)},
	})

	if _, err := client.LockReleaseMany("legacy-lock-id"); err == nil {
		t.Fatal("expected legacy lock release-many to fail locally")
	}

	if _, err := client.TrySemaphore("pools/db/primary", AcquireOpts{}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/semaphores/acquire",
		Body:   map[string]any{"key": "pools/db/primary", "wait": false, "limit": float64(2)},
	})

	if _, err := client.SemaphoreRelease("pools/db/primary", ReleaseOpts{Holder: "worker-b", FencingToken: 12}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/semaphores/release",
		Body:   map[string]any{"key": "pools/db/primary", "holder": "worker-b", "fencing_token": float64(12)},
	})
}

func TestServiceDiscoverySendsMetadataAndHeartbeatBody(t *testing.T) {
	server, calls := recordingServer(t)
	defer server.Close()
	client := New(server.URL)

	if _, err := client.ServiceRegisterWithMetadata("api", "i-1", "10.0.0.1:9000", 10000, map[string]string{"region": "eu-central-1"}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "PUT",
		Path:   "/v1/services/api/instances/i-1",
		Body: map[string]any{
			"address":  "10.0.0.1:9000",
			"ttl_ms":   float64(10000),
			"metadata": map[string]any{"region": "eu-central-1"},
		},
	})

	if _, err := client.ServiceHeartbeat("api", "i-1"); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/services/api/instances/i-1/heartbeat",
		Body:   map[string]any{},
	})
}
