// Tests for the generated Fiducia Go client.
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

	if _, err := client.LockAcquire("orders/42", map[string]any{"holder": "worker-a", "wait": false}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/locks/acquire",
		Body:   map[string]any{"key": "orders/42", "holder": "worker-a", "wait": false},
	})

	if _, err := client.LockAcquireMany(
		[]string{"orders/42", "inventory/sku-7"},
		map[string]any{"holder": "worker-a", "ttl_ms": 30000, "wait": true},
	); err != nil {
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

	if _, err := client.LockRelease("worker-a", 11); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/locks/release",
		Body:   map[string]any{"holder": "worker-a", "fencing_token": float64(11)},
	})

	if _, err := client.SemaphoreAcquire("pools/db/primary", 2, map[string]any{"wait": false}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/semaphores/acquire",
		Body:   map[string]any{"key": "pools/db/primary", "wait": false, "limit": float64(2)},
	})

	if _, err := client.SemaphoreRelease("pools/db/primary", "worker-b", 12); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/semaphores/release",
		Body:   map[string]any{"key": "pools/db/primary", "holder": "worker-b", "fencing_token": float64(12)},
	})

	if _, err := client.IdempotencyGet("stripe-webhook/event_123"); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{"GET", "/v1/idempotency?key=stripe-webhook%2Fevent_123", nil})

	if _, err := client.IdempotencyClaim("stripe-webhook/event_123", map[string]any{
		"owner": "worker-a", "ttl": "24h", "metadata": map[string]string{"source": "stripe"},
	}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/idempotency/claim",
		Body: map[string]any{
			"key":      "stripe-webhook/event_123",
			"owner":    "worker-a",
			"ttl":      "24h",
			"metadata": map[string]any{"source": "stripe"},
		},
	})

	if _, err := client.IdempotencyComplete(
		"stripe-webhook/event_123",
		"worker-a",
		11,
		map[string]any{"result": map[string]any{"status": "ok"}},
	); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/idempotency/complete",
		Body: map[string]any{
			"key":           "stripe-webhook/event_123",
			"owner":         "worker-a",
			"fencing_token": float64(11),
			"result":        map[string]any{"status": "ok"},
		},
	})

	if _, err := client.ElectionCampaign("prod/invoice-reconciler/leader", "pod-a", 15000, map[string]any{
		"metadata": map[string]string{"address": "10.2.4.18:8080", "region": "us-east-1"},
	}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/elections/prod%2Finvoice-reconciler%2Fleader/campaign",
		Body: map[string]any{
			"candidate": "pod-a",
			"ttl_ms":    float64(15000),
			"metadata":  map[string]any{"address": "10.2.4.18:8080", "region": "us-east-1"},
		},
	})
}

func TestServiceDiscoverySendsMetadataAndHeartbeatBody(t *testing.T) {
	server, calls := recordingServer(t)
	defer server.Close()
	client := New(server.URL)

	if _, err := client.ServiceRegister(
		"api", "i-1", "10.0.0.1:9000", 10000,
		map[string]any{"metadata": map[string]string{"region": "eu-central-1"}},
	); err != nil {
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

	if _, err := client.ServiceHeartbeat("api", "i-1", nil); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/services/api/instances/i-1/heartbeat",
		Body:   map[string]any{},
	})

	if _, err := client.ServiceInstances("api", map[string]any{
		"metadata": map[string]string{"version": "blue/1", "region": "eu central"},
	}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "GET",
		Path:   "/v1/services/api?metadata.region=eu+central&metadata.version=blue%2F1",
	})
}

func TestServiceInstancesRejectsInvalidMetadata(t *testing.T) {
	client := New("https://fiducia.invalid")
	if _, err := client.ServiceInstances("api", map[string]any{"metadata": "not-a-map"}); err == nil {
		t.Fatal("expected invalid metadata to fail before an HTTP request")
	}
}
