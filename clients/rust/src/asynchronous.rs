//! Async Fiducia client, built on `reqwest`. Enable with the `async` feature.
//!
//! [`FiduciaClient`](crate::FiduciaClient) is synchronous (`ureq`). Calling it
//! from an axum/tokio service blocks a runtime thread on every lock and
//! rate-limit call — on the request path — so async services were re-writing
//! the protocol by hand instead. Hand-rolled clients then shipped the two
//! defects this crate already avoids: no renew heartbeat, and `not_leader`
//! treated as fatal. This type exists so that correctness is reachable from an
//! async caller.
//!
//! It carries the same invariants as the sync client, and they are the reason
//! to use it rather than raw HTTP:
//!
//! * a credential never crosses a cleartext hop to a public host,
//! * redirects are refused, so a server-named `Location` cannot capture a
//!   bearer token,
//! * only *provably-safe* failures are retried — `429`, an explicitly marked
//!   `503 not_leader`, and (with an idempotency key) ambiguous 5xx,
//! * `renewed: false` is lost fenced authority, not a warning, and
//! * committed mutation data is read from `result.output`, because
//!   `committed: true` only means the command reached the Raft log.

use std::time::Duration;

use serde_json::{json, Value};

use crate::{
    cleartext_http_host, cleartext_internal_host_allowed, explicit_not_leader, Error,
    RequestControl,
};

/// Async twin of [`crate::FiduciaClient`].
///
/// Constructors mirror the sync client: [`new`](Self::new) for an anonymous
/// endpoint, [`internal`](Self::internal) for the trusted in-cluster hop, and
/// [`bearer`](Self::bearer) for an API-key edge.
#[derive(Clone)]
pub struct AsyncFiduciaClient {
    base: String,
    http: reqwest::Client,
    request_timeout: Option<Duration>,
    lock_request_timeout: Option<Duration>,
    retry_max: u32,
    retry_delay: Duration,
    internal_auth: Option<String>,
    org_scope: Option<String>,
    bearer_auth: Option<String>,
    allow_cleartext_internal: bool,
}

impl std::fmt::Debug for AsyncFiduciaClient {
    /// Redacts both credentials so neither can reach a log line via `{:?}`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AsyncFiduciaClient")
            .field("base", &self.base)
            .field(
                "internal_auth",
                &self.internal_auth.as_ref().map(|_| "<set>"),
            )
            .field("org_scope", &self.org_scope)
            .field("bearer_auth", &self.bearer_auth.as_ref().map(|_| "<set>"))
            .finish()
    }
}

impl AsyncFiduciaClient {
    pub fn new(base_url: &str) -> Self {
        // Coordination endpoints are not expected to redirect. Refusing every
        // redirect prevents replaying mutations, idempotency keys, or trusted
        // internal-hop headers to an attacker-controlled Location.
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("static reqwest configuration is valid");
        Self {
            base: base_url.trim_end_matches('/').to_string(),
            http,
            request_timeout: None,
            lock_request_timeout: None,
            retry_max: 0,
            retry_delay: Duration::ZERO,
            internal_auth: None,
            org_scope: None,
            bearer_auth: None,
            allow_cleartext_internal: false,
        }
    }

    /// The trusted internal hop straight to a fiducia-node. See
    /// [`crate::FiduciaClient::internal`] for the transport-security contract:
    /// the secret is bearer-equivalent, and a cleartext base is accepted only
    /// for hosts that are recognizably local or in-cluster.
    pub fn internal(base_url: &str, internal_secret: &str, org_id: &str) -> Self {
        let mut client = Self::new(base_url);
        client.internal_auth = Some(internal_secret.to_string());
        client.org_scope = Some(org_id.to_string());
        client
    }

    /// A public edge or load-balancer endpoint authenticated with an API key.
    pub fn bearer(base_url: &str, api_key: &str) -> Self {
        let mut client = Self::new(base_url);
        client.bearer_auth = Some(api_key.to_string());
        client
    }

    /// Opt in to sending the internal-auth secret over cleartext `http://` to a
    /// host that is not recognizably local/in-cluster. Only for topologies where
    /// the whole path is genuinely trusted.
    pub fn allow_cleartext_internal(mut self) -> Self {
        self.allow_cleartext_internal = true;
        self
    }

    pub fn with_request_timeout(mut self, timeout: Duration) -> Self {
        self.request_timeout = Some(timeout);
        self
    }

    pub fn with_lock_request_timeout(mut self, timeout: Duration) -> Self {
        self.lock_request_timeout = Some(timeout);
        self
    }

    pub fn with_retries(mut self, max_retries: u32, delay: Duration) -> Self {
        self.retry_max = max_retries;
        self.retry_delay = delay;
        self
    }

    /// The refusal, if any, for sending a credential over the configured base.
    /// Pure — checked before every request, so it is unit-testable without a
    /// socket, and identical in meaning to the sync client's check.
    pub fn cleartext_refusal(&self) -> Option<Error> {
        let credential_kind = if self.internal_auth.is_some() {
            if self.allow_cleartext_internal {
                return None;
            }
            "internal-auth secret"
        } else if self.bearer_auth.is_some() {
            "bearer credential"
        } else {
            return None;
        };
        let host = cleartext_http_host(&self.base)?;
        if cleartext_internal_host_allowed(host) {
            return None;
        }
        Some(Error::Transport(format!(
            "fiducia: refusing to send the {credential_kind} over cleartext http:// to public \
             host {host:?}: use https://, an in-cluster address, or loopback"
        )))
    }

    // --- transport -----------------------------------------------------------

    /// Escape hatch for an endpoint this client does not wrap. Prefer a named
    /// method where one exists — they encode the response-shape rules.
    pub async fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, Error> {
        self.request_with_control(method, path, body, RequestControl::default(), false)
            .await
    }

    pub async fn request_with_control(
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
        // A retry re-sends the request. That is only safe when either the server
        // provably did NOT apply the first attempt, or it can dedup a re-send
        // via the caller's idempotency key.
        let has_idempotency = control.idempotency_key.is_some();
        for attempt in 0..=max_retries {
            match self
                .request_once(method, path, body.clone(), &control, lock_acquire)
                .await
            {
                Ok(value) => return Ok(value),
                Err(err) if attempt < max_retries && retryable(&err, has_idempotency) => {
                    let delay = if control.retry_delay > Duration::ZERO {
                        control.retry_delay
                    } else {
                        self.retry_delay
                    };
                    if delay > Duration::ZERO {
                        tokio::time::sleep(delay).await;
                    }
                }
                Err(err) => return Err(err),
            }
        }
        unreachable!("bounded retry loop always returns");
    }

    async fn request_once(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        control: &RequestControl,
        lock_acquire: bool,
    ) -> Result<Value, Error> {
        // Never let a credential travel a cleartext hop to a public host —
        // refuse before anything is sent (or even resolved).
        if let Some(refusal) = self.cleartext_refusal() {
            return Err(refusal);
        }
        let method = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|err| Error::Transport(err.to_string()))?;
        let mut request = self.http.request(method, format!("{}{}", self.base, path));

        if let Some(key) = control.idempotency_key.as_deref() {
            request = request.header("Idempotency-Key", key);
        }
        if let Some(secret) = self.internal_auth.as_deref() {
            request = request.header("x-fiducia-internal-auth", secret);
        }
        if let Some(org) = self.org_scope.as_deref() {
            request = request.header("x-fiducia-org-id", org);
        }
        if let Some(api_key) = self.bearer_auth.as_deref() {
            request = request.bearer_auth(api_key);
        }
        if let Some(timeout) = self.resolve_timeout(control, lock_acquire) {
            request = request.timeout(timeout);
        }
        if let Some(value) = body {
            request = request.json(&value);
        }

        let response = request
            .send()
            .await
            .map_err(|err| Error::Transport(err.to_string()))?;
        let status = response.status().as_u16();
        let parsed = response.json::<Value>().await.ok();
        if status >= 300 {
            Err(Error::Http {
                status,
                body: parsed,
            })
        } else {
            Ok(parsed.unwrap_or(Value::Null))
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

    // --- locks ---------------------------------------------------------------

    /// Acquire `key`. `Ok(None)` means the lock is held by someone else —
    /// contention, not failure. A transport or not-leader error is `Err`,
    /// because then you do *not* know who holds it.
    pub async fn acquire(
        &self,
        key: &str,
        holder: &str,
        ttl_ms: u64,
    ) -> Result<Option<u64>, Error> {
        let response = self
            .request(
                "POST",
                "/v1/locks/acquire",
                Some(json!({ "key": key, "holder": holder, "ttl_ms": ttl_ms })),
            )
            .await?;
        let output = out(&response);
        if output["acquired"].as_bool().unwrap_or(false) {
            Ok(output["fencing_token"].as_u64())
        } else {
            Ok(None)
        }
    }

    /// Extend a held lease without changing its fencing token.
    ///
    /// A `renewed: false` outcome is **lost fenced authority**, not a warning:
    /// fiducia has already reaped the grant and may have promoted another
    /// holder. It is surfaced as `Err` so a caller cannot log-and-continue into
    /// the two-leader bug. Cancel the guarded work.
    pub async fn renew(
        &self,
        key: &str,
        holder: &str,
        fencing_token: u64,
        ttl_ms: u64,
    ) -> Result<Option<u64>, Error> {
        let response = self
            .request(
                "POST",
                "/v1/locks/renew",
                Some(json!({
                    "key": key,
                    "holder": holder,
                    "fencing_token": fencing_token,
                    "ttl_ms": ttl_ms,
                })),
            )
            .await?;
        let output = out(&response);
        if !output["renewed"].as_bool().unwrap_or(false) {
            return Err(Error::Transport(
                "fiducia: lock renewal lost fenced authority".to_string(),
            ));
        }
        Ok(output["lease_expires_ms"].as_u64())
    }

    /// Release a held lock. `Ok(false)` is a **committed no-op** — the command
    /// reached the log but matched no grant, which usually means the lease had
    /// already lapsed. Callers that treat every 2xx as success miss this.
    pub async fn release(
        &self,
        key: &str,
        holder: &str,
        fencing_token: u64,
    ) -> Result<bool, Error> {
        let response = self
            .request(
                "POST",
                "/v1/locks/release",
                Some(json!({
                    "key": key,
                    "holder": holder,
                    "fencing_token": fencing_token,
                })),
            )
            .await?;
        Ok(out(&response)["released"].as_bool().unwrap_or(false))
    }

    // --- rate limiting -------------------------------------------------------

    /// Consume `cost` from `key`'s budget. `Ok(false)` means denied by policy.
    /// A coordination outage is `Err`, so the caller decides fail-open vs
    /// fail-closed deliberately rather than inheriting it from a bool.
    pub async fn rate_limit_check(&self, key: &str, cost: u64) -> Result<bool, Error> {
        let response = self
            .request(
                "POST",
                "/v1/ratelimit/check",
                Some(json!({ "key": key, "cost": cost })),
            )
            .await?;
        Ok(out(&response)["allowed"].as_bool().unwrap_or(false))
    }

    // --- kv ------------------------------------------------------------------

    pub async fn kv_get(&self, key: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/kv?key={}", urlencode(key)), None)
            .await
    }

    pub async fn kv_put(&self, key: &str, value: Value) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!("/v1/kv?key={}", urlencode(key)),
            Some(json!({ "value": value })),
        )
        .await
    }

    pub async fn kv_delete(&self, key: &str) -> Result<Value, Error> {
        self.request("DELETE", &format!("/v1/kv?key={}", urlencode(key)), None)
            .await
    }

    /// Returns `{prefix, count, keys}` — note `keys`, not `entries`.
    pub async fn kv_list(&self, prefix: &str) -> Result<Value, Error> {
        self.request(
            "GET",
            &format!("/v1/kv?prefix={}", urlencode(prefix)),
            None,
        )
        .await
    }
}

/// Committed mutation data lives under `result.output`; `committed: true` only
/// means the command reached the Raft log.
fn out(response: &Value) -> &Value {
    &response["result"]["output"]
}

/// Same policy as the sync client: retry only what is provably safe.
fn retryable(err: &Error, has_idempotency: bool) -> bool {
    match err {
        Error::Http { status, body } => {
            if *status == 429 {
                return true;
            }
            // A marked not_leader proves the operation was rejected *before*
            // application, so a bounded retry is safe even without a key.
            if *status == 503 && explicit_not_leader(body.as_ref()) {
                return true;
            }
            matches!(*status, 408 | 425 | 500 | 502 | 503 | 504) && has_idempotency
        }
        Error::Transport(_) => has_idempotency,
    }
}

fn urlencode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_credential_never_crosses_cleartext_to_a_public_host() {
        for base in ["http://api.fiducia.cloud", "http://8.8.8.8"] {
            assert!(
                AsyncFiduciaClient::bearer(base, "key")
                    .cleartext_refusal()
                    .is_some(),
                "should refuse {base}"
            );
            assert!(
                AsyncFiduciaClient::internal(base, "secret", "org")
                    .cleartext_refusal()
                    .is_some(),
                "should refuse {base}"
            );
        }
    }

    #[test]
    fn anonymous_and_in_cluster_clients_are_unaffected() {
        // No credential: nothing to disclose.
        assert!(AsyncFiduciaClient::new("http://api.fiducia.cloud")
            .cleartext_refusal()
            .is_none());
        for base in [
            "https://api.fiducia.cloud",
            "http://localhost:8080",
            "http://127.0.0.1",
            "http://10.0.0.5",
            "http://fiducia-node",
            "http://n.svc.cluster.local",
        ] {
            assert!(
                AsyncFiduciaClient::bearer(base, "key")
                    .cleartext_refusal()
                    .is_none(),
                "should allow {base}"
            );
        }
        // …and the documented escape hatch still works.
        assert!(AsyncFiduciaClient::internal("http://api.fiducia.cloud", "s", "o")
            .allow_cleartext_internal()
            .cleartext_refusal()
            .is_none());
    }

    #[test]
    fn neither_credential_reaches_a_debug_line() {
        let rendered = format!(
            "{:?}",
            AsyncFiduciaClient::internal("https://x", "internal-secret", "org")
                .with_retries(1, Duration::ZERO)
        );
        assert!(!rendered.contains("internal-secret"), "{rendered}");
        let rendered = format!("{:?}", AsyncFiduciaClient::bearer("https://x", "api-key"));
        assert!(!rendered.contains("api-key"), "{rendered}");
    }

    #[test]
    fn only_provably_safe_failures_retry() {
        let not_leader = Error::Http {
            status: 503,
            body: Some(json!({"error": {"reason": "not_leader", "retryable": true}})),
        };
        // Marked not_leader is safe to retry with no idempotency key at all.
        assert!(retryable(&not_leader, false));
        assert!(retryable(&Error::Http { status: 429, body: None }, false));

        // A bare 503 is ambiguous: the mutation may have applied.
        let bare = Error::Http { status: 503, body: None };
        assert!(!retryable(&bare, false));
        assert!(retryable(&bare, true));

        // Transport failures are ambiguous in the same way.
        assert!(!retryable(&Error::Transport("reset".into()), false));
        assert!(retryable(&Error::Transport("reset".into()), true));

        // Terminal statuses never retry.
        for status in [400, 401, 403, 404, 409, 422] {
            assert!(!retryable(&Error::Http { status, body: None }, true), "{status}");
        }
    }

    #[test]
    fn committed_data_is_read_from_result_output() {
        let response = json!({
            "committed": true,
            "result": { "output": { "acquired": true, "fencing_token": 42 } }
        });
        assert_eq!(out(&response)["fencing_token"].as_u64(), Some(42));
    }
}
