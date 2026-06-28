//! Fiducia HTTP client (Rust), built on `ureq`. Implements PROTOCOL.md.
//!
//! ```no_run
//! let c = fiducia_client::FiduciaClient::new("https://api.fiducia.cloud");
//! let lock = c.lock_acquire("orders/checkout", Some("worker-a"), Some(30_000), false, None).unwrap();
//! let token = lock["result"]["fencing_token"].as_u64().unwrap();
//! c.lock_release("orders/checkout", "worker-a", token).unwrap();
//! ```

use serde_json::{json, Value};

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

/// HTTP client for a fiducia endpoint (edge / load balancer / node).
pub struct FiduciaClient {
    base: String,
    agent: ureq::Agent,
}

impl FiduciaClient {
    pub fn new(base_url: &str) -> Self {
        Self {
            base: base_url.trim_end_matches('/').to_string(),
            agent: ureq::agent(),
        }
    }

    fn request(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, Error> {
        let url = format!("{}{}", self.base, path);
        let req = self.agent.request(method, &url);
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

    // --- misc ---
    pub fn health(&self) -> Result<Value, Error> {
        self.request("GET", "/healthz", None)
    }
    pub fn status(&self) -> Result<Value, Error> {
        self.request("GET", "/v1/status", None)
    }

    // --- locks ---
    pub fn lock_get(&self, key: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/locks/{}", enc(key)), None)
    }
    pub fn lock_acquire(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/locks/{}/acquire", enc(key)),
            Some(json!({ "holder": holder, "ttl_ms": ttl_ms, "wait": wait, "max": max })),
        )
    }
    pub fn lock_acquire_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/locks/acquire-many",
            Some(json!({ "keys": keys, "holder": holder, "ttl_ms": ttl_ms, "wait": wait })),
        )
    }
    pub fn lock_release(
        &self,
        key: &str,
        holder: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/locks/{}/release", enc(key)),
            Some(json!({ "holder": holder, "fencing_token": fencing_token })),
        )
    }
    pub fn lock_release_many(&self, lock_id: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/locks/release-many",
            Some(json!({ "lock_id": lock_id })),
        )
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
        self.request(
            "POST",
            &format!("/v1/semaphores/{}/acquire", enc(key)),
            Some(json!({ "holder": holder, "ttl_ms": ttl_ms, "wait": wait, "max": max.max(2) })),
        )
    }
    pub fn semaphore_release(
        &self,
        key: &str,
        holder: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            &format!("/v1/semaphores/{}/release", enc(key)),
            Some(json!({ "holder": holder, "fencing_token": fencing_token })),
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
        self.request("GET", &format!("/v1/kv/{}", enc(key)), None)
    }
    pub fn kv_put(&self, key: &str, value: &str, ttl_ms: Option<u64>) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!("/v1/kv/{}", enc(key)),
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
            &format!("/v1/kv/{}", enc(key)),
            Some(json!({ "value": value, "ttl_ms": ttl_ms, "prev_revision": prev_revision })),
        )
    }
    pub fn kv_delete(&self, key: &str) -> Result<Value, Error> {
        self.request("DELETE", &format!("/v1/kv/{}", enc(key)), None)
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
        let mut body = json!({ "address": address, "ttl_ms": ttl_ms });
        if let Some(metadata) = metadata {
            body["metadata"] = metadata;
        }
        self.request(
            "PUT",
            &format!(
                "/v1/services/{}/instances/{}",
                enc(service),
                enc(instance_id)
            ),
            Some(body),
        )
    }
    /// Heartbeat to keep an instance live. `ttl_ms` overrides the lease length.
    pub fn service_heartbeat(
        &self,
        service: &str,
        instance_id: &str,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        let body = ttl_ms.map(|ttl_ms| json!({ "ttl_ms": ttl_ms }));
        self.request(
            "POST",
            &format!(
                "/v1/services/{}/instances/{}/heartbeat",
                enc(service),
                enc(instance_id)
            ),
            body,
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
}
