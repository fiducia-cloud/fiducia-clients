// High-level locking for the Fiducia Go client.
//
// Hand-written (NOT generated): adds live-mutex-style ergonomics on top of the
// generated thin Client. Two shapes:
//
//   - TryLock(keys)  — wait:false. Returns (lock, nil) if free now, or
//     (nil, nil) if it's held. Never blocks.
//   - Lock(keys) / MustLock(keys) — wait:true. Blocks (polling) until acquired,
//     the budget elapses (*LockTimeoutError), or the server errors.
//
// Counting semaphores get the same pair (TrySemaphore / AcquireSemaphore).
//
// The server never holds a request open: wait:true reserves a FIFO queue slot
// and returns immediately, so the client owns the wait — hence MaxWait,
// RetryInterval and MaxRetries live in LockOptions.

package fiducia

import (
	"fmt"
	"sync/atomic"
	"time"
)

// LockOptions tunes acquisition. Use DefaultLockOptions() for sane defaults.
type LockOptions struct {
	TTLMs         int64         // lease TTL ms (default 60000)
	Holder        string        // caller identity / release key (default generated)
	MaxWait       time.Duration // total wait budget for blocking Lock (default 30s)
	RetryInterval time.Duration // delay between polls while waiting (default 250ms)
	MaxRetries    int           // cap on poll attempts; 0 = unlimited
}

// DefaultLockOptions returns a 60s lease, 30s wait budget, 250ms poll interval.
func DefaultLockOptions() LockOptions {
	return LockOptions{TTLMs: 60000, MaxWait: 30 * time.Second, RetryInterval: 250 * time.Millisecond}
}

func (o LockOptions) withDefaults() LockOptions {
	if o.TTLMs == 0 {
		o.TTLMs = 60000
	}
	if o.MaxWait == 0 {
		o.MaxWait = 30 * time.Second
	}
	if o.RetryInterval == 0 {
		o.RetryInterval = 250 * time.Millisecond
	}
	if o.Holder == "" {
		o.Holder = genHolder()
	}
	return o
}

// Lock is a held grant. Call Release (alias Unlock) when done.
type Lock struct {
	c              *Client
	Keys           []string
	Holder         string
	FencingToken   int64
	LeaseExpiresMs int64
}

// Release frees the whole grant (every member key) by its fencing token.
func (l *Lock) Release() (map[string]any, error) { return l.c.LockRelease(l.Holder, l.FencingToken) }

// Unlock is an alias of Release.
func (l *Lock) Unlock() (map[string]any, error) { return l.Release() }

// SemaphoreHandle is a held permit. Call Release when done.
type SemaphoreHandle struct {
	c              *Client
	Key            string
	Holder         string
	FencingToken   int64
	LeaseExpiresMs int64
}

// Release returns one permit (admits the next FIFO waiter).
func (s *SemaphoreHandle) Release() (map[string]any, error) {
	return s.c.SemaphoreRelease(s.Key, s.Holder, s.FencingToken)
}

// Unlock is an alias of Release.
func (s *SemaphoreHandle) Unlock() (map[string]any, error) { return s.Release() }

// LockTimeoutError is returned by Lock/AcquireSemaphore when the wait budget elapses.
type LockTimeoutError struct {
	Keys   []string
	Waited time.Duration
}

func (e *LockTimeoutError) Error() string {
	return fmt.Sprintf("fiducia: timed out after %s waiting for %v", e.Waited, e.Keys)
}

var holderSeq uint64

func genHolder() string {
	return fmt.Sprintf("fdc-%x-%x", time.Now().UnixNano(), atomic.AddUint64(&holderSeq, 1))
}

// --- locks -----------------------------------------------------------------

// TryLock takes the union of keys now (wait:false). Returns (nil, nil) if held.
func (c *Client) TryLock(keys []string, opts LockOptions) (*Lock, error) {
	return c.acquireLock(keys, false, opts.withDefaults())
}

// Lock blocks until the union of keys is acquired, the budget elapses
// (*LockTimeoutError), or the server errors (wait:true).
func (c *Client) Lock(keys []string, opts LockOptions) (*Lock, error) {
	opts = opts.withDefaults()
	lock, err := c.acquireLock(keys, true, opts)
	if err != nil {
		return nil, err
	}
	if lock == nil {
		return nil, &LockTimeoutError{Keys: keys, Waited: opts.MaxWait}
	}
	return lock, nil
}

// MustLock is an alias of Lock — blocks until acquired (or errors).
func (c *Client) MustLock(keys []string, opts LockOptions) (*Lock, error) { return c.Lock(keys, opts) }

// WithLock acquires the union of keys, runs fn, then always releases.
func (c *Client) WithLock(keys []string, opts LockOptions, fn func(*Lock) error) error {
	lock, err := c.Lock(keys, opts)
	if err != nil {
		return err
	}
	defer lock.Release() // best-effort; lease TTL is the backstop
	return fn(lock)
}

func (c *Client) acquireLock(keys []string, wait bool, opts LockOptions) (*Lock, error) {
	first, err := c.LockAcquireMany(keys, map[string]any{
		"holder": opts.Holder, "ttl_ms": opts.TTLMs, "wait": wait,
	})
	if err != nil {
		return nil, err
	}
	out := output(first)
	if asBool(out["acquired"]) {
		return &Lock{c: c, Keys: keys, Holder: opts.Holder,
			FencingToken: asInt(out["fencing_token"]), LeaseExpiresMs: asInt(out["lease_expires_ms"])}, nil
	}
	if !wait {
		return nil, nil // TryLock: held now → fail fast
	}

	probe := ""
	if len(keys) > 0 {
		probe = keys[0]
	}
	deadline := time.Now().Add(opts.MaxWait)
	for attempt := 0; opts.MaxRetries == 0 || attempt < opts.MaxRetries; attempt++ {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		time.Sleep(minDur(opts.RetryInterval, remaining))
		got, err := c.LockGet(probe)
		if err != nil {
			return nil, err
		}
		lk := asMap(got["lock"])
		if asString(lk["holder"]) == opts.Holder {
			if tok, ok := lk["fencing_token"]; ok && tok != nil {
				return &Lock{c: c, Keys: keys, Holder: opts.Holder,
					FencingToken: asInt(tok), LeaseExpiresMs: asInt(lk["lease_expires_ms"])}, nil
			}
		}
	}
	return nil, nil
}

// --- counting semaphores ---------------------------------------------------

// TrySemaphore takes a permit now (wait:false). Returns (nil, nil) if at capacity.
func (c *Client) TrySemaphore(key string, limit int64, opts LockOptions) (*SemaphoreHandle, error) {
	return c.acquireSemaphore(key, limit, false, opts.withDefaults())
}

// AcquireSemaphore blocks until a permit is free, the budget elapses, or error.
func (c *Client) AcquireSemaphore(key string, limit int64, opts LockOptions) (*SemaphoreHandle, error) {
	opts = opts.withDefaults()
	h, err := c.acquireSemaphore(key, limit, true, opts)
	if err != nil {
		return nil, err
	}
	if h == nil {
		return nil, &LockTimeoutError{Keys: []string{key}, Waited: opts.MaxWait}
	}
	return h, nil
}

func (c *Client) acquireSemaphore(key string, limit int64, wait bool, opts LockOptions) (*SemaphoreHandle, error) {
	first, err := c.SemaphoreAcquire(key, limit, map[string]any{
		"holder": opts.Holder, "ttl_ms": opts.TTLMs, "wait": wait,
	})
	if err != nil {
		return nil, err
	}
	out := output(first)
	if asBool(out["acquired"]) {
		return &SemaphoreHandle{c: c, Key: key, Holder: opts.Holder,
			FencingToken: asInt(out["fencing_token"]), LeaseExpiresMs: asInt(out["lease_expires_ms"])}, nil
	}
	if !wait {
		return nil, nil
	}

	deadline := time.Now().Add(opts.MaxWait)
	for attempt := 0; opts.MaxRetries == 0 || attempt < opts.MaxRetries; attempt++ {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		time.Sleep(minDur(opts.RetryInterval, remaining))
		got, err := c.SemaphoreGet(key)
		if err != nil {
			return nil, err
		}
		sem := asMap(got["semaphore"])
		holders, _ := sem["holders"].([]any)
		for _, h := range holders {
			slot := asMap(h)
			if asString(slot["holder"]) == opts.Holder {
				if tok, ok := slot["fencing_token"]; ok && tok != nil {
					return &SemaphoreHandle{c: c, Key: key, Holder: opts.Holder,
						FencingToken: asInt(tok), LeaseExpiresMs: asInt(slot["lease_expires_ms"])}, nil
				}
			}
		}
	}
	return nil, nil
}

// --- JSON helpers (responses come back as map[string]any) ------------------

func output(resp map[string]any) map[string]any {
	return asMap(asMap(resp["result"])["output"])
}

func asMap(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func asBool(v any) bool {
	b, _ := v.(bool)
	return b
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}

// asInt coerces a JSON number (float64) — or an int64 — to int64.
func asInt(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int64:
		return n
	case int:
		return int64(n)
	default:
		return 0
	}
}

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
