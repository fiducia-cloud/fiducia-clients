//! Fiducia HTTP client (Rust), built on `ureq`. Implements PROTOCOL.md.
//!
//! ```no_run
//! let c = fiducia_client::FiduciaClient::new("https://api.fiducia.cloud");
//! let lock = c.lock_acquire("orders/checkout", Some("worker-a"), Some(30_000), false, None).unwrap();
//! let token = lock["result"]["output"]["fencing_token"].as_u64().unwrap();
//! c.lock_release("orders/checkout", "worker-a", token).unwrap();
//! ```

use serde_json::{json, Value};
use std::{fmt, thread, time::Duration};
use ureq::http::{self, header::HeaderValue};

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

fn sensitive_header_value(value: &str) -> Result<HeaderValue, Error> {
    let mut header = HeaderValue::from_str(value)
        .map_err(|err| Error::Transport(format!("invalid sensitive request header: {err}")))?;
    // Defense in depth: ureq 3 redacts non-allowlisted headers from its debug
    // logs, and http::HeaderValue also redacts values explicitly marked
    // sensitive if another layer formats the request directly.
    header.set_sensitive(true);
    Ok(header)
}

/// The host portion of `base` when (and only when) its scheme is cleartext
/// `http://`. Returns `None` for `https://` or anything unparseable (which the
/// request builder will reject on its own later).
fn cleartext_http_host(base: &str) -> Option<&str> {
    if base.len() < 7 || !base[..7].eq_ignore_ascii_case("http://") {
        return None;
    }
    let rest = &base[7..];
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    if let Some(v6) = host_port.strip_prefix('[') {
        return Some(v6.split(']').next().unwrap_or(v6));
    }
    Some(host_port.split(':').next().unwrap_or(host_port))
}

/// Whether `host` is one an authentication credential may travel to in cleartext:
/// loopback, a private/link-local IP, a single-label service name (compose /
/// same-namespace k8s), or a cluster-internal DNS suffix. Public DNS names and
/// public IPs are refused — a bearer-equivalent secret must not cross a path an
/// on-path observer could watch (see [`FiduciaClient::internal`] and
/// [`FiduciaClient::bearer`]).
fn cleartext_internal_host_allowed(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    if host == "localhost" || host.ends_with(".localhost") {
        return true;
    }
    if let Ok(v4) = host.parse::<std::net::Ipv4Addr>() {
        return v4.is_loopback() || v4.is_private() || v4.is_link_local();
    }
    if let Ok(v6) = host.parse::<std::net::Ipv6Addr>() {
        let seg0 = v6.segments()[0];
        return v6.is_loopback() || (seg0 & 0xfe00) == 0xfc00 || (seg0 & 0xffc0) == 0xfe80;
    }
    // Single-label names only resolve via local/cluster search domains, never
    // public DNS — the in-cluster `http://fiducia-node:8090` shape.
    if !host.contains('.') {
        return true;
    }
    [".svc", ".svc.cluster.local", ".cluster.local", ".internal"]
        .iter()
        .any(|suffix| host.ends_with(suffix))
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

/// A per-axis budget amount or limit. `None` on an axis means unlimited (for a
/// limit) or unset (for a spend/amount).
#[derive(Clone, Copy, Debug, Default)]
pub struct BudgetAmount {
    pub usd_micros: Option<u64>,
    pub tokens: Option<u64>,
    pub tool_calls: Option<u64>,
}

impl BudgetAmount {
    fn to_json(self) -> Value {
        let mut map = serde_json::Map::new();
        if let Some(v) = self.usd_micros {
            map.insert("usd_micros".into(), json!(v));
        }
        if let Some(v) = self.tokens {
            map.insert("tokens".into(), json!(v));
        }
        if let Some(v) = self.tool_calls {
            map.insert("tool_calls".into(), json!(v));
        }
        Value::Object(map)
    }
}

/// Parameters for casting a decision vote.
#[derive(Clone, Copy, Debug)]
pub struct DecisionVote<'a> {
    pub voter: &'a str,
    /// The chosen option, or `None` to abstain.
    pub option: Option<&'a str>,
    pub confidence: f64,
    pub weight: u64,
    pub veto: bool,
    pub evidence: &'a [&'a str],
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
    /// Internal-hop secret (`x-fiducia-internal-auth`). Set only when calling a
    /// fiducia-node directly (bypassing the edge/LB) as a trusted internal
    /// service; leave `None` for customer-facing edge/LB calls.
    internal_auth: Option<String>,
    /// Org scope (`x-fiducia-org-id`) attached to internal-hop calls so the node
    /// can attribute/scope the request to a tenant.
    org_scope: Option<String>,
    /// API key sent as a bearer credential to an edge/load-balancer endpoint.
    /// This is mutually exclusive with the trusted internal-hop headers.
    bearer_auth: Option<String>,
    /// Explicit opt-in to sending the internal-auth secret over cleartext http
    /// to a host that is not recognizably local/in-cluster. See
    /// [`allow_cleartext_internal`](Self::allow_cleartext_internal).
    allow_cleartext_internal: bool,
}

impl fmt::Debug for FiduciaClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FiduciaClient")
            .field("base", &self.base)
            .field("request_timeout", &self.request_timeout)
            .field("lock_request_timeout", &self.lock_request_timeout)
            .field("retry_max", &self.retry_max)
            .field("retry_delay", &self.retry_delay)
            .field(
                "internal_auth",
                &self.internal_auth.as_ref().map(|_| "<redacted>"),
            )
            .field("org_scope", &self.org_scope.as_ref().map(|_| "<redacted>"))
            .field(
                "bearer_auth",
                &self.bearer_auth.as_ref().map(|_| "<redacted>"),
            )
            .finish()
    }
}

impl FiduciaClient {
    pub fn new(base_url: &str) -> Self {
        // Coordination endpoints are not expected to redirect. Refusing every
        // redirect prevents replaying mutations, idempotency keys, or trusted
        // internal-hop headers to an attacker-controlled Location.
        let config = ureq::Agent::config_builder()
            .max_redirects(0)
            .http_status_as_error(false)
            .build();
        Self {
            base: base_url.trim_end_matches('/').to_string(),
            agent: config.into(),
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

    /// A client for the trusted internal hop straight to a fiducia-node: attaches
    /// the internal-auth secret and org scope to every request. Use this from a
    /// service (never from an untrusted client) to read/write a tenant's
    /// coordination state.
    ///
    /// # Transport security
    ///
    /// `internal_secret` is **bearer-equivalent**: anyone who observes it can
    /// impersonate an internal service. It is sent as the `x-fiducia-internal-auth`
    /// request header on every call, so the transport MUST be confidential on any
    /// path an attacker could observe:
    ///
    /// * In-cluster (`base_url` a plaintext `http://…svc.cluster.local` node
    ///   address on a NetworkPolicy-restricted network) is the intended
    ///   deployment — the internal network is the trust boundary.
    /// * Across ANY untrusted network (public internet, a shared LAN, a hop that
    ///   leaves the cluster) `base_url` MUST be `https://`. Passing an `http://`
    ///   base over such a path leaks the secret in cleartext to any on-path
    ///   observer.
    ///
    /// The header value is marked sensitive and never crosses a redirect
    /// (`max_redirects(0)`), but that does not protect a cleartext hop — pick the
    /// scheme to match where the request actually travels.
    ///
    /// **Enforced:** an `http://` base is accepted only for hosts that are
    /// recognizably local or in-cluster (loopback, private/link-local IPs,
    /// single-label service names, `*.svc` / `*.cluster.local` / `*.internal`).
    /// A cleartext request to any other host — a public DNS name or
    /// public IP — is refused with a typed error before anything is sent. Use
    /// `https://`, or opt in explicitly with
    /// [`allow_cleartext_internal`](Self::allow_cleartext_internal) for an
    /// unusual-but-trusted topology.
    pub fn internal(base_url: &str, internal_secret: &str, org_id: &str) -> Self {
        let mut client = Self::new(base_url);
        client.internal_auth = Some(internal_secret.to_string());
        client.org_scope = Some(org_id.to_string());
        client
    }

    /// A client for a public edge or load-balancer endpoint authenticated with a
    /// Fiducia API key. The bearer credential is redacted in debug output and is
    /// never replayed through a redirect. For a non-loopback/non-cluster target,
    /// the base URL must use `https://`; cleartext public endpoints are refused
    /// before a request is sent.
    pub fn bearer(base_url: &str, api_key: &str) -> Self {
        let mut client = Self::new(base_url);
        client.bearer_auth = Some(api_key.to_string());
        client
    }

    /// Opt in to sending the internal-auth secret over cleartext `http://` to a
    /// host that is not recognizably local/in-cluster. Only for topologies where
    /// a multi-label internal DNS name doesn't match the recognized suffixes and
    /// the whole path is genuinely trusted — anyone observing the hop can
    /// impersonate an internal service with the captured secret.
    pub fn allow_cleartext_internal(mut self) -> Self {
        self.allow_cleartext_internal = true;
        self
    }

    /// The refusal (if any) for sending the internal-auth secret over the
    /// configured base. Pure — checked before every request; factored out so the
    /// policy is unit-testable without a socket.
    fn cleartext_refusal(&self) -> Option<Error> {
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
            "refusing to send the {credential_kind} over cleartext http to \
             public host '{host}': use an https:// base_url, an in-cluster \
             address, or loopback"
        )))
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
        // A retry re-sends the request. That is only safe when either the server
        // provably did NOT apply the first attempt, or it can dedup a re-send via
        // the caller's idempotency key. Thread that fact into the retry decision so
        // a keyless, non-idempotent mutation is never double-applied.
        let has_idempotency = control.idempotency_key.is_some();
        for attempt in 0..=max_retries {
            match self.request_once(method, path, body.clone(), control.clone(), lock_acquire) {
                Ok(value) => return Ok(value),
                Err(err) if attempt < max_retries && Self::retryable(&err, has_idempotency) => {
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
        // Never let an authentication credential travel a cleartext hop to a
        // public host — refuse before anything is sent (or resolved).
        if let Some(refusal) = self.cleartext_refusal() {
            return Err(refusal);
        }
        let url = format!("{}{}", self.base, path);
        let mut builder = http::Request::builder().method(method).uri(&url);
        if let Some(key) = control.idempotency_key.as_deref() {
            builder = builder.header("Idempotency-Key", key);
        }
        // Internal-hop headers (only present on clients built via `internal()`).
        if let Some(secret) = self.internal_auth.as_deref() {
            builder = builder.header("x-fiducia-internal-auth", sensitive_header_value(secret)?);
        }
        if let Some(org) = self.org_scope.as_deref() {
            builder = builder.header("x-fiducia-org-id", sensitive_header_value(org)?);
        }
        if let Some(api_key) = self.bearer_auth.as_deref() {
            builder = builder.header(
                "authorization",
                sensitive_header_value(&format!("Bearer {api_key}"))?,
            );
        }
        let timeout = self.resolve_timeout(&control, lock_acquire);
        let resp = match body {
            Some(value) => {
                let bytes =
                    serde_json::to_vec(&value).map_err(|err| Error::Transport(err.to_string()))?;
                let request = builder
                    .header("content-type", "application/json")
                    .body(bytes)
                    .map_err(|err| Error::Transport(err.to_string()))?;
                let request = self
                    .agent
                    .configure_request(request)
                    .timeout_global(timeout)
                    .build();
                self.agent.run(request)
            }
            None => {
                let request = builder
                    .body(())
                    .map_err(|err| Error::Transport(err.to_string()))?;
                let request = self
                    .agent
                    .configure_request(request)
                    .timeout_global(timeout)
                    .build();
                self.agent.run(request)
            }
        };
        match resp {
            Ok(mut response) => {
                let status = response.status().as_u16();
                let parsed = response.body_mut().read_json::<Value>().ok();
                if status >= 300 {
                    Err(Error::Http {
                        status,
                        body: parsed,
                    })
                } else {
                    Ok(parsed.unwrap_or(Value::Null))
                }
            }
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

    /// Whether `err` may be retried. `429` and `503` mean the server rejected the
    /// request before applying it, so re-sending is always safe. Every other
    /// retryable status (`408/425/500/502/504`) and any transport failure can
    /// occur *after* the server applied a mutation, so re-sending is only safe
    /// when the caller supplied an idempotency key for the server to dedup on.
    fn retryable(err: &Error, has_idempotency: bool) -> bool {
        match err {
            Error::Http { status, .. } => match *status {
                429 | 503 => true,
                408 | 425 | 500 | 502 | 504 => has_idempotency,
                _ => false,
            },
            Error::Transport(_) => has_idempotency,
        }
    }

    // Mirrors the compatibility surface's independent acquire controls.
    #[allow(clippy::too_many_arguments)]
    fn lock_acquire_with_wait(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        _max: Option<u32>,
        request_id: Option<&str>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        let holder = locking::holder_or_generated(holder);
        let mut body = json!({ "key": key, "holder": holder, "ttl_ms": ttl_ms, "wait": wait });
        if let Some(request_id) = request_id {
            locking::validate_request_id(request_id)?;
            body["request_id"] = Value::String(request_id.to_string());
        }
        self.request_with_control("POST", "/v1/locks/acquire", Some(body), control, true)
    }

    fn lock_acquire_many_with_wait(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        request_id: Option<&str>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        let holder = locking::holder_or_generated(holder);
        let mut body = json!({ "keys": keys, "holder": holder, "ttl_ms": ttl_ms, "wait": wait });
        if let Some(request_id) = request_id {
            locking::validate_request_id(request_id)?;
            body["request_id"] = Value::String(request_id.to_string());
        }
        self.request_with_control("POST", "/v1/locks/acquire", Some(body), control, true)
    }

    // Mirrors the compatibility surface's independent acquire controls.
    #[allow(clippy::too_many_arguments)]
    fn semaphore_acquire_with_wait(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: u32,
        request_id: Option<&str>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        let holder = locking::holder_or_generated(holder);
        let mut body = json!({ "key": key, "holder": holder, "ttl_ms": ttl_ms, "wait": wait, "limit": max.max(1) });
        if let Some(request_id) = request_id {
            locking::validate_request_id(request_id)?;
            body["request_id"] = Value::String(request_id.to_string());
        }
        self.request_with_control(
            "POST",
            "/v1/semaphores/acquire",
            // Clamp only the invalid `0` up to `1`; never clamp higher. `max=1`
            // is a mutex (per the shared LockAcquireRequest contract), and the
            // old `.max(2)` silently turned a mutex into a capacity-2 semaphore,
            // letting two holders enter a section that must admit exactly one.
            Some(body),
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
    /// Read one supported node observability inventory. This remains read-only
    /// and validates `kind` rather than interpolating arbitrary path segments.
    pub fn observe(&self, kind: &str) -> Result<Value, Error> {
        match kind {
            "locks" | "semaphores" | "elections" | "shards" | "metrics" => {
                self.request("GET", &format!("/v1/observe/{kind}"), None)
            }
            _ => Err(Error::Transport(format!(
                "unknown observe kind {kind:?}; expected locks, semaphores, elections, shards, or metrics"
            ))),
        }
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
        self.lock_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            wait,
            max,
            None,
            RequestControl::default(),
        )
    }
    /// Acquire a single lock under an attempt-scoped request identity. Reuse
    /// the same request_id for retries and cancellation, never for a later
    /// logical attempt. Passing None preserves the legacy wire contract.
    pub fn lock_acquire_with_request_id(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: Option<u32>,
        request_id: Option<&str>,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            wait,
            max,
            request_id,
            RequestControl::default(),
        )
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
        self.lock_acquire_with_wait(key, holder, ttl_ms, wait, max, None, control)
    }
    pub fn try_lock(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            false,
            max,
            None,
            RequestControl::default(),
        )
    }
    pub fn try_lock_with_options(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, false, max, None, control)
    }
    pub fn must_lock(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            true,
            max,
            None,
            RequestControl::default(),
        )
    }
    pub fn must_lock_with_options(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: Option<u32>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_with_wait(key, holder, ttl_ms, true, max, None, control)
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
        self.lock_acquire_many_with_wait(
            keys,
            holder,
            ttl_ms,
            wait,
            None,
            RequestControl::default(),
        )
    }
    /// Acquire a union lock under an attempt-scoped request identity.
    pub fn lock_acquire_many_with_request_id(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        request_id: Option<&str>,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(
            keys,
            holder,
            ttl_ms,
            wait,
            request_id,
            RequestControl::default(),
        )
    }
    pub fn lock_acquire_many_with_options(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(keys, holder, ttl_ms, wait, None, control)
    }
    pub fn try_lock_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(
            keys,
            holder,
            ttl_ms,
            false,
            None,
            RequestControl::default(),
        )
    }
    pub fn must_lock_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.lock_acquire_many_with_wait(
            keys,
            holder,
            ttl_ms,
            true,
            None,
            RequestControl::default(),
        )
    }
    pub fn lock_many(
        &self,
        keys: &[&str],
        holder: Option<&str>,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.must_lock_many(keys, holder, ttl_ms)
    }
    pub fn lock_renew(
        &self,
        keys: &[&str],
        holder: &str,
        fencing_token: u64,
        ttl_ms: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/locks/renew",
            Some(json!({
                "keys": keys,
                "holder": holder,
                "fencing_token": fencing_token,
                "ttl_ms": ttl_ms,
            })),
        )
    }
    pub fn lock_cancel(&self, keys: &[&str], holder: &str) -> Result<Value, Error> {
        self.lock_cancel_with_request_id(keys, holder, None)
    }
    /// Cancel exactly one logical union-lock acquisition attempt. None keeps
    /// the legacy holder/key cancellation behavior for rolling upgrades.
    pub fn lock_cancel_with_request_id(
        &self,
        keys: &[&str],
        holder: &str,
        request_id: Option<&str>,
    ) -> Result<Value, Error> {
        let mut body = json!({ "keys": keys, "holder": holder });
        if let Some(request_id) = request_id {
            locking::validate_request_id(request_id)?;
            body["request_id"] = Value::String(request_id.to_string());
        }
        self.request("POST", "/v1/locks/cancel", Some(body))
    }
    pub fn lock_release(
        &self,
        _key: &str,
        holder: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.lock_release_with_options(_key, holder, fencing_token, RequestControl::default())
    }
    pub fn lock_release_with_options(
        &self,
        _key: &str,
        holder: &str,
        fencing_token: u64,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.request_with_control(
            "POST",
            "/v1/locks/release",
            Some(json!({ "holder": holder, "fencing_token": fencing_token })),
            control,
            false,
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
        self.semaphore_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            wait,
            max,
            None,
            RequestControl::default(),
        )
    }
    /// Acquire a semaphore permit under an attempt-scoped request identity.
    pub fn semaphore_acquire_with_request_id(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        wait: bool,
        max: u32,
        request_id: Option<&str>,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            wait,
            max,
            request_id,
            RequestControl::default(),
        )
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
        self.semaphore_acquire_with_wait(key, holder, ttl_ms, wait, max, None, control)
    }
    pub fn try_semaphore(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: u32,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            false,
            max,
            None,
            RequestControl::default(),
        )
    }
    pub fn must_semaphore(
        &self,
        key: &str,
        holder: Option<&str>,
        ttl_ms: Option<u64>,
        max: u32,
    ) -> Result<Value, Error> {
        self.semaphore_acquire_with_wait(
            key,
            holder,
            ttl_ms,
            true,
            max,
            None,
            RequestControl::default(),
        )
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
    pub fn semaphore_renew(
        &self,
        key: &str,
        holder: &str,
        fencing_token: u64,
        ttl_ms: u64,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/semaphores/renew",
            Some(json!({
                "key": key,
                "holder": holder,
                "fencing_token": fencing_token,
                "ttl_ms": ttl_ms,
            })),
        )
    }
    pub fn semaphore_cancel(&self, key: &str, holder: &str) -> Result<Value, Error> {
        self.semaphore_cancel_with_request_id(key, holder, None)
    }
    /// Cancel exactly one logical semaphore acquisition attempt.
    pub fn semaphore_cancel_with_request_id(
        &self,
        key: &str,
        holder: &str,
        request_id: Option<&str>,
    ) -> Result<Value, Error> {
        let mut body = json!({ "key": key, "holder": holder });
        if let Some(request_id) = request_id {
            locking::validate_request_id(request_id)?;
            body["request_id"] = Value::String(request_id.to_string());
        }
        self.request("POST", "/v1/semaphores/cancel", Some(body))
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

    // --- local-first sync ---
    /// Send the canonical `fiducia-interfaces` queued-write envelope. The
    /// client always reuses `write.key` as the HTTP idempotency key, so this is
    /// safe to bind to a durable fiducia-sync queue.
    pub fn sync_write(
        &self,
        write: &types::SyncQueuedWrite,
        path_prefix: Option<&str>,
        control: Option<RequestControl>,
    ) -> Result<types::SyncWriteAcknowledgement, Error> {
        if write.table.trim().is_empty()
            || write.id.trim().is_empty()
            || write.key.trim().is_empty()
            || write.base_version < 0
        {
            return Err(Error::Transport(
                "sync write has an empty identity or negative base_version".to_string(),
            ));
        }
        let mut control = control.unwrap_or_default();
        if let Some(explicit) = control.idempotency_key.as_deref() {
            if explicit != write.key {
                return Err(Error::Transport(
                    "explicit idempotency key does not match the sync write key".to_string(),
                ));
            }
        } else {
            control.idempotency_key = Some(write.key.clone());
        }
        let prefix = path_prefix
            .unwrap_or("/api/customer/sync")
            .trim_end_matches('/');
        if prefix.is_empty() {
            return Err(Error::Transport(
                "sync path prefix must be nonempty".to_string(),
            ));
        }
        let body = serde_json::to_value(write).map_err(|err| Error::Transport(err.to_string()))?;
        let value = self.request_with_control(
            "POST",
            &format!("{prefix}/{}", enc(&write.table)),
            Some(body),
            control,
            false,
        )?;
        let acknowledgement: types::SyncWriteAcknowledgement =
            serde_json::from_value(value).map_err(|err| Error::Transport(err.to_string()))?;
        if acknowledgement.id != write.id || acknowledgement.committed_version < 0 {
            return Err(Error::Transport(
                "sync acknowledgement does not match the queued write".to_string(),
            ));
        }
        Ok(acknowledgement)
    }

    /// Fetch one globally ordered catch-up page using the canonical interface
    /// type consumed by fiducia-sync.
    pub fn sync_pull(
        &self,
        table: &str,
        cursor: i64,
        limit: u16,
        path_prefix: Option<&str>,
        control: Option<RequestControl>,
    ) -> Result<types::SyncPullPage, Error> {
        if table.trim().is_empty() || cursor < 0 || limit == 0 || limit > 1_000 {
            return Err(Error::Transport(
                "sync table, cursor, or limit is outside its valid range".to_string(),
            ));
        }
        let prefix = path_prefix
            .unwrap_or("/api/customer/sync")
            .trim_end_matches('/');
        if prefix.is_empty() {
            return Err(Error::Transport(
                "sync path prefix must be nonempty".to_string(),
            ));
        }
        let mut value = self.request_with_control(
            "GET",
            &format!("{prefix}/{}?cursor={cursor}&limit={limit}", enc(table)),
            None,
            control.unwrap_or_default(),
            false,
        )?;
        if let Some(changes) = value.get_mut("changes").and_then(Value::as_array_mut) {
            for change in changes {
                let Some(change) = change.as_object_mut() else {
                    continue;
                };
                change.entry("at_ms").or_insert(json!(0));
                if !change.contains_key("sync_sequence") {
                    if let Some(sequence) = change.get("sequence").cloned() {
                        change.insert("sync_sequence".to_string(), sequence);
                    }
                }
            }
        }
        let page: types::SyncPullPage =
            serde_json::from_value(value).map_err(|err| Error::Transport(err.to_string()))?;
        if page.next_cursor < cursor {
            return Err(Error::Transport(
                "sync pull cursor moved backwards".to_string(),
            ));
        }
        Ok(page)
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
        self.kv_put_with_options(key, value, ttl_ms, None, false)
    }
    pub fn kv_put_cas(
        &self,
        key: &str,
        value: &str,
        ttl_ms: Option<u64>,
        prev_revision: Option<u64>,
    ) -> Result<Value, Error> {
        self.kv_put_with_options(key, value, ttl_ms, prev_revision, false)
    }
    /// Write KV with compare-and-swap and storage-protection controls.
    /// `plaintext=true` explicitly opts this value out of cluster-side at-rest
    /// encryption; callers should normally leave it false.
    pub fn kv_put_with_options(
        &self,
        key: &str,
        value: &str,
        ttl_ms: Option<u64>,
        prev_revision: Option<u64>,
        plaintext: bool,
    ) -> Result<Value, Error> {
        self.request(
            "PUT",
            &format!("/v1/kv?key={}", enc(key)),
            Some(json!({
                "value": value,
                "ttl_ms": ttl_ms,
                "prev_revision": prev_revision,
                "plaintext": plaintext,
            })),
        )
    }
    pub fn kv_delete(&self, key: &str) -> Result<Value, Error> {
        self.request("DELETE", &format!("/v1/kv?key={}", enc(key)), None)
    }
    pub fn kv_list(&self, prefix: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/kv?prefix={}", enc(prefix)), None)
    }

    // --- secrets (write-only ergonomics over the encrypted config KV) ---
    // Secrets live under the reserved "secret/" keyspace and are ALWAYS stored
    // with at-rest encryption (never plaintext). `secret_list` returns names +
    // metadata only; a value is exposed solely through `secret_reveal`. This
    // requires the cluster to have KV protection configured.
    pub fn secret_put(
        &self,
        name: &str,
        value: &str,
        ttl_ms: Option<u64>,
        prev_revision: Option<u64>,
    ) -> Result<Value, Error> {
        let key = secret_key(name)?;
        self.request(
            "PUT",
            &format!("/v1/kv?key={}", enc(&key)),
            Some(json!({
                "value": value,
                "ttl_ms": ttl_ms,
                "prev_revision": prev_revision,
                "plaintext": false,
            })),
        )
    }
    /// Explicitly read (reveal) a secret's decrypted value.
    pub fn secret_reveal(&self, name: &str) -> Result<Value, Error> {
        let key = secret_key(name)?;
        self.request("GET", &format!("/v1/kv?key={}", enc(&key)), None)
    }
    pub fn secret_delete(&self, name: &str) -> Result<Value, Error> {
        let key = secret_key(name)?;
        self.request("DELETE", &format!("/v1/kv?key={}", enc(&key)), None)
    }
    /// List secret names + metadata under an optional sub-prefix; never values.
    pub fn secret_list(&self, prefix: &str) -> Result<Value, Error> {
        let raw = self.request(
            "GET",
            &format!("/v1/kv?prefix={}", enc(&format!("secret/{prefix}"))),
            None,
        )?;
        Ok(strip_secret_values(raw))
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
    // Keep the public method parallel to the HTTP contract; bundling these fields
    // would be a breaking client API change.
    #[allow(clippy::too_many_arguments)]
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

    // --- hierarchical budgets ---
    /// Read a budget's ceiling, consumption, and reservations. Absent reports
    /// `found: false`.
    pub fn budget_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/budgets?name={}", enc(name)), None)
    }
    /// Create or re-cap a budget with a per-axis ceiling (unset axis = unlimited).
    pub fn budget_set(&self, name: &str, limit: BudgetAmount) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/budgets/set",
            Some(json!({ "name": name, "limit": limit.to_json() })),
        )
    }
    /// Reserve `amount` under `reservation_id`; rejected if it would exceed the
    /// ceiling on any limited axis.
    pub fn budget_reserve(
        &self,
        name: &str,
        reservation_id: &str,
        holder: &str,
        amount: BudgetAmount,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/budgets/reserve",
            Some(json!({ "name": name, "reservation_id": reservation_id, "holder": holder, "amount": amount.to_json() })),
        )
    }
    /// Commit a reservation with the `actual` spend (capped at the reservation),
    /// freeing the difference.
    pub fn budget_commit(
        &self,
        name: &str,
        reservation_id: &str,
        actual: BudgetAmount,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/budgets/commit",
            Some(json!({ "name": name, "reservation_id": reservation_id, "actual": actual.to_json() })),
        )
    }
    /// Release a still-held reservation, returning its full headroom.
    pub fn budget_release(&self, name: &str, reservation_id: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/budgets/release",
            Some(json!({ "name": name, "reservation_id": reservation_id })),
        )
    }

    // --- claims (contestable ledger) ---
    /// Read a claim's subject/predicate/value, status, support, and contests.
    /// Absent reports `found: false`.
    pub fn claim_get(&self, name: &str) -> Result<Value, Error> {
        self.request("GET", &format!("/v1/claims?name={}", enc(name)), None)
    }
    /// Assert (or re-assert) a claim; re-asserting bumps the version and resets
    /// support/contests.
    #[allow(clippy::too_many_arguments)]
    pub fn claim_assert(
        &self,
        name: &str,
        subject: &str,
        predicate: &str,
        value: Value,
        confidence: f64,
        author: &str,
        evidence: &[&str],
        valid_until_ms: Option<u64>,
    ) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/claims/assert",
            Some(json!({
                "name": name,
                "subject": subject,
                "predicate": predicate,
                "value": value,
                "confidence": confidence,
                "author": author,
                "evidence": evidence,
                "valid_until_ms": valid_until_ms,
            })),
        )
    }
    /// Record an agent's support for a claim.
    pub fn claim_support(&self, name: &str, agent: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/claims/support",
            Some(json!({ "name": name, "agent": agent })),
        )
    }
    /// Record an agent's contest of a claim, moving it to `contested`.
    pub fn claim_contest(&self, name: &str, agent: &str, reason: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/claims/contest",
            Some(json!({ "name": name, "agent": agent, "reason": reason })),
        )
    }
    /// Authoritatively accept or reject a claim (terminal).
    pub fn claim_resolve(&self, name: &str, accepted: bool) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/claims/resolve",
            Some(json!({ "name": name, "accepted": accepted })),
        )
    }
    /// Supersede a claim with a newer one (terminal).
    pub fn claim_supersede(&self, name: &str, superseded_by: &str) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/claims/supersede",
            Some(json!({ "name": name, "superseded_by": superseded_by })),
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
        self.election_campaign_with_options(
            name,
            candidate,
            ttl_ms,
            metadata,
            RequestControl::default(),
        )
    }
    pub fn election_campaign_with_options(
        &self,
        name: &str,
        candidate: &str,
        ttl_ms: u64,
        metadata: Option<Value>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        let mut body = json!({ "candidate": candidate, "ttl_ms": ttl_ms });
        if let Some(metadata) = metadata {
            body["metadata"] = metadata;
        }
        self.request_with_control(
            "POST",
            &format!("/v1/elections/{}/campaign", enc(name)),
            Some(body),
            control,
            false,
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
        self.election_renew_with_options(
            name,
            candidate,
            fencing_token,
            ttl_ms,
            RequestControl::default(),
        )
    }
    pub fn election_renew_with_options(
        &self,
        name: &str,
        candidate: &str,
        fencing_token: u64,
        ttl_ms: Option<u64>,
        control: RequestControl,
    ) -> Result<Value, Error> {
        let mut body = json!({ "candidate": candidate, "fencing_token": fencing_token });
        if let Some(ttl_ms) = ttl_ms {
            body["ttl_ms"] = json!(ttl_ms);
        }
        self.request_with_control(
            "POST",
            &format!("/v1/elections/{}/renew", enc(name)),
            Some(body),
            control,
            false,
        )
    }
    pub fn election_resign(
        &self,
        name: &str,
        candidate: &str,
        fencing_token: u64,
    ) -> Result<Value, Error> {
        self.election_resign_with_options(name, candidate, fencing_token, RequestControl::default())
    }
    pub fn election_resign_with_options(
        &self,
        name: &str,
        candidate: &str,
        fencing_token: u64,
        control: RequestControl,
    ) -> Result<Value, Error> {
        self.request_with_control(
            "POST",
            &format!("/v1/elections/{}/resign", enc(name)),
            Some(json!({ "candidate": candidate, "fencing_token": fencing_token })),
            control,
            false,
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
/// The reserved key for a named secret; rejects an empty name.
fn secret_key(name: &str) -> Result<String, Error> {
    if name.is_empty() {
        return Err(Error::Transport(
            "secret name must be non-empty".to_string(),
        ));
    }
    Ok(format!("secret/{name}"))
}

/// Enforce write-only listing: drop every `value`, strip the `secret/` prefix
/// into a `name` field, so a `secret_list` response can never leak a value.
fn strip_secret_values(mut raw: Value) -> Value {
    if let Some(keys) = raw.get_mut("keys").and_then(Value::as_array_mut) {
        for item in keys.iter_mut() {
            if let Some(obj) = item.as_object_mut() {
                obj.remove("value");
                if let Some(Value::String(key)) = obj.get("key") {
                    if let Some(stripped) = key.strip_prefix("secret/") {
                        let name = Value::String(stripped.to_string());
                        obj.insert("name".to_string(), name);
                    }
                }
            }
        }
    }
    raw
}

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
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{self, Receiver};
    use std::sync::Arc;

    #[test]
    fn secret_key_namespaces_and_rejects_empty() {
        assert_eq!(secret_key("api-key").unwrap(), "secret/api-key");
        assert_eq!(secret_key("db/password").unwrap(), "secret/db/password");
        assert!(matches!(secret_key(""), Err(Error::Transport(_))));
    }

    #[test]
    fn strip_secret_values_never_leaks_a_value() {
        let raw = json!({
            "prefix": "secret/",
            "count": 1,
            "keys": [
                { "key": "secret/api-key", "value": "LEAK", "mod_revision": 2 }
            ]
        });
        let stripped = strip_secret_values(raw);
        let item = &stripped["keys"][0];
        assert_eq!(item.get("value"), None, "list must never expose a value");
        assert_eq!(item["name"], "api-key");
        assert_eq!(item["mod_revision"], 2);
        assert!(!stripped.to_string().contains("LEAK"));
    }

    #[derive(Debug)]
    struct RecordedRequest {
        method: String,
        path: String,
        body: Value,
        idempotency_key: Option<String>,
        authorization: Option<String>,
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
                let authorization = header_value(&headers, "authorization");
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
                    authorization,
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

    fn json_recording_server(responses: Vec<Value>) -> (String, Receiver<RecordedRequest>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();

        thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().unwrap();
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
                            content_len = content_length(&String::from_utf8_lossy(&buf[..pos]));
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
                tx.send(RecordedRequest {
                    method,
                    path,
                    body,
                    idempotency_key: header_value(&headers, "idempotency-key"),
                    authorization: header_value(&headers, "authorization"),
                })
                .unwrap();

                let response = serde_json::to_vec(&response).unwrap();
                let headers = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    response.len()
                );
                stream.write_all(headers.as_bytes()).unwrap();
                stream.write_all(&response).unwrap();
            }
        });

        (base, rx)
    }

    /// A server that always answers `status`, counting the requests it received.
    /// Used to observe whether a failed request is retried.
    fn erroring_server(status: u16) -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = hits.clone();

        thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                // Drain the full request (headers + body) before responding so the
                // client's write never races the connection close.
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
                            content_len = content_length(&String::from_utf8_lossy(&buf[..pos]));
                        }
                    }
                    if let Some(pos) = header_end {
                        if buf.len() >= pos + 4 + content_len {
                            break;
                        }
                    }
                }
                counter.fetch_add(1, Ordering::SeqCst);
                let resp = format!(
                    "HTTP/1.1 {status} STATUS\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{{\"ok\":true}}"
                );
                let _ = stream.write_all(resp.as_bytes());
            }
        });

        (base, hits)
    }

    fn redirecting_server(location: String) -> (String, Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();

        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = Vec::new();
            let mut tmp = [0_u8; 1024];
            while find_header_end(&buf).is_none() {
                let n = stream.read(&mut tmp).unwrap();
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&tmp[..n]);
            }
            let header_end = find_header_end(&buf).unwrap();
            tx.send(String::from_utf8_lossy(&buf[..header_end]).into_owned())
                .unwrap();
            let response = format!(
                "HTTP/1.1 302 Found\r\nlocation: {location}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            );
            stream.write_all(response.as_bytes()).unwrap();
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

    #[test]
    fn trusted_hop_secret_is_redacted_and_never_crosses_a_redirect() {
        let attacker = TcpListener::bind("127.0.0.1:0").unwrap();
        attacker.set_nonblocking(true).unwrap();
        let location = format!("http://{}/steal", attacker.local_addr().unwrap());
        let (base, origin_headers) = redirecting_server(location);
        let secret = "internal-secret-must-not-leak";
        let org = "org-sensitive";
        let client = FiduciaClient::internal(&base, secret, org);

        let err = client.health().unwrap_err();
        assert!(matches!(err, Error::Http { status: 302, .. }));
        let headers = origin_headers.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(
            header_value(&headers, "x-fiducia-internal-auth").as_deref(),
            Some(secret)
        );
        assert_eq!(
            header_value(&headers, "x-fiducia-org-id").as_deref(),
            Some(org)
        );
        assert!(
            matches!(attacker.accept(), Err(err) if err.kind() == std::io::ErrorKind::WouldBlock),
            "redirect target received a trusted-hop request"
        );

        let debug = format!("{client:?}");
        assert!(!debug.contains(secret));
        assert!(!debug.contains(org));
        assert!(debug.contains("<redacted>"));
        assert!(!format!("{:?}", sensitive_header_value(secret).unwrap()).contains(secret));
    }

    #[test]
    fn bearer_credential_is_redacted_and_never_crosses_a_redirect() {
        let attacker = TcpListener::bind("127.0.0.1:0").unwrap();
        attacker.set_nonblocking(true).unwrap();
        let location = format!("http://{}/steal", attacker.local_addr().unwrap());
        let (base, origin_headers) = redirecting_server(location);
        let api_key = "fiducia-api-key-must-not-leak";
        let client = FiduciaClient::bearer(&base, api_key);

        let err = client.health().unwrap_err();
        assert!(matches!(err, Error::Http { status: 302, .. }));
        let headers = origin_headers.recv_timeout(Duration::from_secs(2)).unwrap();
        let expected_header = format!("Bearer {api_key}");
        assert_eq!(
            header_value(&headers, "authorization").as_deref(),
            Some(expected_header.as_str())
        );
        assert!(
            matches!(attacker.accept(), Err(err) if err.kind() == std::io::ErrorKind::WouldBlock),
            "redirect target received a bearer-authenticated request"
        );

        let debug = format!("{client:?}");
        assert!(!debug.contains(api_key));
        assert!(debug.contains("<redacted>"));
    }

    #[test]
    fn cleartext_internal_host_policy() {
        // Local / in-cluster shapes the secret may travel to over http.
        for ok in [
            "localhost",
            "dev.localhost",
            "127.0.0.1",
            "10.2.3.4",
            "172.16.0.9",
            "192.168.1.20",
            "169.254.1.1",
            "::1",
            "fd00::7",
            "fe80::1",
            "fiducia-node", // single-label service name (compose / same-ns k8s)
            "fiducia-node.fiducia.svc",
            "fiducia-node.fiducia.svc.cluster.local",
            "node-0.corp.internal",
        ] {
            assert!(cleartext_internal_host_allowed(ok), "should allow {ok}");
        }
        // Public shapes it must not.
        for bad in [
            "api.fiducia.cloud",
            "node.example.com",
            "8.8.8.8",
            "172.32.0.1", // just past the RFC1918 172.16/12 range
            "2001:db8::1",
            "node.local", // mDNS is not a cluster-identity guarantee
        ] {
            assert!(!cleartext_internal_host_allowed(bad), "should refuse {bad}");
        }

        // Host extraction: only http:// yields a host; https and userinfo/ports
        // parse correctly; IPv6 brackets are stripped.
        assert_eq!(cleartext_http_host("http://host:8090/v1"), Some("host"));
        assert_eq!(
            cleartext_http_host("HTTP://Host.Example.com"),
            Some("Host.Example.com")
        );
        assert_eq!(cleartext_http_host("http://user@host:1"), Some("host"));
        assert_eq!(cleartext_http_host("http://[::1]:8090"), Some("::1"));
        assert_eq!(cleartext_http_host("https://host:8090"), None);
    }

    #[test]
    fn bearer_client_authenticates_supported_observe_calls() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::bearer(&base, "api-key-sensitive");

        client.observe("locks").unwrap();
        let got = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(got.method, "GET");
        assert_eq!(got.path, "/v1/observe/locks");
        assert_eq!(got.body, Value::Null);
        assert_eq!(
            got.authorization.as_deref(),
            Some("Bearer api-key-sensitive")
        );
        assert!(matches!(
            client.observe("unknown"),
            Err(Error::Transport(_))
        ));
    }

    #[test]
    fn cleartext_secret_to_public_host_is_refused_before_send() {
        // A public-DNS http base with the internal secret: refused with a typed
        // error before any bytes (or DNS lookup) leave the process.
        let client = FiduciaClient::internal("http://api.example.com:8090", "s3cret", "org");
        let err = client.health().unwrap_err();
        match err {
            Error::Transport(msg) => {
                assert!(msg.contains("cleartext"), "unexpected refusal text: {msg}");
                assert!(!msg.contains("s3cret"), "refusal must not echo the secret");
            }
            other => panic!("expected a transport refusal, got {other:?}"),
        }

        // The refusal is scoped precisely: https, loopback http, in-cluster
        // names, no-secret clients, and the explicit opt-in all pass the guard.
        assert!(FiduciaClient::internal("https://api.example.com", "s", "o")
            .cleartext_refusal()
            .is_none());
        assert!(FiduciaClient::internal("http://127.0.0.1:8090", "s", "o")
            .cleartext_refusal()
            .is_none());
        assert!(
            FiduciaClient::internal("http://fiducia-node:8090", "s", "o")
                .cleartext_refusal()
                .is_none()
        );
        assert!(FiduciaClient::new("http://api.example.com")
            .cleartext_refusal()
            .is_none());
        assert!(FiduciaClient::internal("http://api.example.com", "s", "o")
            .allow_cleartext_internal()
            .cleartext_refusal()
            .is_none());
        assert!(matches!(
            FiduciaClient::bearer("http://api.example.com", "api-key").health(),
            Err(Error::Transport(_))
        ));
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
    fn sync_methods_use_canonical_interface_types_and_durable_keys() {
        let (base, rx) = json_recording_server(vec![
            json!({ "id": "operation-7", "committed_version": 4 }),
            json!({
                "changes": [{
                    "sequence": 41,
                    "table": "infra_operations",
                    "op": "upsert",
                    "id": "operation-7",
                    "version": 4,
                    "row": { "state": "running" }
                }],
                "next_cursor": 41,
                "has_more": false
            }),
        ]);
        let client = FiduciaClient::new(&base);
        let write = types::SyncQueuedWrite {
            id: "operation-7".to_string(),
            table: "infra_operations".to_string(),
            op: types::SyncQueuedWriteOp::Upsert,
            payload: Some(json!({ "state": "queued" })),
            base_version: 3,
            key: "write-operation-7-v4".to_string(),
        };

        let acknowledgement = client
            .sync_write(&write, Some("/api/admin/sync"), None)
            .unwrap();
        assert_eq!(acknowledgement.id, write.id);
        assert_eq!(acknowledgement.committed_version, 4);
        let request = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/api/admin/sync/infra_operations");
        assert_eq!(
            request.idempotency_key.as_deref(),
            Some("write-operation-7-v4")
        );
        assert_eq!(request.body["key"], write.key);

        let page = client
            .sync_pull("infra_operations", 40, 2, Some("/api/admin/sync"), None)
            .unwrap();
        assert_eq!(page.next_cursor, 41);
        assert_eq!(page.changes.len(), 1);
        assert_eq!(page.changes[0].at_ms, 0);
        assert_eq!(page.changes[0].sync_sequence, Some(41));
        let request = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(request.method, "GET");
        assert_eq!(
            request.path,
            "/api/admin/sync/infra_operations?cursor=40&limit=2"
        );
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

        client
            .lock_renew(&["orders/42"], "worker-a", 11, 30_000)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/renew",
            json!({ "keys": ["orders/42"], "holder": "worker-a", "fencing_token": 11, "ttl_ms": 30_000 }),
        );
        client.lock_cancel(&["orders/42"], "worker-a").unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/cancel",
            json!({ "keys": ["orders/42"], "holder": "worker-a" }),
        );
        client
            .lock_acquire_many_with_request_id(
                &["orders/42"],
                Some("worker-a"),
                Some(30_000),
                true,
                Some("fdc-attempt-lock-1"),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/acquire",
            json!({
                "keys": ["orders/42"], "holder": "worker-a", "ttl_ms": 30_000,
                "wait": true, "request_id": "fdc-attempt-lock-1"
            }),
        );
        client
            .lock_cancel_with_request_id(&["orders/42"], "worker-a", Some("fdc-attempt-lock-1"))
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/locks/cancel",
            json!({
                "keys": ["orders/42"], "holder": "worker-a",
                "request_id": "fdc-attempt-lock-1"
            }),
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
            .try_semaphore("pools/db/primary", Some("worker-b"), None, 0)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/acquire",
            // max=0 is invalid and clamped to 1 (a mutex); higher values pass through.
            json!({ "key": "pools/db/primary", "holder": "worker-b", "ttl_ms": null, "wait": false, "limit": 1 }),
        );

        client
            .semaphore_renew("pools/db/primary", "worker-b", 12, 30_000)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/renew",
            json!({ "key": "pools/db/primary", "holder": "worker-b", "fencing_token": 12, "ttl_ms": 30_000 }),
        );
        client
            .semaphore_cancel("pools/db/primary", "worker-b")
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/cancel",
            json!({ "key": "pools/db/primary", "holder": "worker-b" }),
        );
        client
            .semaphore_acquire_with_request_id(
                "pools/db/primary",
                Some("worker-b"),
                Some(30_000),
                true,
                2,
                Some("fdc-attempt-semaphore-1"),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/acquire",
            json!({
                "key": "pools/db/primary", "holder": "worker-b", "ttl_ms": 30_000,
                "wait": true, "limit": 2, "request_id": "fdc-attempt-semaphore-1"
            }),
        );
        client
            .semaphore_cancel_with_request_id(
                "pools/db/primary",
                "worker-b",
                Some("fdc-attempt-semaphore-1"),
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/semaphores/cancel",
            json!({
                "key": "pools/db/primary", "holder": "worker-b",
                "request_id": "fdc-attempt-semaphore-1"
            }),
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
    fn omitted_lock_holder_becomes_a_unique_uuid_capability() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);
        client.try_lock("orders/42", None, None, None).unwrap();
        client
            .try_lock("orders/43", Some("   "), None, None)
            .unwrap();
        let first = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let second = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let first_holder = first.body["holder"].as_str().unwrap();
        let second_holder = second.body["holder"].as_str().unwrap();
        assert!(first_holder.starts_with("fdc-"));
        assert_eq!(first_holder.len(), 36);
        assert_ne!(first_holder, second_holder);
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

        client
            .counter_add("rollout/v2/failures", -1, Some(7))
            .unwrap();
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
            .task_complete(
                "repo/acme/api/issue/482",
                "agent-a",
                42,
                json!({ "pr": 991 }),
            )
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

        client
            .effect_commit("invoice-882/payment", json!({ "confirmation": "pay_123" }))
            .unwrap();
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

        client
            .handoff_accept("ticket-482/handoff", "legal-agent")
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/handoffs/accept",
            json!({ "name": "ticket-482/handoff", "to": "legal-agent" }),
        );
    }

    #[test]
    fn decision_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .decision_propose(
                "deploy/safe",
                "Is this deploy safe?",
                &["approve", "reject"],
                json!({ "kind": "plurality", "min_votes": 3 }),
                None,
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/decisions/propose",
            json!({
                "name": "deploy/safe",
                "question": "Is this deploy safe?",
                "options": ["approve", "reject"],
                "policy": { "kind": "plurality", "min_votes": 3 },
                "deadline_ms": null
            }),
        );

        client
            .decision_vote(
                "deploy/safe",
                DecisionVote {
                    voter: "agent-a",
                    option: Some("approve"),
                    confidence: 0.9,
                    weight: 5,
                    veto: false,
                    evidence: &["log:123"],
                },
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/decisions/vote",
            json!({
                "name": "deploy/safe",
                "voter": "agent-a",
                "option": "approve",
                "confidence": 0.9,
                "weight": 5,
                "veto": false,
                "evidence": ["log:123"]
            }),
        );
    }

    #[test]
    fn budget_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .budget_reserve(
                "org/acme/wf/42",
                "res-1",
                "research-agent",
                BudgetAmount {
                    usd_micros: Some(500_000),
                    tokens: Some(100_000),
                    tool_calls: None,
                },
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/budgets/reserve",
            json!({
                "name": "org/acme/wf/42",
                "reservation_id": "res-1",
                "holder": "research-agent",
                "amount": { "usd_micros": 500_000, "tokens": 100_000 }
            }),
        );

        client
            .budget_commit(
                "org/acme/wf/42",
                "res-1",
                BudgetAmount {
                    usd_micros: Some(200_000),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/budgets/commit",
            json!({ "name": "org/acme/wf/42", "reservation_id": "res-1", "actual": { "usd_micros": 200_000 } }),
        );
    }

    #[test]
    fn claim_routes_match_node_contract() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);

        client
            .claim_assert(
                "customer/219/refund_eligible",
                "customer:219",
                "eligible_for_refund",
                json!(true),
                0.91,
                "billing-agent",
                &["ticket:88"],
                None,
            )
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/claims/assert",
            json!({
                "name": "customer/219/refund_eligible",
                "subject": "customer:219",
                "predicate": "eligible_for_refund",
                "value": true,
                "confidence": 0.91,
                "author": "billing-agent",
                "evidence": ["ticket:88"],
                "valid_until_ms": null
            }),
        );

        client
            .claim_resolve("customer/219/refund_eligible", true)
            .unwrap();
        assert_next(
            &rx,
            "POST",
            "/v1/claims/resolve",
            json!({ "name": "customer/219/refund_eligible", "accepted": true }),
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

    #[test]
    fn lock_and_election_mutations_accept_idempotency_controls() {
        let (base, rx) = recording_server();
        let client = FiduciaClient::new(&base);
        let control = |key: &str| RequestControl {
            idempotency_key: Some(key.to_string()),
            ..RequestControl::default()
        };

        client
            .lock_release_with_options("orders/42", "worker-a", 7, control("release-7"))
            .unwrap();
        client
            .election_campaign_with_options(
                "billing/tenant-a",
                "worker-a",
                30_000,
                None,
                control("campaign-7"),
            )
            .unwrap();
        client
            .election_renew_with_options(
                "billing/tenant-a",
                "worker-a",
                7,
                Some(30_000),
                control("renew-7"),
            )
            .unwrap();
        client
            .election_resign_with_options("billing/tenant-a", "worker-a", 7, control("resign-7"))
            .unwrap();

        for (path, key) in [
            ("/v1/locks/release", "release-7"),
            ("/v1/elections/billing%2Ftenant-a/campaign", "campaign-7"),
            ("/v1/elections/billing%2Ftenant-a/renew", "renew-7"),
            ("/v1/elections/billing%2Ftenant-a/resign", "resign-7"),
        ] {
            let got = rx.recv_timeout(Duration::from_secs(2)).unwrap();
            assert_eq!(got.method, "POST");
            assert_eq!(got.path, path);
            assert_eq!(got.idempotency_key.as_deref(), Some(key));
        }
    }

    #[test]
    fn non_idempotent_mutation_is_only_retried_when_safe() {
        // A keyless mutation that fails with 500 must NOT be retried: the server
        // may already have applied it, and a re-send would double-apply.
        let (base, hits) = erroring_server(500);
        let mut client = FiduciaClient::new(&base);
        client.retry_max = 1;
        assert!(client.counter_add("counters/add", 1, None).is_err());
        assert_eq!(hits.load(Ordering::SeqCst), 1, "500 keyless must not retry");

        // The same keyless mutation IS retried on 503: the server provably did
        // not apply it, so re-sending is safe.
        let (base, hits) = erroring_server(503);
        let mut client = FiduciaClient::new(&base);
        client.retry_max = 1;
        assert!(client.counter_add("counters/add", 1, None).is_err());
        assert_eq!(hits.load(Ordering::SeqCst), 2, "503 keyless must retry");

        // With an idempotency key the server can dedup a re-send, so even 500 is
        // retried.
        let (base, hits) = erroring_server(500);
        let mut client = FiduciaClient::new(&base);
        client.retry_max = 1;
        let control = RequestControl {
            idempotency_key: Some("req-1".to_string()),
            ..RequestControl::default()
        };
        assert!(client
            .try_lock_with_options("orders/42", Some("worker-a"), None, None, control)
            .is_err());
        assert_eq!(hits.load(Ordering::SeqCst), 2, "500 keyed must retry");
    }
}
