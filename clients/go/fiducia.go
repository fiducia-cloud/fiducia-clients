// Package fiducia is a zero-dependency HTTP client for fiducia.cloud (stdlib
// net/http). It implements PROTOCOL.md.
//
//	c := fiducia.New("https://api.fiducia.cloud")
//	lock, _ := c.LockAcquire("orders/checkout", fiducia.AcquireOpts{Holder: "worker-a", TTLMs: 30000})
//	token := uint64(lock["result"].(map[string]any)["fencing_token"].(float64))
//	c.LockRelease("orders/checkout", fiducia.ReleaseOpts{Holder: "worker-a", FencingToken: token})
package fiducia

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// AcquireOpts configures a lock acquire.
type AcquireOpts struct {
	Holder string
	TTLMs  int64
	Wait   bool
}

// ReleaseOpts identifies the current holder and fencing token.
type ReleaseOpts struct {
	Holder       string
	FencingToken uint64
}

// RwOpts configures a reader-writer acquire.
type RwOpts struct {
	TTLMs int64
	Wait  bool
}

// RateLimitCheckOpts configures an atomic rate-limit check.
type RateLimitCheckOpts struct {
	Algorithm       string
	Limit           uint32
	WindowMs        uint64
	RefillPerSecond *float64
	Cost            uint32
}

// ScheduleTarget is a webhook, queue, or gRPC target.
type ScheduleTarget map[string]any

// ScheduleUpsertOpts configures a cron or one-shot schedule.
type ScheduleUpsertOpts struct {
	Cron        string
	OneShotAtMs *uint64
	Target      ScheduleTarget
	Delivery    string
	MaxRetries  uint32
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

// --- locks ---
func (c *Client) LockGet(key string) (map[string]any, error) {
	return c.request("GET", "/v1/locks/"+enc(key), nil)
}
func (c *Client) LockAcquire(key string, o AcquireOpts) (map[string]any, error) {
	return c.request("POST", "/v1/locks/"+enc(key)+"/acquire",
		map[string]any{"holder": o.Holder, "ttl_ms": o.TTLMs, "wait": o.Wait})
}
func (c *Client) LockRelease(key string, o ReleaseOpts) (map[string]any, error) {
	return c.request("POST", "/v1/locks/"+enc(key)+"/release",
		map[string]any{"holder": o.Holder, "fencing_token": o.FencingToken})
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

// --- rate limiting ---
func (c *Client) RateLimitCheck(tenant, key string, o RateLimitCheckOpts) (map[string]any, error) {
	body := map[string]any{
		"algorithm": o.Algorithm,
		"limit":     o.Limit,
		"window_ms": o.WindowMs,
	}
	if o.RefillPerSecond != nil {
		body["refill_per_second"] = *o.RefillPerSecond
	}
	if o.Cost > 0 {
		body["cost"] = o.Cost
	}
	return c.request("POST", "/v1/rate-limit/"+enc(tenant)+"/"+enc(key)+"/check", body)
}
func (c *Client) RateLimitGet(tenant, key string) (map[string]any, error) {
	return c.request("GET", "/v1/rate-limit/"+enc(tenant)+"/"+enc(key), nil)
}

// --- cron / scheduling ---
func (c *Client) ScheduleUpsert(name string, o ScheduleUpsertOpts) (map[string]any, error) {
	body := map[string]any{
		"target": o.Target,
	}
	if o.Cron != "" {
		body["cron"] = o.Cron
	}
	if o.OneShotAtMs != nil {
		body["one_shot_at_ms"] = *o.OneShotAtMs
	}
	if o.Delivery != "" {
		body["delivery"] = o.Delivery
	}
	if o.MaxRetries > 0 {
		body["max_retries"] = o.MaxRetries
	}
	return c.request("PUT", "/v1/cron/schedules/"+enc(name), body)
}
func (c *Client) ScheduleGet(name string) (map[string]any, error) {
	return c.request("GET", "/v1/cron/schedules/"+enc(name), nil)
}
func (c *Client) ScheduleRecordRun(name, fireID string, firedAtMs *uint64) (map[string]any, error) {
	body := map[string]any{"fire_id": fireID}
	if firedAtMs != nil {
		body["fired_at_ms"] = *firedAtMs
	}
	return c.request("POST", "/v1/cron/schedules/"+enc(name)+"/runs", body)
}
func (c *Client) ScheduleHistory(name string) (map[string]any, error) {
	return c.request("GET", "/v1/cron/schedules/"+enc(name)+"/history", nil)
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
