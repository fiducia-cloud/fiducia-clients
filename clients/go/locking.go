// High-level locking for the Fiducia Go client.
//
// Hand-written (NOT generated): adds live-mutex-style ergonomics on top of the
// generated thin Client. Two shapes:
//
//   - TryLockHandle(keys)  — wait:false. Returns (lock, nil) if free now, or
//     (nil, nil) if it's held. Never blocks.
//   - LockHandle(keys) / MustLockHandle(keys) — wait:true. Blocks until acquired,
//     the budget elapses (*LockTimeoutError), or the server errors.
//
// Counting semaphores get the same pair (TrySemaphore / AcquireSemaphore).
//
// The server never holds a request open: wait:true reserves a FIFO queue slot
// and returns immediately, so the client owns the wait — hence MaxWait,
// RetryInterval and MaxRetries live in LockOptions.

package fiducia

import (
	"encoding/json"
	"fmt"
	"strings"
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

func (o LockOptions) withDefaults() (LockOptions, error) {
	if o.TTLMs == 0 {
		o.TTLMs = 60000
	}
	if o.MaxWait == 0 {
		o.MaxWait = 30 * time.Second
	}
	if o.RetryInterval == 0 {
		o.RetryInterval = 250 * time.Millisecond
	}
	if o.Holder = strings.TrimSpace(o.Holder); o.Holder == "" {
		holder, err := generatedHolder()
		if err != nil {
			return o, err
		}
		o.Holder = holder
	}
	return o, nil
}

// Lock is a held grant. Call Release (alias Unlock) when done.
type Lock struct {
	c              *Client
	Keys           []string
	Holder         string
	FencingToken   int64
	LeaseExpiresMs int64
	TTLMs          int64
}

// Release frees the whole grant (every member key) by its fencing token.
func (l *Lock) Release() (map[string]any, error) {
	key := ""
	if len(l.Keys) > 0 {
		key = l.Keys[0]
	}
	return l.c.LockRelease(key, ReleaseOpts{Holder: l.Holder, FencingToken: uint64(l.FencingToken)})
}

// Unlock is an alias of Release.
func (l *Lock) Unlock() (map[string]any, error) { return l.Release() }

// Renew extends this grant only while its holder, key set, and fencing token
// still match. Passing 0 reuses the acquisition TTL.
func (l *Lock) Renew(ttlMs int64) (map[string]any, error) {
	if ttlMs == 0 {
		ttlMs = l.TTLMs
	}
	resp, err := l.c.LockRenew(l.Keys, l.Holder, l.FencingToken, ttlMs)
	if err != nil {
		return nil, err
	}
	out := output(resp)
	if !asBool(out["renewed"]) {
		return nil, fmt.Errorf("fiducia: lock renewal lost fenced authority")
	}
	l.LeaseExpiresMs = asInt(out["lease_expires_ms"])
	l.TTLMs = ttlMs
	return resp, nil
}

// SemaphoreHandle is a held permit. Call Release when done.
type SemaphoreHandle struct {
	c              *Client
	Key            string
	Holder         string
	FencingToken   int64
	LeaseExpiresMs int64
	TTLMs          int64
}

// Release returns one permit (admits the next FIFO waiter).
func (s *SemaphoreHandle) Release() (map[string]any, error) {
	return s.c.SemaphoreRelease(s.Key, ReleaseOpts{Holder: s.Holder, FencingToken: uint64(s.FencingToken)})
}

// Unlock is an alias of Release.
func (s *SemaphoreHandle) Unlock() (map[string]any, error) { return s.Release() }

// Renew extends this permit without changing its fencing token. Passing 0
// reuses the acquisition TTL.
func (s *SemaphoreHandle) Renew(ttlMs int64) (map[string]any, error) {
	if ttlMs == 0 {
		ttlMs = s.TTLMs
	}
	resp, err := s.c.SemaphoreRenew(s.Key, s.Holder, s.FencingToken, ttlMs)
	if err != nil {
		return nil, err
	}
	out := output(resp)
	if !asBool(out["renewed"]) {
		return nil, fmt.Errorf("fiducia: semaphore renewal lost fenced authority")
	}
	s.LeaseExpiresMs = asInt(out["lease_expires_ms"])
	s.TTLMs = ttlMs
	return resp, nil
}

// LockTimeoutError is returned by Lock/AcquireSemaphore when the wait budget elapses.
type LockTimeoutError struct {
	Keys   []string
	Waited time.Duration
}

func (e *LockTimeoutError) Error() string {
	return fmt.Sprintf("fiducia: timed out after %s waiting for %v", e.Waited, e.Keys)
}

// --- locks -----------------------------------------------------------------

// TryLockHandle takes the union of keys now (wait:false). It is deliberately
// named separately from the thin single-key TryLock method.
func (c *Client) TryLockHandle(keys []string, opts LockOptions) (*Lock, error) {
	resolved, err := opts.withDefaults()
	if err != nil {
		return nil, err
	}
	return c.acquireLock(keys, false, resolved)
}

// LockHandle blocks until the union of keys is acquired, the budget elapses
// (*LockTimeoutError), or the server errors (wait:true).
func (c *Client) LockHandle(keys []string, opts LockOptions) (*Lock, error) {
	var err error
	opts, err = opts.withDefaults()
	if err != nil {
		return nil, err
	}
	lock, err := c.acquireLock(keys, true, opts)
	if err != nil {
		return nil, err
	}
	if lock == nil {
		return nil, &LockTimeoutError{Keys: keys, Waited: opts.MaxWait}
	}
	return lock, nil
}

// MustLockHandle is an alias of LockHandle — blocks until acquired (or errors).
func (c *Client) MustLockHandle(keys []string, opts LockOptions) (*Lock, error) {
	return c.LockHandle(keys, opts)
}

// WithLock acquires the union of keys, runs fn, then always releases.
func (c *Client) WithLock(keys []string, opts LockOptions, fn func(*Lock) error) error {
	lock, err := c.LockHandle(keys, opts)
	if err != nil {
		return err
	}
	defer lock.Release() // best-effort; lease TTL is the backstop
	return fn(lock)
}

func (c *Client) acquireLock(keys []string, wait bool, opts LockOptions) (result *Lock, err error) {
	requestID, err := generatedRequestID()
	if err != nil {
		return nil, err
	}
	waitTimeoutMs := int64(0)
	if wait {
		waitTimeoutMs = opts.MaxWait.Milliseconds()
	}
	first, err := c.LockAcquireMany(AcquireManyOpts{
		Keys: keys, Holder: opts.Holder, TTLMs: opts.TTLMs, Wait: wait,
		WaitTimeoutMs: waitTimeoutMs, RequestID: requestID,
	})
	if err != nil {
		if cancelErr := c.cancelLockWait(keys, opts.Holder, requestID); cancelErr != nil {
			return nil, cancelErr
		}
		return nil, err
	}
	out := output(first)
	if asBool(out["acquired"]) {
		token := asInt(out["fencing_token"])
		if token <= 0 {
			return nil, fmt.Errorf("fiducia: acquired lock carried no fencing token")
		}
		leaseExpiresMs := asInt(out["lease_expires_ms"])
		if renewed, present := out["renewed"].(bool); present && !renewed {
			response, renewErr := c.LockRenew(keys, opts.Holder, token, opts.TTLMs)
			if renewErr != nil {
				if cancelErr := c.cancelLockWait(keys, opts.Holder, requestID); cancelErr != nil {
					return nil, cancelErr
				}
				return nil, renewErr
			}
			renewedOut := output(response)
			if !asBool(renewedOut["renewed"]) {
				if cancelErr := c.cancelLockWait(keys, opts.Holder, requestID); cancelErr != nil {
					return nil, cancelErr
				}
				return nil, fmt.Errorf("fiducia: reacquired lock lost fenced authority during renewal")
			}
			leaseExpiresMs = asInt(renewedOut["lease_expires_ms"])
		}
		return &Lock{c: c, Keys: keys, Holder: opts.Holder,
			FencingToken: token, LeaseExpiresMs: leaseExpiresMs, TTLMs: opts.TTLMs}, nil
	}
	if !wait {
		return nil, nil // TryLock: held now → fail fast
	}

	deadline := time.Now().Add(opts.MaxWait)
	acquired := false
	defer func() {
		if !acquired {
			if cancelErr := c.cancelLockWait(keys, opts.Holder, requestID); cancelErr != nil {
				result = nil
				err = cancelErr
			}
		}
	}()
	for attempt := 0; opts.MaxRetries == 0 || attempt < opts.MaxRetries; attempt++ {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		backoff := opts.RetryInterval * time.Duration(1<<minInt(attempt, 3))
		time.Sleep(minDur(minDur(backoff, 2*time.Second), remaining))
		got, err := c.LockAcquireMany(AcquireManyOpts{
			Keys: keys, Holder: opts.Holder, TTLMs: opts.TTLMs, Wait: true,
			WaitTimeoutMs: waitTimeoutMs, RequestID: requestID,
		})
		if err != nil {
			return nil, err
		}
		out := output(got)
		if asBool(out["acquired"]) {
			token := asInt(out["fencing_token"])
			if token <= 0 {
				return nil, fmt.Errorf("fiducia: acquired lock carried no fencing token")
			}
			renewed, err := c.LockRenew(keys, opts.Holder, token, opts.TTLMs)
			if err != nil {
				return nil, err
			}
			renewedOut := output(renewed)
			if !asBool(renewedOut["renewed"]) {
				return nil, fmt.Errorf("fiducia: retry-discovered lock lost fenced authority during renewal")
			}
			acquired = true
			return &Lock{c: c, Keys: keys, Holder: opts.Holder,
				FencingToken: token, LeaseExpiresMs: asInt(renewedOut["lease_expires_ms"]), TTLMs: opts.TTLMs}, nil
		}
	}
	return nil, nil
}

func (c *Client) cancelLockWait(keys []string, holder, requestID string) error {
	resp, err := c.LockCancel(keys, holder, map[string]any{"request_id": requestID})
	if err != nil {
		return err
	}
	out := output(resp)
	if asBool(out["acquired"]) {
		if token := asInt(out["fencing_token"]); token > 0 {
			key := ""
			if len(keys) > 0 {
				key = keys[0]
			}
			released, err := c.LockRelease(key, ReleaseOpts{Holder: holder, FencingToken: uint64(token)})
			if err != nil {
				return err
			}
			if releasedOut := output(released); releasedOut["released"] == false {
				return fmt.Errorf("fiducia: raced lock could not be released safely")
			}
			return nil
		}
	}
	if asBool(out["cancelled"]) {
		return nil
	}
	return fmt.Errorf("fiducia: lock cancellation did not establish safety (%v)", out["reason"])
}

// --- counting semaphores ---------------------------------------------------

// TrySemaphoreHandle takes a permit now (wait:false). It is separate from the
// thin TrySemaphore method, which returns the raw response envelope.
func (c *Client) TrySemaphoreHandle(key string, limit int64, opts LockOptions) (*SemaphoreHandle, error) {
	resolved, err := opts.withDefaults()
	if err != nil {
		return nil, err
	}
	return c.acquireSemaphore(key, limit, false, resolved)
}

// AcquireSemaphore blocks until a permit is free, the budget elapses, or error.
func (c *Client) AcquireSemaphore(key string, limit int64, opts LockOptions) (*SemaphoreHandle, error) {
	var err error
	opts, err = opts.withDefaults()
	if err != nil {
		return nil, err
	}
	h, err := c.acquireSemaphore(key, limit, true, opts)
	if err != nil {
		return nil, err
	}
	if h == nil {
		return nil, &LockTimeoutError{Keys: []string{key}, Waited: opts.MaxWait}
	}
	return h, nil
}

func (c *Client) acquireSemaphore(key string, limit int64, wait bool, opts LockOptions) (result *SemaphoreHandle, err error) {
	if limit <= 0 || uint64(limit) > uint64(^uint32(0)) {
		return nil, fmt.Errorf("fiducia: semaphore limit must be between 1 and %d", uint64(^uint32(0)))
	}
	requestID, err := generatedRequestID()
	if err != nil {
		return nil, err
	}
	waitTimeoutMs := int64(0)
	if wait {
		waitTimeoutMs = opts.MaxWait.Milliseconds()
	}
	first, err := c.SemaphoreAcquire(key, AcquireOpts{
		Holder: opts.Holder, TTLMs: opts.TTLMs, Wait: wait, Max: uint32(limit),
		WaitTimeoutMs: waitTimeoutMs, RequestID: requestID,
	})
	if err != nil {
		if cancelErr := c.cancelSemaphoreWait(key, opts.Holder, requestID); cancelErr != nil {
			return nil, cancelErr
		}
		return nil, err
	}
	out := output(first)
	if asBool(out["acquired"]) {
		token := asInt(out["fencing_token"])
		if token <= 0 {
			return nil, fmt.Errorf("fiducia: acquired semaphore permit carried no fencing token")
		}
		leaseExpiresMs := asInt(out["lease_expires_ms"])
		if renewed, present := out["renewed"].(bool); present && !renewed {
			response, renewErr := c.SemaphoreRenew(key, opts.Holder, token, opts.TTLMs)
			if renewErr != nil {
				if cancelErr := c.cancelSemaphoreWait(key, opts.Holder, requestID); cancelErr != nil {
					return nil, cancelErr
				}
				return nil, renewErr
			}
			renewedOut := output(response)
			if !asBool(renewedOut["renewed"]) {
				if cancelErr := c.cancelSemaphoreWait(key, opts.Holder, requestID); cancelErr != nil {
					return nil, cancelErr
				}
				return nil, fmt.Errorf("fiducia: reacquired semaphore permit lost fenced authority during renewal")
			}
			leaseExpiresMs = asInt(renewedOut["lease_expires_ms"])
		}
		return &SemaphoreHandle{c: c, Key: key, Holder: opts.Holder,
			FencingToken: token, LeaseExpiresMs: leaseExpiresMs, TTLMs: opts.TTLMs}, nil
	}
	if out["reason"] == "limit_mismatch" {
		return nil, fmt.Errorf("fiducia: semaphore limit mismatch (requested %d, configured %d)",
			limit, asInt(out["limit"]))
	}
	if !wait {
		return nil, nil
	}

	deadline := time.Now().Add(opts.MaxWait)
	acquired := false
	defer func() {
		if !acquired {
			if cancelErr := c.cancelSemaphoreWait(key, opts.Holder, requestID); cancelErr != nil {
				result = nil
				err = cancelErr
			}
		}
	}()
	for attempt := 0; opts.MaxRetries == 0 || attempt < opts.MaxRetries; attempt++ {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		backoff := opts.RetryInterval * time.Duration(1<<minInt(attempt, 3))
		time.Sleep(minDur(minDur(backoff, 2*time.Second), remaining))
		got, err := c.SemaphoreAcquire(key, AcquireOpts{
			Holder: opts.Holder, TTLMs: opts.TTLMs, Wait: true, Max: uint32(limit),
			WaitTimeoutMs: waitTimeoutMs, RequestID: requestID,
		})
		if err != nil {
			return nil, err
		}
		out := output(got)
		if asBool(out["acquired"]) {
			token := asInt(out["fencing_token"])
			if token <= 0 {
				return nil, fmt.Errorf("fiducia: acquired semaphore permit carried no fencing token")
			}
			renewed, err := c.SemaphoreRenew(key, opts.Holder, token, opts.TTLMs)
			if err != nil {
				return nil, err
			}
			renewedOut := output(renewed)
			if !asBool(renewedOut["renewed"]) {
				return nil, fmt.Errorf("fiducia: retry-discovered semaphore permit lost fenced authority during renewal")
			}
			acquired = true
			return &SemaphoreHandle{c: c, Key: key, Holder: opts.Holder,
				FencingToken: token, LeaseExpiresMs: asInt(renewedOut["lease_expires_ms"]), TTLMs: opts.TTLMs}, nil
		}
		if out["reason"] == "limit_mismatch" {
			return nil, fmt.Errorf("fiducia: semaphore limit mismatch (requested %d, configured %d)",
				limit, asInt(out["limit"]))
		}
	}
	return nil, nil
}

func (c *Client) cancelSemaphoreWait(key, holder, requestID string) error {
	resp, err := c.SemaphoreCancel(key, holder, map[string]any{"request_id": requestID})
	if err != nil {
		return err
	}
	out := output(resp)
	if asBool(out["acquired"]) {
		if token := asInt(out["fencing_token"]); token > 0 {
			released, err := c.SemaphoreRelease(key, ReleaseOpts{Holder: holder, FencingToken: uint64(token)})
			if err != nil {
				return err
			}
			if releasedOut := output(released); releasedOut["released"] == false {
				return fmt.Errorf("fiducia: raced semaphore permit could not be released safely")
			}
			return nil
		}
	}
	if asBool(out["cancelled"]) {
		return nil
	}
	return fmt.Errorf("fiducia: semaphore cancellation did not establish safety (%v)", out["reason"])
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

// asInt converts exact JSON integers without routing them through float64.
func asInt(v any) int64 {
	switch n := v.(type) {
	case json.Number:
		value, err := n.Int64()
		if err == nil {
			return value
		}
	case float64:
		if n == float64(int64(n)) {
			return int64(n)
		}
	case int64:
		return n
	case int:
		return int64(n)
	default:
		return 0
	}
	return 0
}

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
