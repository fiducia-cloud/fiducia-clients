//! High-level locking for the Fiducia Rust client.
//!
//! Mirrors the live-mutex ergonomics on top of the thin HTTP methods: the two
//! shapes callers actually want —
//!
//!   * [`FiduciaClient::try_lock_handle`] — `wait:false`. Returns `Ok(None)` at
//!     once if the lock is held; never blocks.
//!   * [`FiduciaClient::acquire_lock_handle`] /
//!     [`FiduciaClient::must_lock_handle`] — `wait:true`. Blocks (polling with a
//!     fixed interval) until acquired, the wait budget elapses
//!     ([`LockError::Timeout`]), or the server errors.
//!
//! Counting semaphores get the same pair
//! ([`try_semaphore_handle`](FiduciaClient::try_semaphore_handle) /
//! [`acquire_semaphore`](FiduciaClient::acquire_semaphore)).
//!
//! The server never holds a request open: `wait:true` reserves a FIFO queue slot
//! and returns immediately, so the **client** owns the wait. That's why the retry
//! cadence and total budget live in [`LockOptions`].
//!
//! These call the canonical endpoints (`/v1/locks/acquire`, `?key=`,
//! `/v1/locks/release`) directly, so they're correct regardless of the older
//! path-style low-level helpers in [`crate`].

use std::collections::BTreeMap;
use std::thread::sleep;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::{Error, FiduciaClient};

/// Tuning for acquisition. `Default` gives a 60s lease, a 30s wait budget, and a
/// 250ms poll interval.
#[derive(Debug, Clone)]
pub struct LockOptions {
    /// Lease TTL in ms — the lock auto-expires if never released.
    pub ttl_ms: u64,
    /// Caller identity (also the release key). `None` → a generated id.
    pub holder: Option<String>,
    /// Total time to keep waiting before giving up (blocking `lock` only).
    pub max_wait: Duration,
    /// Cap on poll attempts while waiting. `None` → unlimited (bounded by `max_wait`).
    pub max_retries: Option<u32>,
    /// Delay between polls while waiting.
    pub retry_interval: Duration,
}

impl Default for LockOptions {
    fn default() -> Self {
        LockOptions {
            ttl_ms: 60_000,
            holder: None,
            max_wait: Duration::from_secs(30),
            max_retries: None,
            retry_interval: Duration::from_millis(250),
        }
    }
}

/// A held lock grant. Release with [`FiduciaClient::release_lock`].
#[derive(Debug, Clone)]
pub struct LockHandle {
    pub keys: Vec<String>,
    pub holder: String,
    /// The grant's fencing token. For a single-key grant this is the scalar the
    /// node returns. For a multi-key (union) grant with per-key tokens it mirrors
    /// one of `fencing_tokens` (release uses the per-key map, not this scalar).
    pub fencing_token: u64,
    /// Per-key fencing tokens for a multi-key (union) grant. Empty for a
    /// single-key grant (release then uses the scalar `fencing_token`).
    pub fencing_tokens: BTreeMap<String, u64>,
    pub lease_expires_ms: Option<u64>,
    pub ttl_ms: u64,
}

/// A held semaphore permit. Release with [`FiduciaClient::release_semaphore`].
#[derive(Debug, Clone)]
pub struct SemaphoreHandle {
    pub key: String,
    pub holder: String,
    pub fencing_token: u64,
    pub lease_expires_ms: Option<u64>,
    pub ttl_ms: u64,
}

/// Why an acquisition failed.
#[derive(Debug)]
pub enum LockError {
    /// A transport/HTTP error from the server.
    Client(Error),
    /// The wait budget elapsed before the lock was acquired.
    Timeout { keys: Vec<String>, waited: Duration },
}

impl From<Error> for LockError {
    fn from(e: Error) -> Self {
        LockError::Client(e)
    }
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockError::Client(e) => write!(f, "fiducia lock: client error: {e:?}"),
            LockError::Timeout { keys, waited } => {
                write!(
                    f,
                    "fiducia lock: timed out after {waited:?} waiting for {keys:?}"
                )
            }
        }
    }
}

impl std::error::Error for LockError {}

/// An unguessable holder identity. Holder names participate in queue identity
/// and cancellation authority, so a clock/pid/counter value is not sufficient.
pub(crate) fn gen_holder() -> String {
    format!("fdc-{}", uuid::Uuid::new_v4().simple())
}

/// A distinct capability for one logical acquire/retry/cancel attempt. It is
/// deliberately independent of holder so cancelling one attempt cannot
/// tombstone a later attempt by the same long-lived worker identity.
pub(crate) fn gen_request_id() -> String {
    format!("fdc-attempt-{}", uuid::Uuid::new_v4().simple())
}

pub(crate) fn validate_request_id(request_id: &str) -> Result<(), Error> {
    if request_id.trim().is_empty()
        || request_id.len() > 128
        || request_id.chars().any(|ch| ch.is_control())
    {
        return Err(Error::Transport(
            "fiducia: request_id must be 1-128 printable UTF-8 bytes".to_string(),
        ));
    }
    Ok(())
}

pub(crate) fn holder_or_generated(holder: Option<&str>) -> String {
    holder
        .map(str::trim)
        .filter(|holder| !holder.is_empty())
        .map(str::to_string)
        .unwrap_or_else(gen_holder)
}

fn out(resp: &Value) -> &Value {
    &resp["result"]["output"]
}

impl FiduciaClient {
    // --- locks ---------------------------------------------------------------

    /// Try to take the union of `keys` right now (`wait:false`). `Ok(None)` if held.
    pub fn try_lock_handle(
        &self,
        keys: &[&str],
        opts: LockOptions,
    ) -> Result<Option<LockHandle>, LockError> {
        self.acquire_lock(keys, false, opts)
    }

    /// Block until the union of `keys` is acquired, the budget elapses
    /// ([`LockError::Timeout`]), or the server errors (`wait:true`).
    pub fn acquire_lock_handle(
        &self,
        keys: &[&str],
        opts: LockOptions,
    ) -> Result<LockHandle, LockError> {
        match self.acquire_lock(keys, true, opts.clone())? {
            Some(h) => Ok(h),
            None => Err(LockError::Timeout {
                keys: keys.iter().map(|k| k.to_string()).collect(),
                waited: opts.max_wait,
            }),
        }
    }

    /// Alias of [`acquire_lock_handle`](Self::acquire_lock_handle) — blocks until acquired (or errors).
    pub fn must_lock_handle(
        &self,
        keys: &[&str],
        opts: LockOptions,
    ) -> Result<LockHandle, LockError> {
        self.acquire_lock_handle(keys, opts)
    }

    /// Release a held lock grant by its fencing token(s). A single-key grant is
    /// released by its scalar token; a multi-key (union) grant is released once
    /// per member key, each with that key's own token, so no key is left held
    /// with a mismatched (or zero) token until its lease TTL expires.
    pub fn release_lock(&self, handle: &LockHandle) -> Result<Value, Error> {
        let mut last = Value::Null;
        for payload in release_payloads(handle) {
            last = self.request("POST", "/v1/locks/release", Some(payload))?;
        }
        Ok(last)
    }

    /// Extend a held union-lock lease without changing its fencing token.
    pub fn renew_lock(&self, handle: &mut LockHandle, ttl_ms: Option<u64>) -> Result<Value, Error> {
        let ttl_ms = ttl_ms.unwrap_or(handle.ttl_ms);
        let response = self.request(
            "POST",
            "/v1/locks/renew",
            Some(json!({
                "keys": handle.keys,
                "holder": handle.holder,
                "fencing_token": handle.fencing_token,
                "ttl_ms": ttl_ms,
            })),
        )?;
        let output = out(&response);
        if !output["renewed"].as_bool().unwrap_or(false) {
            return Err(Error::Transport(
                "fiducia: lock renewal lost fenced authority".to_string(),
            ));
        }
        handle.lease_expires_ms = output["lease_expires_ms"].as_u64();
        handle.ttl_ms = ttl_ms;
        Ok(response)
    }

    /// Acquire the union of `keys`, run `f`, then always release.
    pub fn with_lock<T>(
        &self,
        keys: &[&str],
        opts: LockOptions,
        f: impl FnOnce(&LockHandle) -> T,
    ) -> Result<T, LockError> {
        let handle = self.acquire_lock_handle(keys, opts)?;
        let result = f(&handle);
        let _ = self.release_lock(&handle); // best-effort; lease TTL is the backstop
        Ok(result)
    }

    fn acquire_lock(
        &self,
        keys: &[&str],
        wait: bool,
        opts: LockOptions,
    ) -> Result<Option<LockHandle>, LockError> {
        let holder = holder_or_generated(opts.holder.as_deref());
        let request_id = gen_request_id();
        let first = self.request(
            "POST",
            "/v1/locks/acquire",
            Some(json!({
                "keys": keys,
                "holder": holder,
                "request_id": request_id,
                "ttl_ms": opts.ttl_ms,
                "wait": wait,
                "wait_timeout_ms": wait.then_some(opts.max_wait.as_millis() as u64),
            })),
        );
        let first = match first {
            Ok(response) => response,
            Err(error) => {
                if let Err(cancel_error) = self.cancel_lock_wait(keys, &holder, &request_id) {
                    return Err(LockError::Client(cancel_error));
                }
                return Err(LockError::Client(error));
            }
        };
        let o = out(&first);
        if o["acquired"].as_bool().unwrap_or(false) {
            let mut handle = lock_handle(keys, &holder, opts.ttl_ms, o)?;
            if o["renewed"].as_bool() == Some(false) {
                if let Err(error) = self.renew_lock(&mut handle, Some(opts.ttl_ms)) {
                    if let Err(cancel_error) = self.cancel_lock_wait(keys, &holder, &request_id) {
                        return Err(LockError::Client(cancel_error));
                    }
                    return Err(LockError::Client(error));
                }
            }
            return Ok(Some(handle));
        }
        if !wait {
            return Ok(None); // try_lock_handle: held now -> fail fast
        }

        // Re-submit the exact queued identity. This replicated command performs
        // expiry/promotion and reports a raced grant atomically; a GET alone
        // cannot advance the state machine.
        let deadline = Instant::now() + opts.max_wait;
        let max_retries = opts.max_retries.unwrap_or(u32::MAX);
        let wait_result = (|| -> Result<Option<LockHandle>, LockError> {
            for attempt in 0..max_retries {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                let backoff = opts.retry_interval.saturating_mul(1_u32 << attempt.min(3));
                sleep(backoff.min(Duration::from_secs(2)).min(remaining));
                let retried = self.request(
                    "POST",
                    "/v1/locks/acquire",
                    Some(json!({
                        "keys": keys,
                        "holder": holder,
                        "request_id": request_id,
                        "ttl_ms": opts.ttl_ms,
                        "wait": true,
                        "wait_timeout_ms": opts.max_wait.as_millis() as u64,
                    })),
                )?;
                let output = out(&retried);
                if output["acquired"].as_bool().unwrap_or(false) {
                    let token = output["fencing_token"].as_u64().ok_or_else(|| {
                        LockError::Client(Error::Transport(
                            "fiducia lock: retry-discovered grant carried no fencing token"
                                .to_string(),
                        ))
                    })?;
                    let renewed = self.request(
                        "POST",
                        "/v1/locks/renew",
                        Some(json!({
                            "keys": keys,
                            "holder": holder,
                            "fencing_token": token,
                            "ttl_ms": opts.ttl_ms,
                        })),
                    )?;
                    let renewed_output = out(&renewed);
                    if !renewed_output["renewed"].as_bool().unwrap_or(false) {
                        return Err(LockError::Client(Error::Transport(
                            "fiducia: retry-discovered lock lost fenced authority during renewal"
                                .to_string(),
                        )));
                    }
                    return Ok(Some(lock_handle(
                        keys,
                        &holder,
                        opts.ttl_ms,
                        renewed_output,
                    )?));
                }
            }
            Ok(None)
        })();

        // Timeouts and transport failures must not leave zombie queue entries.
        // If promotion won the race, cancel returns the active token and we
        // immediately release the grant.
        if !matches!(wait_result, Ok(Some(_))) {
            if let Err(cancel_error) = self.cancel_lock_wait(keys, &holder, &request_id) {
                return Err(LockError::Client(cancel_error));
            }
        }
        wait_result
    }

    fn cancel_lock_wait(&self, keys: &[&str], holder: &str, request_id: &str) -> Result<(), Error> {
        let response = self.request(
            "POST",
            "/v1/locks/cancel",
            Some(json!({ "keys": keys, "holder": holder, "request_id": request_id })),
        )?;
        let output = out(&response);
        if output["acquired"].as_bool().unwrap_or(false) {
            let token = output["fencing_token"].as_u64().ok_or_else(|| {
                Error::Transport("fiducia: raced lock carried no fencing token".to_string())
            })?;
            let released = self.request(
                "POST",
                "/v1/locks/release",
                Some(json!({ "holder": holder, "fencing_token": token })),
            )?;
            if out(&released)["released"].as_bool() == Some(false) {
                return Err(Error::Transport(
                    "fiducia: raced lock could not be released safely".to_string(),
                ));
            }
            return Ok(());
        }
        if output["cancelled"].as_bool() == Some(true) {
            return Ok(());
        }
        Err(Error::Transport(format!(
            "fiducia: lock cancellation did not establish safety ({})",
            output["reason"].as_str().unwrap_or("invalid_response")
        )))
    }

    // --- counting semaphores -------------------------------------------------

    /// Take a permit right now (`wait:false`). `Ok(None)` if at capacity.
    pub fn try_semaphore_handle(
        &self,
        key: &str,
        limit: u32,
        opts: LockOptions,
    ) -> Result<Option<SemaphoreHandle>, LockError> {
        self.acquire_semaphore_inner(key, limit, false, opts)
    }

    /// Block until a permit is free, the budget elapses, or the server errors.
    pub fn acquire_semaphore(
        &self,
        key: &str,
        limit: u32,
        opts: LockOptions,
    ) -> Result<SemaphoreHandle, LockError> {
        match self.acquire_semaphore_inner(key, limit, true, opts.clone())? {
            Some(h) => Ok(h),
            None => Err(LockError::Timeout {
                keys: vec![key.to_string()],
                waited: opts.max_wait,
            }),
        }
    }

    /// Release one held permit (admits the next FIFO waiter).
    pub fn release_semaphore(&self, handle: &SemaphoreHandle) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/semaphores/release",
            Some(json!({
                "key": handle.key,
                "holder": handle.holder,
                "fencing_token": handle.fencing_token,
            })),
        )
    }

    /// Extend a held semaphore permit without changing its fencing token.
    pub fn renew_semaphore(
        &self,
        handle: &mut SemaphoreHandle,
        ttl_ms: Option<u64>,
    ) -> Result<Value, Error> {
        let ttl_ms = ttl_ms.unwrap_or(handle.ttl_ms);
        let response = self.request(
            "POST",
            "/v1/semaphores/renew",
            Some(json!({
                "key": handle.key,
                "holder": handle.holder,
                "fencing_token": handle.fencing_token,
                "ttl_ms": ttl_ms,
            })),
        )?;
        let output = out(&response);
        if !output["renewed"].as_bool().unwrap_or(false) {
            return Err(Error::Transport(
                "fiducia: semaphore renewal lost fenced authority".to_string(),
            ));
        }
        handle.lease_expires_ms = output["lease_expires_ms"].as_u64();
        handle.ttl_ms = ttl_ms;
        Ok(response)
    }

    fn acquire_semaphore_inner(
        &self,
        key: &str,
        limit: u32,
        wait: bool,
        opts: LockOptions,
    ) -> Result<Option<SemaphoreHandle>, LockError> {
        let holder = holder_or_generated(opts.holder.as_deref());
        let request_id = gen_request_id();
        let first = self.request(
            "POST",
            "/v1/semaphores/acquire",
            Some(json!({
                "key": key, "limit": limit, "holder": holder,
                "request_id": request_id,
                "ttl_ms": opts.ttl_ms, "wait": wait,
                "wait_timeout_ms": wait.then_some(opts.max_wait.as_millis() as u64),
            })),
        );
        let first = match first {
            Ok(response) => response,
            Err(error) => {
                if let Err(cancel_error) = self.cancel_semaphore_wait(key, &holder, &request_id) {
                    return Err(LockError::Client(cancel_error));
                }
                return Err(LockError::Client(error));
            }
        };
        let o = out(&first);
        if o["acquired"].as_bool().unwrap_or(false) {
            let Some(token) = o["fencing_token"].as_u64() else {
                return Err(LockError::Client(Error::Transport(
                    "fiducia semaphore: acquired permit carried no fencing token".to_string(),
                )));
            };
            let mut handle = SemaphoreHandle {
                key: key.to_string(),
                holder,
                fencing_token: token,
                lease_expires_ms: o["lease_expires_ms"].as_u64(),
                ttl_ms: opts.ttl_ms,
            };
            if o["renewed"].as_bool() == Some(false) {
                if let Err(error) = self.renew_semaphore(&mut handle, Some(opts.ttl_ms)) {
                    if let Err(cancel_error) =
                        self.cancel_semaphore_wait(key, &handle.holder, &request_id)
                    {
                        return Err(LockError::Client(cancel_error));
                    }
                    return Err(LockError::Client(error));
                }
            }
            return Ok(Some(handle));
        }
        if o["reason"].as_str() == Some("limit_mismatch") {
            return Err(LockError::Client(Error::Transport(format!(
                "fiducia semaphore limit mismatch: requested {limit}, configured {}",
                o["limit"].as_u64().unwrap_or_default()
            ))));
        }
        if !wait {
            return Ok(None);
        }

        let deadline = Instant::now() + opts.max_wait;
        let max_retries = opts.max_retries.unwrap_or(u32::MAX);
        let wait_result = (|| -> Result<Option<SemaphoreHandle>, LockError> {
            for attempt in 0..max_retries {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                let backoff = opts.retry_interval.saturating_mul(1_u32 << attempt.min(3));
                sleep(backoff.min(Duration::from_secs(2)).min(remaining));
                let retried = self.request(
                    "POST",
                    "/v1/semaphores/acquire",
                    Some(json!({
                        "key": key,
                        "limit": limit,
                        "holder": holder,
                        "request_id": request_id,
                        "ttl_ms": opts.ttl_ms,
                        "wait": true,
                        "wait_timeout_ms": opts.max_wait.as_millis() as u64,
                    })),
                )?;
                let output = out(&retried);
                if output["acquired"].as_bool().unwrap_or(false) {
                    let Some(token) = output["fencing_token"].as_u64() else {
                        return Err(LockError::Client(Error::Transport(
                            "fiducia semaphore: acquired permit carried no fencing token"
                                .to_string(),
                        )));
                    };
                    let renewed = self.request(
                        "POST",
                        "/v1/semaphores/renew",
                        Some(json!({
                            "key": key,
                            "holder": holder,
                            "fencing_token": token,
                            "ttl_ms": opts.ttl_ms,
                        })),
                    )?;
                    let renewed_output = out(&renewed);
                    if !renewed_output["renewed"].as_bool().unwrap_or(false) {
                        return Err(LockError::Client(Error::Transport(
                            "fiducia: retry-discovered semaphore permit lost fenced authority during renewal"
                                .to_string(),
                        )));
                    }
                    return Ok(Some(SemaphoreHandle {
                        key: key.to_string(),
                        holder: holder.clone(),
                        fencing_token: token,
                        lease_expires_ms: renewed_output["lease_expires_ms"].as_u64(),
                        ttl_ms: opts.ttl_ms,
                    }));
                }
                if output["reason"].as_str() == Some("limit_mismatch") {
                    return Err(LockError::Client(Error::Transport(format!(
                        "fiducia semaphore limit mismatch: requested {limit}, configured {}",
                        output["limit"].as_u64().unwrap_or_default()
                    ))));
                }
            }
            Ok(None)
        })();
        if !matches!(wait_result, Ok(Some(_))) {
            if let Err(cancel_error) = self.cancel_semaphore_wait(key, &holder, &request_id) {
                return Err(LockError::Client(cancel_error));
            }
        }
        wait_result
    }

    fn cancel_semaphore_wait(
        &self,
        key: &str,
        holder: &str,
        request_id: &str,
    ) -> Result<(), Error> {
        let response = self.request(
            "POST",
            "/v1/semaphores/cancel",
            Some(json!({ "key": key, "holder": holder, "request_id": request_id })),
        )?;
        let output = out(&response);
        if output["acquired"].as_bool().unwrap_or(false) {
            let token = output["fencing_token"].as_u64().ok_or_else(|| {
                Error::Transport(
                    "fiducia: raced semaphore permit carried no fencing token".to_string(),
                )
            })?;
            let released = self.request(
                "POST",
                "/v1/semaphores/release",
                Some(json!({
                    "key": key,
                    "holder": holder,
                    "fencing_token": token,
                })),
            )?;
            if out(&released)["released"].as_bool() == Some(false) {
                return Err(Error::Transport(
                    "fiducia: raced semaphore permit could not be released safely".to_string(),
                ));
            }
            return Ok(());
        }
        if output["cancelled"].as_bool() == Some(true) {
            return Ok(());
        }
        Err(Error::Transport(format!(
            "fiducia: semaphore cancellation did not establish safety ({})",
            output["reason"].as_str().unwrap_or("invalid_response")
        )))
    }
}

/// Read per-key fencing tokens from a grant/lock object's `fencing_tokens` map.
/// Absent (single-key grant) yields an empty map.
fn extract_fencing_tokens(value: &Value) -> BTreeMap<String, u64> {
    let mut tokens = BTreeMap::new();
    if let Some(map) = value["fencing_tokens"].as_object() {
        for (key, token) in map {
            if let Some(t) = token.as_u64() {
                tokens.insert(key.clone(), t);
            }
        }
    }
    tokens
}

/// Build a [`LockHandle`] from a successful acquire's `output`. Reads the scalar
/// `fencing_token` (single-key) and/or the per-key `fencing_tokens` map
/// (multi-key union). Errors if a granted lock carries no resolvable token at
/// all — silently defaulting to `0` would make release fail and leak the lock
/// until its lease TTL expires.
fn lock_handle(
    keys: &[&str],
    holder: &str,
    ttl_ms: u64,
    output: &Value,
) -> Result<LockHandle, LockError> {
    let scalar = output["fencing_token"].as_u64();
    let fencing_tokens = extract_fencing_tokens(output);
    if scalar.is_none() && fencing_tokens.is_empty() {
        return Err(LockError::Client(Error::Transport(format!(
            "fiducia lock: acquired {keys:?} but response carried no fencing token"
        ))));
    }
    // Keep the scalar for single-key; for a multi-key grant with only per-key
    // tokens, expose the first as the representative scalar (release uses the map).
    let fencing_token = scalar
        .or_else(|| fencing_tokens.values().copied().next())
        .unwrap_or(0);
    Ok(LockHandle {
        keys: keys.iter().map(|k| k.to_string()).collect(),
        holder: holder.to_string(),
        fencing_token,
        fencing_tokens,
        lease_expires_ms: output["lease_expires_ms"].as_u64(),
        ttl_ms,
    })
}

/// The release request body/bodies for a handle: one `{ holder, fencing_token }`
/// for a single-key grant (unchanged), or one `{ key, holder, fencing_token }`
/// per member key for a multi-key grant so each key is released with its own
/// token.
fn release_payloads(handle: &LockHandle) -> Vec<Value> {
    if handle.fencing_tokens.is_empty() {
        vec![json!({ "holder": handle.holder, "fencing_token": handle.fencing_token })]
    } else {
        handle
            .fencing_tokens
            .iter()
            .map(|(key, token)| {
                json!({ "key": key, "holder": handle.holder, "fencing_token": token })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn generated_holders_are_unique() {
        let a = gen_holder();
        let b = gen_holder();
        assert_ne!(a, b);
        assert!(a.starts_with("fdc-"));
    }

    #[test]
    fn holder_id_is_a_uuid_capability() {
        let id = gen_holder();
        assert_eq!(id.len(), 36);
        assert!(id[4..].chars().all(|ch| ch.is_ascii_hexdigit()));
    }

    #[test]
    fn request_id_is_a_distinct_uuid_capability() {
        let a = gen_request_id();
        let b = gen_request_id();
        assert_ne!(a, b);
        assert!(a.starts_with("fdc-attempt-"));
        assert_eq!(a.len(), 44);
        assert!(validate_request_id(&a).is_ok());
        assert!(validate_request_id("   ").is_err());
        assert!(validate_request_id(&"x".repeat(129)).is_err());
        assert!(validate_request_id("bad\0id").is_err());
    }

    #[test]
    fn single_key_grant_uses_scalar_token() {
        let output = json!({ "acquired": true, "fencing_token": 5, "lease_expires_ms": 100 });
        let handle = lock_handle(&["orders/42"], "worker-a", 30_000, &output).unwrap();
        assert_eq!(handle.fencing_token, 5);
        assert!(handle.fencing_tokens.is_empty());
        // Single-key release body is unchanged: no `key`, scalar token.
        assert_eq!(
            release_payloads(&handle),
            vec![json!({ "holder": "worker-a", "fencing_token": 5 })]
        );
    }

    #[test]
    fn multi_key_grant_carries_per_key_tokens() {
        // A union grant whose scalar token is absent but per-key tokens are set.
        let output = json!({
            "acquired": true,
            "keys": ["a", "b"],
            "fencing_tokens": { "a": 7, "b": 9 },
        });
        let handle = lock_handle(&["a", "b"], "worker-a", 30_000, &output).unwrap();
        assert_eq!(handle.fencing_tokens.get("a"), Some(&7));
        assert_eq!(handle.fencing_tokens.get("b"), Some(&9));
        // The scalar is no longer 0 (which broke release); it mirrors a real token.
        assert_ne!(handle.fencing_token, 0);
        // Release sends each key with its own token (BTreeMap → sorted order).
        assert_eq!(
            release_payloads(&handle),
            vec![
                json!({ "key": "a", "holder": "worker-a", "fencing_token": 7 }),
                json!({ "key": "b", "holder": "worker-a", "fencing_token": 9 }),
            ]
        );
    }

    #[test]
    fn acquired_grant_with_no_token_is_a_hard_error() {
        // A successful acquire that resolves no token at all must error rather
        // than silently carry token 0 (which release can never match).
        let output = json!({ "acquired": true, "keys": ["a"] });
        assert!(lock_handle(&["a"], "worker-a", 30_000, &output).is_err());
    }

    #[test]
    fn default_options_are_sane() {
        let o = LockOptions::default();
        assert_eq!(o.ttl_ms, 60_000);
        assert_eq!(o.max_wait, Duration::from_secs(30));
        assert!(o.holder.is_none());
    }

    #[test]
    fn try_lock_handle_against_dead_server_is_a_client_error_not_a_panic() {
        // Nothing listening → transport error surfaces as LockError::Client,
        // exercising the acquire path end-to-end without a live server.
        let c = FiduciaClient::new("http://127.0.0.1:1");
        let opts = LockOptions {
            max_wait: Duration::from_millis(50),
            ..LockOptions::default()
        };
        match c.try_lock_handle(&["k"], opts) {
            Err(LockError::Client(_)) => {}
            other => panic!("expected client error, got {other:?}"),
        }
    }
}
