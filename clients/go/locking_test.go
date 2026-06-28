package fiducia

import (
	"testing"
	"time"
)

func TestAsIntCoercesJSONNumbers(t *testing.T) {
	if asInt(float64(42)) != 42 {
		t.Fatal("float64 not coerced")
	}
	if asInt(nil) != 0 {
		t.Fatal("nil should be 0")
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
	if _, err := c.TryLock([]string{"k"}, opts); err == nil {
		t.Fatal("expected transport error from dead server")
	}
}
