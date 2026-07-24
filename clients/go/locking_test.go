// Tests for the high-level locking helpers in the Fiducia Go client.
package fiducia

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGeneratedHolderIsUnguessableAndUnique(t *testing.T) {
	a, err := generatedHolder()
	if err != nil {
		t.Fatal(err)
	}
	b, err := generatedHolder()
	if err != nil {
		t.Fatal(err)
	}
	if a == b || !strings.HasPrefix(a, "fdc-") || len(a) != 36 {
		t.Fatalf("unexpected holder identities %q and %q", a, b)
	}
}

func TestGeneratedRequestIDIsUnguessableAndUnique(t *testing.T) {
	a, err := generatedRequestID()
	if err != nil {
		t.Fatal(err)
	}
	b, err := generatedRequestID()
	if err != nil {
		t.Fatal(err)
	}
	if a == b || !strings.HasPrefix(a, "fdc-attempt-") || len(a) != 44 {
		t.Fatalf("unexpected request identities %q and %q", a, b)
	}
}

func TestAttemptRequestIDValidation(t *testing.T) {
	for _, requestID := range []string{"   ", strings.Repeat("x", 129), "bad\x00id"} {
		if err := validateAttemptRequestIDs(map[string]any{"request_id": requestID}, "request"); err == nil {
			t.Fatalf("expected invalid request id %q", requestID)
		}
	}
	if err := validateAttemptRequestIDs(map[string]any{"request_id": "fdc-attempt-123"}, "request"); err != nil {
		t.Fatal(err)
	}
}

func TestAsIntCoercesJSONNumbers(t *testing.T) {
	if asInt(float64(42)) != 42 {
		t.Fatal("float64 not coerced")
	}
	if asInt(nil) != 0 {
		t.Fatal("nil should be 0")
	}
	if asInt(json.Number("9007199254740991")) != 9007199254740991 {
		t.Fatal("exact JSON integer was not preserved")
	}
	if asInt(json.Number("9007199254740991.5")) != 0 {
		t.Fatal("fractional JSON number must be rejected")
	}
}

func TestAttemptIDIsReusedAcrossRetriesAndCancellation(t *testing.T) {
	type call struct {
		path string
		body map[string]any
	}
	var calls []call
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := map[string]any{}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
		}
		calls = append(calls, call{path: r.URL.Path, body: body})
		output := map[string]any{"acquired": false, "queued": true}
		if strings.HasSuffix(r.URL.Path, "/cancel") {
			output = map[string]any{"cancelled": true, "acquired": false}
		}
		w.Header().Set("content-type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"output": output}})
	}))
	defer server.Close()

	client := New(server.URL)
	opts := DefaultLockOptions()
	opts.Holder = "stable-worker"
	opts.MaxWait = 50 * time.Millisecond
	opts.RetryInterval = time.Millisecond
	opts.MaxRetries = 1
	if _, err := client.LockHandle([]string{"orders/42"}, opts); err == nil {
		t.Fatal("expected lock timeout")
	}

	var ids []string
	for _, got := range calls {
		if strings.HasPrefix(got.path, "/v1/locks/") {
			id, _ := got.body["request_id"].(string)
			ids = append(ids, id)
		}
	}
	if len(ids) != 3 || ids[0] == "" || ids[0] != ids[1] || ids[0] != ids[2] {
		t.Fatalf("lock attempt request ids were not reused: %#v", ids)
	}

	calls = nil
	if _, err := client.AcquireSemaphore("pool", 2, opts); err == nil {
		t.Fatal("expected semaphore timeout")
	}
	ids = nil
	for _, got := range calls {
		if strings.HasPrefix(got.path, "/v1/semaphores/") {
			id, _ := got.body["request_id"].(string)
			ids = append(ids, id)
		}
	}
	if len(ids) != 3 || ids[0] == "" || ids[0] != ids[1] || ids[0] != ids[2] {
		t.Fatalf("semaphore attempt request ids were not reused: %#v", ids)
	}
}

func TestInitialRenewedFalseIsRenewedBeforeHandleReturns(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		semaphore := strings.Contains(r.URL.Path, "semaphores")
		renew := strings.HasSuffix(r.URL.Path, "/renew")
		token := 71
		expires := 100
		if semaphore {
			token = 72
			expires = 300
		}
		output := map[string]any{
			"acquired": true, "queued": false, "renewed": false,
			"fencing_token": token, "lease_expires_ms": expires,
		}
		if renew {
			expires += 100
			output = map[string]any{
				"renewed": true, "fencing_token": token, "lease_expires_ms": expires,
			}
		}
		w.Header().Set("content-type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"output": output}})
	}))
	defer server.Close()

	client := New(server.URL)
	opts := DefaultLockOptions()
	opts.Holder = "stable-worker"
	lock, err := client.TryLockHandle([]string{"orders/42"}, opts)
	if err != nil {
		t.Fatal(err)
	}
	permit, err := client.TrySemaphoreHandle("pool", 2, opts)
	if err != nil {
		t.Fatal(err)
	}
	if lock.LeaseExpiresMs != 200 || permit.LeaseExpiresMs != 400 {
		t.Fatalf("handles returned before renewal: lock=%d permit=%d", lock.LeaseExpiresMs, permit.LeaseExpiresMs)
	}
}

func TestCancellationCapacityIsSurfacedAsUnsafe(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"output": map[string]any{
			"cancelled": false, "acquired": false, "reason": "cancellation_capacity",
		}}})
	}))
	defer server.Close()

	client := New(server.URL)
	if err := client.cancelLockWait([]string{"orders/42"}, "stable-worker", "attempt-1"); err == nil || !strings.Contains(err.Error(), "cancellation_capacity") {
		t.Fatalf("expected lock capacity failure, got %v", err)
	}
	if err := client.cancelSemaphoreWait("pool", "stable-worker", "attempt-2"); err == nil || !strings.Contains(err.Error(), "cancellation_capacity") {
		t.Fatalf("expected semaphore capacity failure, got %v", err)
	}
}

func TestOutputUnwrapsEnvelope(t *testing.T) {
	resp := map[string]any{"result": map[string]any{"output": map[string]any{"acquired": true}}}
	if !asBool(output(resp)["acquired"]) {
		t.Fatal("output did not unwrap result.output")
	}
}

func TestTryLockAgainstDeadServerErrors(t *testing.T) {
	c := New("http://127.0.0.1:1")
	opts := DefaultLockOptions()
	opts.MaxWait = 50 * time.Millisecond
	if _, err := c.TryLockHandle([]string{"k"}, opts); err == nil {
		t.Fatal("expected transport error from dead server")
	}
}
