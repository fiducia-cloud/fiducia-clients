// Package fiducia is a zero-dependency HTTP client for fiducia.cloud (stdlib
// net/http). It implements PROTOCOL.md.
//
//	c := fiducia.New("https://api.fiducia.cloud")
//	lock, _ := c.LockAcquire("orders/checkout", fiducia.AcquireOpts{TTLMs: 30000})
//	c.LockRelease("orders/checkout", lock["lock_id"].(string))
package fiducia

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	// Shared, generated payload contract (aliased because the generated package
	// is also named `fiducia`). Re-exported as typed aliases below.
	types "github.com/fiducia-cloud/fiducia-interfaces/generated/go"
)

// Shared payload/error types, re-exported from fiducia-interfaces so callers can
// decode responses into typed structs from one source of truth.
type (
	ProposeOutcome = types.ProposeOutcome
	ProposeError   = types.ProposeError
	KvEntry        = types.KvEntry
	LockGrant      = types.LockGrant
	Leadership     = types.Leadership
	ServiceInstance = types.ServiceInstance
)

// AcquireOpts configures a lock/semaphore acquire.
type AcquireOpts struct {
	TTLMs int64
	Wait  bool
	Max   int
}

// RwOpts configures a reader-writer acquire.
type RwOpts struct {
	TTLMs int64
	Wait  bool
}

// Error is a non-2xx response.
type Error struct {
	Status int
	Body   map[string]any
}

func (e *Error) Error() string { return fmt.Sprintf("fiducia: HTTP %d", e.Status) }

// Client talks to a fiducia endpoint over HTTP.
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

// New returns a client for the given base URL.
func New(baseURL string) *Client {
	return &Client{BaseURL: strings.TrimRight(baseURL, "/"), HTTP: http.DefaultClient}
}

func (c *Client) request(method, path string, body any) (map[string]any, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.BaseURL+path, rdr)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var data map[string]any
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &data)
	}
	if res.StatusCode >= 300 {
		return nil, &Error{Status: res.StatusCode, Body: data}
	}
	return data, nil
}

func enc(s string) string { return url.PathEscape(s) }

// --- misc ---
func (c *Client) Health() (map[string]any, error) { return c.request("GET", "/healthz", nil) }
func (c *Client) Status() (map[string]any, error) { return c.request("GET", "/v1/status", nil) }

// --- locks & semaphores ---
func (c *Client) LockAcquire(key string, o AcquireOpts) (map[string]any, error) {
	max := o.Max
	if max == 0 {
		max = 1
	}
	return c.request("POST", "/v1/locks/"+enc(key)+"/acquire",
		map[string]any{"ttl_ms": o.TTLMs, "wait": o.Wait, "max": max})
}
func (c *Client) LockRelease(key, lockID string) (map[string]any, error) {
	return c.request("POST", "/v1/locks/"+enc(key)+"/release", map[string]any{"lock_id": lockID})
}

// --- reader-writer locks ---
func (c *Client) RwAcquireRead(key string, o RwOpts) (map[string]any, error) {
	return c.request("POST", "/v1/rw/"+enc(key)+"/read", map[string]any{"ttl_ms": o.TTLMs, "wait": o.Wait})
}
func (c *Client) RwEndRead(key, lockID string) (map[string]any, error) {
	return c.request("POST", "/v1/rw/"+enc(key)+"/read/end", map[string]any{"lock_id": lockID})
}
func (c *Client) RwAcquireWrite(key string, o RwOpts) (map[string]any, error) {
	return c.request("POST", "/v1/rw/"+enc(key)+"/write", map[string]any{"ttl_ms": o.TTLMs, "wait": o.Wait})
}
func (c *Client) RwEndWrite(key, lockID string) (map[string]any, error) {
	return c.request("POST", "/v1/rw/"+enc(key)+"/write/end", map[string]any{"lock_id": lockID})
}

// --- config KV ---
func (c *Client) KvGet(key string) (map[string]any, error) {
	return c.request("GET", "/v1/kv/"+enc(key), nil)
}
func (c *Client) KvPut(key, value string, ttlMs int64) (map[string]any, error) {
	return c.request("PUT", "/v1/kv/"+enc(key), map[string]any{"value": value, "ttl_ms": ttlMs})
}
func (c *Client) KvDelete(key string) (map[string]any, error) {
	return c.request("DELETE", "/v1/kv/"+enc(key), nil)
}
func (c *Client) KvList(prefix string) (map[string]any, error) {
	return c.request("GET", "/v1/kv?prefix="+url.QueryEscape(prefix), nil)
}

// --- leader election ---
func (c *Client) ElectionCampaign(name, candidate string, ttlMs int64) (map[string]any, error) {
	return c.request("POST", "/v1/elections/"+enc(name)+"/campaign",
		map[string]any{"candidate": candidate, "ttl_ms": ttlMs})
}
func (c *Client) ElectionRenew(name, candidate string, fencingToken uint64) (map[string]any, error) {
	return c.request("POST", "/v1/elections/"+enc(name)+"/renew",
		map[string]any{"candidate": candidate, "fencing_token": fencingToken})
}
func (c *Client) ElectionResign(name, candidate string, fencingToken uint64) (map[string]any, error) {
	return c.request("POST", "/v1/elections/"+enc(name)+"/resign",
		map[string]any{"candidate": candidate, "fencing_token": fencingToken})
}
func (c *Client) ElectionGet(name string) (map[string]any, error) {
	return c.request("GET", "/v1/elections/"+enc(name), nil)
}

// --- service discovery ---
func (c *Client) ServiceRegister(service, instanceID, address string, ttlMs int64) (map[string]any, error) {
	return c.request("PUT", "/v1/services/"+enc(service)+"/instances/"+enc(instanceID),
		map[string]any{"address": address, "ttl_ms": ttlMs})
}
func (c *Client) ServiceHeartbeat(service, instanceID string) (map[string]any, error) {
	return c.request("POST", "/v1/services/"+enc(service)+"/instances/"+enc(instanceID)+"/heartbeat", nil)
}
func (c *Client) ServiceDeregister(service, instanceID string) (map[string]any, error) {
	return c.request("DELETE", "/v1/services/"+enc(service)+"/instances/"+enc(instanceID), nil)
}
func (c *Client) ServiceInstances(service string) (map[string]any, error) {
	return c.request("GET", "/v1/services/"+enc(service), nil)
}
func (c *Client) ServiceList() (map[string]any, error) {
	return c.request("GET", "/v1/services", nil)
}
