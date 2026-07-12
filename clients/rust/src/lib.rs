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

/// High-level blocking/try lock + semaphore acquisition (live-mutex-style).
mod locking;
pub use locking::{LockError, LockHandle, LockOptions, SemaphoreHandle};

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
#[derive(Clone, Debug, Default)]
pub struct RequestControl {
    pub timeout: Option<Duration>,
    pub lock_request_timeout: Option<Duration>,
    pub max_retries: usize,
    pub retry_delay: Duration,
    pub idempotency_key: Option<String>,
}

/// Parameters for a rate-limit check.
#[derive(Clone, Copy, Debug)]
pub struct RateLimitCheckRequest<'a> {
    pub tenant: &'a str,
    pub key: &'a str,
    pub algorithm: &'a str,
    pub limit: u32,
    pub window_ms: u64,
    pub refill_per_second: Option<f64>,
    pub cost: Option<u32>,
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
            match self.request_once(method, path, body.clone(), control.clone(), lock_acquire) {
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
        if let Some(timeout) = self.resolve_timeout(&control, lock_acquire) {
            req = req.timeout(timeout);
        }
        if let Some(key) = control.idempotency_key.as_deref() {
            req = req.set("Idempotency-Key", key);
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

    fn resolve_timeout(&self, control: &RequestControl, lock_acquire: bool) -> Option<Duration> {
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

    // --- idempotency keys ---
    pub fn idempotency_get(&self, key: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/idempotency?key={}", enc(key)), None)
    }
    pub fn idempotency_claim(
        &self,
        key: &str,
        owner: Option<&str>,
        ttl_ms: Option<u64>,
        ttl: Option<&str>,
        metadata: Value,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/idempotency/claim",
            Some(json!({ "key": key, "owner": owner, "ttl_ms": ttl_ms, "ttl": ttl, "metadata": metadata })),
        )
    }
    pub fn idempotency_complete(
        &self,
        key: &str,
        owner: &str,
        fencing_token: u64,
        result: Option<Value>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/idempotency/complete",
            Some(json!({ "key": key, "owner": owner, "fencing_token": fencing_token, "result": result })),
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

    // --- counters ---
    /// Read a counter's current value and revision. An absent counter reports
    /// `found: false`; callers treat that as value 0.
    pub fn counter_get(&self, key: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/counters?key={}", enc(key)), None)
    }
    /// Atomically add `delta` (which may be negative), creating the counter at 0.
    /// When `prev_revision` is set, the add is a compare-and-set.
    pub fn counter_add(
        &self,
        key: &str,
        delta: i64,
        prev_revision: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/counters/add",
            Some(json!({ "key": key, "delta": delta, "prev_revision": prev_revision })),
        )
    }
    /// Set a counter to an absolute `value` (e.g. reset to 0). When
    /// `prev_revision` is set, the write is a compare-and-set.
    pub fn counter_set(
        &self,
        key: &str,
        value: i64,
        prev_revision: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/counters/set",
            Some(json!({ "key": key, "value": value, "prev_revision": prev_revision })),
        )
    }

    // --- barriers ---
    /// Read a barrier's arrivals and resolution status. Absent reports
    /// `found: false`.
    pub fn barrier_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/barriers?name={}", enc(name)), None)
    }
    /// Create (or reconfigure, if still pending) a barrier. `policy` is a JSON
    /// object like `{"kind":"quorum","required":3}`; `expected` is the
    /// participant count for `all`/`any_veto` (defaults to 1).
    pub fn barrier_create(
        &self,
        name: &str,
        policy: Value,
        expected: Option<u32>,
        deadline_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/barriers/create",
            Some(json!({
                "name": name,
                "policy": policy,
                "expected": expected.unwrap_or(1),
                "deadline_ms": deadline_ms,
            })),
        )
    }
    /// Record a participant's arrival (or veto). Repeat arrivals by the same
    /// participant are idempotent.
    pub fn barrier_arrive(
        &self,
        name: &str,
        participant: &str,
        weight: Option<u64>,
        veto: bool,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/barriers/arrive",
            Some(json!({
                "name": name,
                "participant": participant,
                "weight": weight.unwrap_or(1),
                "veto": veto,
            })),
        )
    }

    // --- durable tasks ---
    /// Read a task's status, owner, and fencing token. Absent reports
    /// `found: false`.
    pub fn task_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/tasks?name={}", enc(name)), None)
    }
    /// Create a durable task if it does not exist (idempotent).
    pub fn task_create(
        &self,
        name: &str,
        task_type: &str,
        payload: Value,
        deadline_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/tasks/create",
            Some(json!({ "name": name, "task_type": task_type, "payload": payload, "deadline_ms": deadline_ms })),
        )
    }
    /// Claim a pending or lease-expired task; the grant carries a fencing token.
    pub fn task_claim(
        &self,
        name: &str,
        worker: &str,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/tasks/claim",
            Some(json!({ "name": name, "worker": worker, "ttl_ms": ttl_ms })),
        )
    }
    /// Report progress and a checkpoint under the current fencing token.
    pub fn task_progress(
        &self,
        name: &str,
        worker: &str,
        fencing_token: u64,
        percent: u32,
        checkpoint: Value,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/tasks/progress",
            Some(json!({ "name": name, "worker": worker, "fencing_token": fencing_token, "percent": percent, "checkpoint": checkpoint })),
        )
    }
    /// Complete a task with a durable result under the current fencing token.
    pub fn task_complete(
        &self,
        name: &str,
        worker: &str,
        fencing_token: u64,
        result: Value,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/tasks/complete",
            Some(json!({ "name": name, "worker": worker, "fencing_token": fencing_token, "result": result })),
        )
    }
    /// Fail a task; `retryable` requeues it for another worker.
    pub fn task_fail(
        &self,
        name: &str,
        worker: &str,
        fencing_token: u64,
        retryable: bool,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/tasks/fail",
            Some(json!({ "name": name, "worker": worker, "fencing_token": fencing_token, "retryable": retryable })),
        )
    }
    /// Cancel a task (terminal), regardless of owner.
    pub fn task_cancel(&self, name: &str) -> Result<Value, Error> {
        self.request("POST", "/v1/tasks/cancel", Some(json!({ "name": name })))
    }

    // --- approval-escrow effects ---
    /// Read an effect's status, approvals, and result. Absent reports
    /// `found: false`.
    pub fn effect_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/effects?name={}", enc(name)), None)
    }
    /// Prepare a side effect for later authorization (idempotent).
    /// `required_approvals` of 0 is pre-approved and may be committed immediately.
    pub fn effect_prepare(
        &self,
        name: &str,
        effect_type: &str,
        payload: Value,
        risk: &str,
        idempotency_key: &str,
        required_approvals: u32,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/effects/prepare",
            Some(json!({
                "name": name,
                "effect_type": effect_type,
                "payload": payload,
                "risk": risk,
                "idempotency_key": idempotency_key,
                "required_approvals": required_approvals,
            })),
        )
    }
    /// Record one principal's approval.
    pub fn effect_approve(&self, name: &str, principal: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/effects/approve",
            Some(json!({ "name": name, "principal": principal })),
        )
    }
    /// Commit an approved effect exactly once, recording `result`.
    pub fn effect_commit(&self, name: &str, result: Value) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/effects/commit",
            Some(json!({ "name": name, "result": result })),
        )
    }
    /// Abort a prepared/approved effect (terminal).
    pub fn effect_abort(&self, name: &str) -> Result<Value, Error> {
        self.request("POST", "/v1/effects/abort", Some(json!({ "name": name })))
    }

    // --- atomic ownership handoffs ---
    /// Read a handoff's status, counterparties, and tokens. Absent reports
    /// `found: false`.
    pub fn handoff_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/handoffs?name={}", enc(name)), None)
    }
    /// Offer to transfer ownership of `resource` from `from` (presenting its
    /// current `from_token`) to `to`, with a context manifest and accept deadline.
    pub fn handoff_offer(
        &self,
        name: &str,
        resource: &str,
        from: &str,
        to: &str,
        from_token: u64,
        context: Value,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/handoffs/offer",
            Some(json!({
                "name": name,
                "resource": resource,
                "from": from,
                "to": to,
                "from_token": from_token,
                "context": context,
                "ttl_ms": ttl_ms,
            })),
        )
    }
    /// Accept an offered handoff; the grant carries a strictly higher fencing
    /// token for the new owner.
    pub fn handoff_accept(&self, name: &str, to: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/handoffs/accept",
            Some(json!({ "name": name, "to": to })),
        )
    }
    /// Reject an offered handoff; ownership stays with the original owner.
    pub fn handoff_reject(&self, name: &str, to: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/handoffs/reject",
            Some(json!({ "name": name, "to": to })),
        )
    }

    // --- decisions (typed weighted voting) ---
    /// Read a decision's options, tallies, votes, and resolution. Absent reports
    /// `found: false`.
    pub fn decision_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/decisions?name={}", enc(name)), None)
    }
    /// Propose a decision with typed options and a resolution policy (a JSON
    /// object like `{"kind":"plurality","min_votes":3}`). Idempotent.
    pub fn decision_propose(
        &self,
        name: &str,
        question: &str,
        options: &[&str],
        policy: Value,
        deadline_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/decisions/propose",
            Some(json!({
                "name": name,
                "question": question,
                "options": options,
                "policy": policy,
                "deadline_ms": deadline_ms,
            })),
        )
    }
    /// Cast (or replace) a vote. `option` of `None` abstains; `veto` aborts the
    /// decision; `weight` drives resolution.
    pub fn decision_vote(&self, name: &str, vote: DecisionVote<'_>) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/decisions/vote",
            Some(json!({
                "name": name,
                "voter": vote.voter,
                "option": vote.option,
                "confidence": vote.confidence,
                "weight": vote.weight,
                "veto": vote.veto,
                "evidence": vote.evidence,
            })),
        )
    }

    // --- rate limiting ---
    pub fn rate_limit_check(&self, request: RateLimitCheckRequest<'_>) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!(
                "/v1/rate-limit/{}/{}/check",
                enc(request.tenant),
                enc(request.key)
            ),
            Some(json!({
                "algorithm": request.algorithm,
                "limit": request.limit,
                "window_ms": request.window_ms,
                "refill_per_second": request.refill_per_second,
                "cost": request.cost,
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
    /// Campaign to lead `name`. `metadata` publishes candidate facts (address,
    /// region, version, …) with the leadership so observers can discover the
    /// leader's endpoint, not just its id.
    pub fn election_campaign(
        &self,
        name: &str,
        candidate: &str,
        ttl_ms: u64,
        metadata: Option<Value>,
    ) -> Result<Value, Error> {
        let mut body = json!({ "candidate": candidate, "ttl_ms": ttl_ms });
        if let Some(metadata) = metadata {
            body["metadata"] = metadata;
        }
        self.request(
            "POST",
            &format!("/v1/elections/{}/campaign", enc(name)),
            Some(body),
        )
    }
    pub fn election_campaign_with_metadata(
        &self,
        name: &str,
        candidate: &str,
        ttl_ms: u64,
        metadata: Value,
    ) -> Result<Value, Error> {
        self.election_campaign(name, candidate, ttl_ms, Some(metadata))
    }
    /// Renew the lease. `ttl_ms` overrides the lease length; when `None`, the
    /// original campaign TTL is reused.
    pub fn election_renew(
        &self,
        name: &str,
        candidate: &str,
        fencing_token: u64,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        let mut body = json!({ "candidate": candidate, "fencing_token": fencing_token });
        if let Some(ttl_ms) = ttl_ms {
            body["ttl_ms"] = json!(ttl_ms);
        }
        self.request(
            "POST",
            &format!("/v1/elections/{}/renew", enc(name)),
            Some(body),
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
    /// Register/refresh an instance. `metadata` carries free-form facts (zone,
    /// capacity, version, …) returned to clients resolving the service.
    pub fn service_register(
        &self,
        service: &str,
        instance_id: &str,
        address: &str,
        ttl_ms: u64,
        metadata: Option<Value>,
    ) -> Result<Value, Error> {
        self.service_register_with_metadata(
            service,
            instance_id,
            address,
            ttl_ms,
            metadata.unwrap_or_else(|| json!({})),
        )
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
        self.service_instances_with_metadata(service, &[])
    }
    pub fn service_instances_with_metadata(
        &self,
        service: &str,
        metadata: &[(&str, &str)],
    ) -> Result<Value, Error> {
        self.request(
            "GET",
            &format!(
                "/v1/services/{}{}",
                enc(service),
                service_metadata_query(metadata)
            ),
            None,
        )
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

fn service_metadata_query(metadata: &[(&str, &str)]) -> String {
    let mut pairs = metadata
        .iter()
        .filter(|(key, _)| !key.trim().is_empty())
        .collect::<Vec<_>>();
    pairs.sort_by_key(|(key, _)| *key);
    if pairs.is_empty() {
        return String::new();
    }
    let query = pairs
        .into_iter()
        .map(|(key, value)| format!("metadata.{}={}", enc(key), enc(value)))
        .collect::<Vec<_>>()
        .join("&");
    format!("?{query}")
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
        idempotency_key: Option<String>,
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
                let idempotency_key = header_value(&headers, "idempotency-key");
                let body_start = header_end + 4;
                let body = if content_len == 0 {
                    Value::Null
                } else {
                    serde_json::from_slice(&buf[body_start..body_start + content_len]).unwrap()
                };

                tx.send(RecordedRequest {
                    method,
                    path,
                    body,
                    idempotency_key,
                })
                .unwrap();
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

    fn header_value(headers: &str, name: &str) -> Option<String> {
        headers.lines().find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case(name)
                .then(|| value.trim().to_string())
        })
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

        let idempotency: types::IdempotencyRecord = serde_json::from_value(json!({
            "key": "stripe-webhook/event_123",
            "owner": "worker-a",
            "fencing_token": 11,
            "status": "claimed",
            "first_seen_ms": 100,
            "lease_expires_ms": 200,
            "metadata": { "source": "stripe" }
        }))
        .unwrap();
        assert!(matches!(
            idempotency.status,
            types::IdempotencyRecordStatus::Claimed
        ));
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

        client.idempotency_get("stripe-webhook/event_123").unwrap();
        assert_next(
            &rx,
            "GET",
            "/v1/idempotency?key=stripe-webhook%2Fevent_123",
            Value::Null,
        );

        client
            .idempotency_claim(
                "stripe-webhook/event_123",
                Some("worker-a"),
                None,
                Some("24h"),
                json!({ "source": "stripe" }),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/idempotency/claim",
            json!({
                "key": "stripe-webhook/event_123",
                "owner": "worker-a",
                "ttl_ms": null,
                "ttl": "24h",
                "metadata": { "source": "stripe" }
            }),
        );

        client
            .idempotency_complete(
                "stripe-webhook/event_123",
                "worker-a",
                11,
                Some(json!({ "status": "ok" })),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/idempotency/complete",
            json!({
                "key": "stripe-webhook/event_123",
                "owner": "worker-a",
                "fencing_token": 11,
                "result": { "status": "ok" }
            }),
        );

        client
            .election_campaign_with_metadata(
                "prod/invoice-reconciler/leader",
                "pod-a",
                15_000,
                json!({ "address": "10.2.4.18:8080", "region": "us-east-1" }),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/elections/prod%2Finvoice-reconciler%2Fleader/campaign",
            json!({
                "candidate": "pod-a",
                "ttl_ms": 15_000,
                "metadata": { "address": "10.2.4.18:8080", "region": "us-east-1" }
            }),
        );
    }

    #[test]
    fn counter_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client.counter_get("rollout/v2/failures").unwrap();
        assert_next(
            &rx,
            "GET",
            "/v1/counters?key=rollout%2Fv2%2Ffailures",
            Value::Null,
        );

        client.counter_add("rollout/v2/failures", -1, Some(7)).unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/counters/add",
            json!({ "key": "rollout/v2/failures", "delta": -1, "prev_revision": 7 }),
        );

        client.counter_set("rollout/v2/failures", 0, None).unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/counters/set",
            json!({ "key": "rollout/v2/failures", "value": 0, "prev_revision": null }),
        );
    }

    #[test]
    fn barrier_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client.barrier_get("release/reviewers").unwrap();
        assert_next(
            &rx,
            "GET",
            "/v1/barriers?name=release%2Freviewers",
            Value::Null,
        );

        client
            .barrier_create(
                "release/reviewers",
                json!({ "kind": "quorum", "required": 2 }),
                Some(3),
                None,
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/barriers/create",
            json!({
                "name": "release/reviewers",
                "policy": { "kind": "quorum", "required": 2 },
                "expected": 3,
                "deadline_ms": null
            }),
        );

        client
            .barrier_arrive("release/reviewers", "reviewer-a", None, false)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/barriers/arrive",
            json!({ "name": "release/reviewers", "participant": "reviewer-a", "weight": 1, "veto": false }),
        );
    }

    #[test]
    fn task_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .task_claim("repo/acme/api/issue/482", "agent-a", Some(60_000))
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/tasks/claim",
            json!({ "name": "repo/acme/api/issue/482", "worker": "agent-a", "ttl_ms": 60_000 }),
        );

        client
            .task_complete("repo/acme/api/issue/482", "agent-a", 42, json!({ "pr": 991 }))
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/tasks/complete",
            json!({ "name": "repo/acme/api/issue/482", "worker": "agent-a", "fencing_token": 42, "result": { "pr": 991 } }),
        );
    }

    #[test]
    fn effect_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .effect_prepare(
                "invoice-882/payment",
                "send_payment",
                json!({ "amount_usd": 500 }),
                "high",
                "invoice-882:payment",
                2,
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/effects/prepare",
            json!({
                "name": "invoice-882/payment",
                "effect_type": "send_payment",
                "payload": { "amount_usd": 500 },
                "risk": "high",
                "idempotency_key": "invoice-882:payment",
                "required_approvals": 2
            }),
        );

        client.effect_commit("invoice-882/payment", json!({ "confirmation": "pay_123" })).unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/effects/commit",
            json!({ "name": "invoice-882/payment", "result": { "confirmation": "pay_123" } }),
        );
    }

    #[test]
    fn handoff_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .handoff_offer(
                "ticket-482/handoff",
                "task:ticket-482",
                "research-agent",
                "legal-agent",
                7,
                json!({ "summary": "needs legal review" }),
                Some(30_000),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/handoffs/offer",
            json!({
                "name": "ticket-482/handoff",
                "resource": "task:ticket-482",
                "from": "research-agent",
                "to": "legal-agent",
                "from_token": 7,
                "context": { "summary": "needs legal review" },
                "ttl_ms": 30_000
            }),
        );

        client.handoff_accept("ticket-482/handoff", "legal-agent").unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/handoffs/accept",
            json!({ "name": "ticket-482/handoff", "to": "legal-agent" }),
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

        client
            .service_instances_with_metadata(
                "api",
                &[("version", "blue/1"), ("region", "eu central")],
            )
            .unwrap();
        assert_next(
            &rx,
            "GET",
            "/v1/services/api?metadata.region=eu%20central&metadata.version=blue%2F1",
            Value::Null,
        );
    }

    #[test]
    fn rate_limit_check_uses_structured_request_options() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .rate_limit_check(RateLimitCheckRequest {
                tenant: "tenant/a",
                key: "checkout",
                algorithm: "token_bucket",
                limit: 100,
                window_ms: 60_000,
                refill_per_second: Some(2.5),
                cost: Some(3),
            })
            .unwrap();

        assert_next(
            &rx,
            "POST",
            "/v1/rate-limit/tenant%2Fa/checkout/check",
            json!({
                "algorithm": "token_bucket",
                "limit": 100,
                "window_ms": 60_000,
                "refill_per_second": 2.5,
                "cost": 3,
            }),
        );
    }

    #[test]
    fn request_control_sends_idempotency_key_header() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .try_lock_with_options(
                "orders/42",
                Some("worker-a"),
                None,
                None,
                RequestControl {
                    idempotency_key: Some("req_order_42".to_string()),
                    ..RequestControl::default()
                },
            )
            .unwrap();
        let got = rx.recv_timeout(Duration::from_secs(2)).unwrap();

        assert_eq!(got.method, "POST");
        assert_eq!(got.path, "/v1/locks/acquire");
        assert_eq!(got.idempotency_key.as_deref(), Some("req_order_42"));
        assert!(got.body.get("idempotency_key").is_none());
    }
}
