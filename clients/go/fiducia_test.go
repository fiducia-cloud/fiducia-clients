// Tests for the generated Fiducia Go client.
package fiducia

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) { return fn(req) }

type truncatedBody struct{}

func (*truncatedBody) Read(p []byte) (int, error) {
	return copy(p, `{"ok":`), io.ErrUnexpectedEOF
}

func (*truncatedBody) Close() error { return nil }

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

	if _, err := client.LockAcquire("orders/42", AcquireOpts{Holder: "worker-a", Wait: false}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/locks/acquire",
		Body:   map[string]any{"key": "orders/42", "holder": "worker-a", "wait": false},
	})

	if _, err := client.LockAcquireMany(AcquireManyOpts{
		Keys: []string{"orders/42", "inventory/sku-7"}, Holder: "worker-a", TTLMs: 30000, Wait: true,
	}); err != nil {
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

	if _, err := client.SemaphoreAcquire("pools/db/primary", AcquireOpts{Max: 2, Wait: false}); err != nil {
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

	if _, err := client.IdempotencyGet("stripe-webhook/event_123"); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{"GET", "/v1/idempotency?key=stripe-webhook%2Fevent_123", nil})

	if _, err := client.IdempotencyClaim("stripe-webhook/event_123", IdempotencyClaimOpts{
		Owner: "worker-a", TTL: "24h", Metadata: map[string]string{"source": "stripe"},
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

	if _, err := client.IdempotencyComplete("stripe-webhook/event_123", IdempotencyCompleteOpts{
		Owner: "worker-a", FencingToken: 11, Result: map[string]any{"status": "ok"},
	}); err != nil {
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

	if _, err := client.ElectionCampaignWithMetadata(
		"prod/invoice-reconciler/leader", "pod-a", 15000,
		map[string]string{"address": "10.2.4.18:8080", "region": "us-east-1"},
	); err != nil {
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

	if _, err := client.ServiceRegisterWithMetadata(
		"api", "i-1", "10.0.0.1:9000", 10000,
		map[string]string{"region": "eu-central-1"},
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

	if _, err := client.ServiceHeartbeat("api", "i-1"); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "POST",
		Path:   "/v1/services/api/instances/i-1/heartbeat",
		Body:   map[string]any{},
	})

	if _, err := client.ServiceInstancesWithMetadata("api", map[string]string{
		"version": "blue/1", "region": "eu central",
	}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{
		Method: "GET",
		Path:   "/v1/services/api?metadata.region=eu+central&metadata.version=blue%2F1",
	})
}

func TestServiceInstancesIgnoresBlankMetadataKeys(t *testing.T) {
	server, calls := recordingServer(t)
	defer server.Close()
	client := New(server.URL)
	if _, err := client.ServiceInstancesWithMetadata("api", map[string]string{"": "ignored", "region": "eu central"}); err != nil {
		t.Fatal(err)
	}
	requireLastCall(t, calls, recordedCall{Method: "GET", Path: "/v1/services/api?metadata.region=eu+central"})
}

func TestKeylessPostIsNotRetried(t *testing.T) {
	var keys []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		keys = append(keys, r.Header.Get("Idempotency-Key"))
		if len(keys) == 1 {
			http.Error(w, "try again", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	client := New(server.URL)
	client.RetryMax = 1
	if _, err := client.TryLock("orders/42", AcquireOpts{Holder: "worker-a"}); err == nil {
		t.Fatal("keyless mutation unexpectedly succeeded after retry")
	}
	if len(keys) != 1 || keys[0] != "" {
		t.Fatalf("keyless mutation must make one keyless attempt: %#v", keys)
	}
}

func TestRetryKeepsCallerKeyAndLeavesSafeOrSingleShotCallsKeyless(t *testing.T) {
	var calls []struct {
		method string
		key    string
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, struct {
			method string
			key    string
		}{r.Method, r.Header.Get("Idempotency-Key")})
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	retrying := New(server.URL)
	retrying.RetryMax = 1
	if _, err := retrying.TryLock("orders/42", AcquireOpts{
		Holder:         "worker-a",
		IdempotencyKey: "caller-key",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := retrying.LockGet("orders/42"); err != nil {
		t.Fatal(err)
	}
	if _, err := New(server.URL).TryLock("orders/43", AcquireOpts{Holder: "worker-a"}); err != nil {
		t.Fatal(err)
	}

	want := []struct {
		method string
		key    string
	}{{"POST", "caller-key"}, {"GET", ""}, {"POST", ""}}
	if len(calls) != len(want) {
		t.Fatalf("call count: got %d want %d", len(calls), len(want))
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Fatalf("call %d: got %#v want %#v", i, calls[i], want[i])
		}
	}
}

func TestRedirectIsNotFollowedOrRetried(t *testing.T) {
	attackerHits := 0
	attacker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attackerHits++
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"stolen":true}`))
	}))
	defer attacker.Close()

	redirectHits := 0
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirectHits++
		http.Redirect(w, r, attacker.URL+"/stolen", http.StatusFound)
	}))
	defer redirect.Close()

	client := New(redirect.URL)
	client.RetryMax = 3
	_, err := client.TryLock("orders/42", AcquireOpts{Holder: "worker-a"})
	httpErr, ok := err.(*Error)
	if !ok {
		t.Fatalf("expected *Error, got %T (%v)", err, err)
	}
	if httpErr.Status != http.StatusFound || httpErr.Body["error"] != "redirect_not_followed" {
		t.Fatalf("unexpected redirect error: %#v", httpErr)
	}
	if httpErr.Body["location"] != attacker.URL+"/stolen" {
		t.Fatalf("redirect location mismatch: %#v", httpErr.Body)
	}
	if redirectHits != 1 || attackerHits != 0 {
		t.Fatalf("redirect followed or retried: redirect=%d attacker=%d", redirectHits, attackerHits)
	}
}

func TestTruncatedSuccessfulMutationResponseRetriesWithTheSameKey(t *testing.T) {
	var calls int
	var keys []string
	client := New("https://fiducia.test")
	client.RetryMax = 1
	client.HTTP = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		keys = append(keys, req.Header.Get("Idempotency-Key"))
		body := io.ReadCloser(&truncatedBody{})
		if calls == 2 {
			body = io.NopCloser(strings.NewReader(`{"ok":true}`))
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       body,
			Request:    req,
		}, nil
	})}

	if _, err := client.TryLock("orders/42", AcquireOpts{
		Holder:         "worker-a",
		IdempotencyKey: "caller-key",
	}); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || keys[0] == "" || keys[0] != keys[1] {
		t.Fatalf("truncated response must retry once with one stable key: calls=%d keys=%#v", calls, keys)
	}
}

func TestTruncatedErrorResponsePreservesStatusAndIsNotRetried(t *testing.T) {
	var calls int
	client := New("https://fiducia.test")
	client.RetryMax = 3
	client.HTTP = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{
			StatusCode: http.StatusUnauthorized,
			Header:     make(http.Header),
			Body:       &truncatedBody{},
			Request:    req,
		}, nil
	})}

	_, err := client.LockGet("orders/42")
	httpErr, ok := err.(*Error)
	if !ok {
		t.Fatalf("expected *Error, got %T (%v)", err, err)
	}
	if httpErr.Status != http.StatusUnauthorized || httpErr.Body["error"] != "truncated_error_response" {
		t.Fatalf("truncated response lost authoritative status: %#v", httpErr)
	}
	if calls != 1 {
		t.Fatalf("401 response must not retry after body read failure: %d calls", calls)
	}
}

func TestMalformedSuccessfulJSONIsAnError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":`))
	}))
	defer server.Close()

	if _, err := New(server.URL).LockGet("orders/42"); err == nil {
		t.Fatal("malformed successful JSON must not be reported as success")
	}
}
