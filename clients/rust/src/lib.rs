//! Fiducia HTTP client (Rust), built on `ureq`. Implements PROTOCOL.md.
//!
//! ```no_run
//! let c = fiducia_client::FiduciaClient::new("https://api.fiducia.cloud");
//! let lock = c.lock_acquire("orders/checkout", Some("worker-a"), Some(30_000), false, None).unwrap();
//! let token = lock["result"]["output"]["fencing_token"].as_u64().unwrap();
//! c.lock_release("orders/checkout", "worker-a", token).unwrap();
//! ```

use serde_json::{json, Value};
use std::{thread, time::Duration};

/// The shared, generated payload/error contract (from `fiducia-interfaces`),
/// re-exported so callers can deserialize responses into typed structs, e.g.
/// `serde_json::from_value::<fiducia_client::types::KvEntry>(resp["entry"].clone())`.
pub use fiducia_interfaces as types;

/// A non-2xx response, or a transport failure.
#[derive(Debug)]
pub enum Error {
    Http { status: u16, body: Option<Value> },
    Transport(String),
}

/// Per-request controls for blocking lock/semaphore acquires.
#[derive(Clone, Copy, Debug, Default)]
pub struct RequestControl {
    pub timeout: Option<Duration>,
    pub lock_request_timeout: Option<Duration>,
    pub max_retries: usize,
    pub retry_delay: Duration,
}

/// HTTP client for a fiducia endpoint (edge / load balancer / node).
pub struct FiduciaClient {
    base: String,
    agent: ureq::Agent,
    pub request_timeout: Option<Duration>,
    pub lock_request_timeout: Option<Duration>,
    pub retry_max: usize,
    pub retry_delay: Duration,
}

impl FiduciaClient {
    pub fn new(base_url: &str) -> Self {
        Self {
            base: base_url.trim_end_matches('/').to_string(),
            agent: ureq::agent(),
            request_timeout: None,
            lock_request_timeout: None,
            retry_max: 0,
            retry_delay: Duration::ZERO,
        }
    }

    fn request(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, Error> {
        self.request_with_control(method, path, body, RequestControl::default(), false)
    }

    fn request_with_control(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        control: RequestControl,
        lock_acquire: bool,
    ) -> Result<Value, Error> {
        let max_retries = if control.max_retries > 0 {
            control.max_retries
        } else {
            self.retry_max
        };
        for attempt in 0..=max_retries {
            match self.request_once(method, path, body.clone(), control, lock_acquire) {
                Ok(value) => return Ok(value),
                Err(err) if attempt < max_retries && Self::retryable(&err) => {
                    let delay = if control.retry_delay > Duration::ZERO {
                        control.retry_delay
                    } else {
                        self.retry_delay
                    };
                    if delay > Duration::ZERO {
                        thread::sleep(delay);
                    }
                }
                Err(err) => return Err(err),
            }
        }
        unreachable!("bounded retry loop always returns");
    }

    fn request_once(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        control: RequestControl,
        lock_acquire: bool,
    ) -> Result<Value, Error> {
        let url = format!("{}{}", self.base, path);
        let mut req = self.agent.request(method, &url);
        if let Some(timeout) = self.resolve_timeout(control, lock_acquire) {
            req = req.timeout(timeout);
        }
        let resp = match body {
            Some(b) => req.send_json(b),
            None => req.call(),
        };
        match resp {
            Ok(r) => Ok(r.into_json::<Value>().unwrap_or(Value::Null)),
            Err(ureq::Error::Status(code, r)) => Err(Error::Http {
                status: code,
                body: r.into_json::<Value>().ok(),
            }),
            Err(e) => Err(Error::Transport(e.to_string())),
        }
    }

    fn resolve_timeout(&self, control: RequestControl, lock_acquire: bool) -> Option<Duration> {
        control
            .lock_request_timeout
            .or(control.timeout)
            .or(if lock_acquire {
                self.lock_request_timeout
            } else {
                None
            })
            .or(self.request_timeout)
    }

    fn retryable(err: &Error) -> bool {
        match err {
            Error::Http { status, .. } => {
                matches!(*status, 408 | 425 | 429 | 500 | 502 | 503 | 504)
            }
            Error::Transport(_) => true,
        }
    }

    fn lock_acquire_with_wait(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        _max: Option<u32>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.request_with_control(
            "POST",
            "/v1/locks/acquire",
            Some(json!({ "key": key, "holder": holder, "ttl_ms": ttl_ms, "wait": wait })),
            control,
            true,
        )
    }

    fn lock_acquire_many_with_wait(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.request_with_control(
            "POST",
            "/v1/locks/acquire",
            Some(json!({ "keys": keys, "holder": holder, "ttl_ms": ttl_ms, "wait": wait })),
            control,
            true,
        )
    }

    fn semaphore_acquire_with_wait(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: u32,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.request_with_control(
            "POST",
            "/v1/semaphores/acquire",
            Some(json!({ "key": key, "holder": holder, "ttl_ms": ttl_ms, "wait": wait, "limit": max.max(2) })),
            control,
            true,
        )
    }

    // --- misc ---
    pub fn health(&self) -> Result<Value, Error> {
        self.request("GET", "/healthz", None)
    }
    pub fn status(&self) -> Result<Value, Error> {
        self.request("GET", "/v1/status", None)
    }

    // --- locks ---
    pub fn lock_get(&self, key: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/locks?key={}", enc(key)), None)
    }
    pub fn lock_acquire(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, wait, max, RequestControl::default())
    }
    pub fn lock_acquire_with_options(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: Option<u32>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, wait, max, control)
    }
    pub fn try_lock(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, false, max, RequestControl::default())
    }
    pub fn try_lock_with_options(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, false, max, control)
    }
    pub fn must_lock(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, true, max, RequestControl::default())
    }
    pub fn must_lock_with_options(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, true, max, control)
    }
    pub fn lock(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.must_lock(key, holder, ttl_ms, max)
    }
    pub fn lock_acquire_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(keys, holder, ttl_ms, wait, RequestControl::default())
    }
    pub fn lock_acquire_many_with_options(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(keys, holder, ttl_ms, wait, control)
    }
    pub fn try_lock_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(keys, holder, ttl_ms, false, RequestControl::default())
    }
    pub fn must_lock_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(keys, holder, ttl_ms, true, RequestControl::default())
    }
    pub fn lock_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.must_lock_many(keys, holder, ttl_ms)
    }
    pub fn lock_release(
        &self,
        _key: &str,
        holder: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/locks/release",
            Some(json!({ "holder": holder, "fencing_token": fencing_token })),
        )
    }
    pub fn lock_release_many(&self, lock_id: &str) -> Result<Value, Error> {
        Err(Error::Transport(format!(
            "fiducia: lock_release_many({lock_id}) is legacy; release union locks with lock_release and the fencing token"
        )))
    }

    // --- semaphores ---
    pub fn semaphore_acquire(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: u32,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(key, holder, ttl_ms, wait, max, RequestControl::default())
    }
    pub fn semaphore_acquire_with_options(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: u32,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(key, holder, ttl_ms, wait, max, control)
    }
    pub fn try_semaphore(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: u32,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(key, holder, ttl_ms, false, max, RequestControl::default())
    }
    pub fn must_semaphore(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: u32,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(key, holder, ttl_ms, true, max, RequestControl::default())
    }
    pub fn semaphore(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: u32,
    ) -> Result<Value, Error> {
        self.must_semaphore(key, holder, ttl_ms, max)
    }
    pub fn semaphore_release(
        &self,
        key: &str,
        holder: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/semaphores/release",
            Some(json!({ "key": key, "holder": holder, "fencing_token": fencing_token })),
        )
    }

    // --- reader-writer locks ---
    pub fn rw_acquire_read(
        &self,
        key: &str,
        ttl_ms: Option<u64>,
        wait: bool,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/rw/{}/read", enc(key)),
            Some(json!({ "ttl_ms": ttl_ms, "wait": wait })),
        )
    }
    pub fn rw_end_read(&self, key: &str, lock_id: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/rw/{}/read/end", enc(key)),
            Some(json!({ "lock_id": lock_id })),
        )
    }
    pub fn rw_acquire_write(
        &self,
        key: &str,
        ttl_ms: Option<u64>,
        wait: bool,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/rw/{}/write", enc(key)),
            Some(json!({ "ttl_ms": ttl_ms, "wait": wait })),
        )
    }
    pub fn rw_end_write(&self, key: &str, lock_id: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/rw/{}/write/end", enc(key)),
            Some(json!({ "lock_id": lock_id })),
        )
    }

    // --- config KV ---
    pub fn kv_get(&self, key: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/kv?key={}", enc(key)), None)
    }
    pub fn kv_put(&self, key: &str, value: &str, ttl_ms: Option<u64>) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!("/v1/kv?key={}", enc(key)),
            Some(json!({ "value": value, "ttl_ms": ttl_ms })),
        )
    }
    pub fn kv_put_cas(
        &self,
        key: &str,
        value: &str,
        ttl_ms: Option<u64>,
        prev_revision: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!("/v1/kv?key={}", enc(key)),
            Some(json!({ "value": value, "ttl_ms": ttl_ms, "prev_revision": prev_revision })),
        )
    }
    pub fn kv_delete(&self, key: &str) -> Result<Value, Error> {
        self.request("DELETE", &format!("/v1/kv?key={}", enc(key)), None)
    }
    pub fn kv_list(&self, prefix: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/kv?prefix={}", enc(prefix)), None)
    }

    // --- rate limiting ---
    pub fn rate_limit_check(
        &self,
        tenant: &str,
        key: &str,
        algorithm: &str,
        limit: u32,
        window_ms: u64,
        refill_per_second: Option<f64>,
        cost: Option<u32>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/rate-limit/{}/{}/check", enc(tenant), enc(key)),
            Some(json!({
                "algorithm": algorithm,
                "limit": limit,
                "window_ms": window_ms,
                "refill_per_second": refill_per_second,
                "cost": cost,
            })),
        )
    }
    pub fn rate_limit_get(&self, tenant: &str, key: &str) -> Result<Value, Error> {
        self.request(
            "GET",
            &format!("/v1/rate-limit/{}/{}", enc(tenant), enc(key)),
            None,
        )
    }

    // --- cron / scheduling ---
    pub fn schedule_upsert(
        &self,
        name: &str,
        cron: Option<&str>,
        one_shot_at_ms: Option<u64>,
        target: Value,
        delivery: Option<&str>,
        max_retries: Option<u32>,
    ) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!("/v1/cron/schedules/{}", enc(name)),
            Some(json!({
                "cron": cron,
                "one_shot_at_ms": one_shot_at_ms,
                "target": target,
                "delivery": delivery,
                "max_retries": max_retries,
            })),
        )
    }
    pub fn schedule_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/cron/schedules/{}", enc(name)), None)
    }
    pub fn schedule_record_run(
        &self,
        name: &str,
        fire_id: &str,
        fired_at_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/cron/schedules/{}/runs", enc(name)),
            Some(json!({ "fire_id": fire_id, "fired_at_ms": fired_at_ms })),
        )
    }
    pub fn schedule_history(&self, name: &str) -> Result<Value, Error> {
        self.request(
            "GET",
            &format!("/v1/cron/schedules/{}/history", enc(name)),
            None,
        )
    }

    // --- leader election ---
    pub fn election_campaign(
        &self,
        name: &str,
        candidate: &str,
        ttl_ms: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/elections/{}/campaign", enc(name)),
            Some(json!({ "candidate": candidate, "ttl_ms": ttl_ms })),
        )
    }
    pub fn election_renew(
        &self,
        name: &str,
        candidate: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/elections/{}/renew", enc(name)),
            Some(json!({ "candidate": candidate, "fencing_token": fencing_token })),
        )
    }
    pub fn election_resign(
        &self,
        name: &str,
        candidate: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/elections/{}/resign", enc(name)),
            Some(json!({ "candidate": candidate, "fencing_token": fencing_token })),
        )
    }
    pub fn election_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/elections/{}", enc(name)), None)
    }

    // --- service discovery ---
    pub fn service_register(
        &self,
        service: &str,
        instance_id: &str,
        address: &str,
        ttl_ms: u64,
    ) -> Result<Value, Error> {
        self.service_register_with_metadata(service, instance_id, address, ttl_ms, json!({}))
    }
    pub fn service_register_with_metadata(
        &self,
        service: &str,
        instance_id: &str,
        address: &str,
        ttl_ms: u64,
        metadata: Value,
    ) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!(
                "/v1/services/{}/instances/{}",
                enc(service),
                enc(instance_id)
            ),
            Some(json!({ "address": address, "ttl_ms": ttl_ms, "metadata": metadata })),
        )
    }
    pub fn service_heartbeat(&self, service: &str, instance_id: &str) -> Result<Value, Error> {
        self.service_heartbeat_with_ttl(service, instance_id, None)
    }
    pub fn service_heartbeat_with_ttl(
        &self,
        service: &str,
        instance_id: &str,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!(
                "/v1/services/{}/instances/{}/heartbeat",
                enc(service),
                enc(instance_id)
            ),
            Some(json!({ "ttl_ms": ttl_ms })),
        )
    }
    pub fn service_deregister(&self, service: &str, instance_id: &str) -> Result<Value, Error> {
        self.request(
            "DELETE",
            &format!(
                "/v1/services/{}/instances/{}",
                enc(service),
                enc(instance_id)
            ),
            None,
        )
    }
    pub fn service_instances(&self, service: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/services/{}", enc(service)), None)
    }
    pub fn service_list(&self) -> Result<Value, Error> {
        self.request("GET", "/v1/services", None)
    }
}

/// Percent-encode a single path segment (unreserved chars pass through).
fn enc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc::{self, Receiver};

    #[derive(Debug)]
    struct RecordedRequest {
        method: String,
        path: String,
        body: Value,
    }

    fn recording_server() -> (String, Receiver<RecordedRequest>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();

        thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let mut buf = Vec::new();
                let mut tmp = [0_u8; 1024];
                let mut header_end = None;
                let mut content_len = 0_usize;

                loop {
                    let n = stream.read(&mut tmp).unwrap();
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                    if header_end.is_none() {
                        if let Some(pos) = find_header_end(&buf) {
                            header_end = Some(pos);
                            let headers = String::from_utf8_lossy(&buf[..pos]);
                            content_len = content_length(&headers);
                        }
                    }
                    if let Some(pos) = header_end {
                        if buf.len() >= pos + 4 + content_len {
                            break;
                        }
                    }
                }

                let header_end = header_end.unwrap();
                let headers = String::from_utf8_lossy(&buf[..header_end]);
                let mut first_line = headers.lines().next().unwrap().split_whitespace();
                let method = first_line.next().unwrap().to_string();
                let path = first_line.next().unwrap().to_string();
                let body_start = header_end + 4;
                let body = if content_len == 0 {
                    Value::Null
                } else {
                    serde_json::from_slice(&buf[body_start..body_start + content_len]).unwrap()
                };

                tx.send(RecordedRequest { method, path, body }).unwrap();
                stream
                    .write_all(
                        b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
                    )
                    .unwrap();
            }
        });

        (base, rx)
    }

    fn find_header_end(buf: &[u8]) -> Option<usize> {
        buf.windows(4).position(|window| window == b"\r\n\r\n")
    }

    fn content_length(headers: &str) -> usize {
        headers
            .lines()
            .find_map(|line| {
                line.strip_prefix("content-length:")
                    .or_else(|| line.strip_prefix("Content-Length:"))
                    .and_then(|raw| raw.trim().parse().ok())
            })
            .unwrap_or(0)
    }

    fn assert_next(rx: &Receiver<RecordedRequest>, method: &str, path: &str, body: Value) {
        let got = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(got.method, method);
        assert_eq!(got.path, path);
        assert_eq!(got.body, body);
    }

    #[test]
    fn shared_contract_types_parse_node_responses() {
        // A node lock grant deserializes into the shared `LockGrant` type, and a
        // NotLeader error into the shared `ProposeError` — so the client speaks the
        // same contract the node emits (no per-client payload definitions).
        let err: types::ProposeError = serde_json::from_value(
            json!({ "reason": "not_leader", "shard": 7, "leader": "http://leader-a:8090" }),
        )
        .unwrap();
        assert!(matches!(err.reason, types::ProposeErrorReason::NotLeader));
        assert_eq!(err.leader.as_deref(), Some("http://leader-a:8090"));

        let kv: types::KvEntry =
            serde_json::from_value(json!({ "value": "on", "mod_revision": 9 })).unwrap();
        assert_eq!(kv.value, "on");
    }

    #[test]
    fn coordination_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client.lock_get("orders/42").unwrap();
        assert_next(&rx, "GET", "/v1/locks?key=orders%2F42", Value::Null);

        client
            .try_lock("orders/42", Some("worker-a"), None, None)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/acquire",
            json!({ "key": "orders/42", "holder": "worker-a", "ttl_ms": null, "wait": false }),
        );

        client
            .must_lock_many(
                &["orders/42", "inventory/sku-7"],
                Some("worker-a"),
                Some(30_000),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/acquire",
            json!({ "keys": ["orders/42", "inventory/sku-7"], "holder": "worker-a", "ttl_ms": 30_000, "wait": true }),
        );

        client.lock_release("orders/42", "worker-a", 11).unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/release",
            json!({ "holder": "worker-a", "fencing_token": 11 }),
        );

        assert!(client.lock_release_many("legacy-lock-id").is_err());

        client
            .try_semaphore("pools/db/primary", None, None, 0)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/acquire",
            json!({ "key": "pools/db/primary", "holder": null, "ttl_ms": null, "wait": false, "limit": 2 }),
        );

        client
            .semaphore_release("pools/db/primary", "worker-b", 12)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/release",
            json!({ "key": "pools/db/primary", "holder": "worker-b", "fencing_token": 12 }),
        );
    }

    #[test]
    fn service_discovery_sends_metadata_and_heartbeat_body() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .service_register_with_metadata(
                "api",
                "i-1",
                "10.0.0.1:9000",
                10_000,
                json!({ "region": "eu-central-1" }),
            )
            .unwrap();
        assert_next(
            &rx,
            "PUT",
            "/v1/services/api/instances/i-1",
            json!({ "address": "10.0.0.1:9000", "ttl_ms": 10_000, "metadata": { "region": "eu-central-1" } }),
        );

        client.service_heartbeat("api", "i-1").unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/services/api/instances/i-1/heartbeat",
            json!({ "ttl_ms": null }),
        );
    }
}
