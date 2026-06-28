//! High-level locking for the Fiducia Rust client.
//!
//! Mirrors the live-mutex ergonomics on top of the thin HTTP methods: the two
//! shapes callers actually want —
//!
//!   * [`FiduciaClient::try_lock`]  — `wait:false`. Returns `Ok(None)` at once if
//!     the lock is held; never blocks.
//!   * [`FiduciaClient::lock`] / [`FiduciaClient::must_lock`] — `wait:true`. Blocks
//!     (polling with a fixed interval) until acquired, the wait budget elapses
//!     ([`LockError::Timeout`]), or the server errors.
//!
//! Counting semaphores get the same pair ([`try_semaphore`](FiduciaClient::try_semaphore)
//! / [`acquire_semaphore`](FiduciaClient::acquire_semaphore)).
//!
//! The server never holds a request open: `wait:true` reserves a FIFO queue slot
//! and returns immediately, so the **client** owns the wait. That's why the retry
//! cadence and total budget live in [`LockOptions`].
//!
//! These call the canonical endpoints (`/v1/locks/acquire`, `?key=`,
//! `/v1/locks/release`) directly, so they're correct regardless of the older
//! path-style low-level helpers in [`crate`].

use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::{enc, Error, FiduciaClient};

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
    pub fencing_token: u64,
    pub lease_expires_ms: Option<u64>,
}

/// A held semaphore permit. Release with [`FiduciaClient::release_semaphore`].
#[derive(Debug, Clone)]
pub struct SemaphoreHandle {
    pub key: String,
    pub holder: String,
    pub fencing_token: u64,
    pub lease_expires_ms: Option<u64>,
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
                write!(f, "fiducia lock: timed out after {waited:?} waiting for {keys:?}")
            }
        }
    }
}

impl std::error::Error for LockError {}

static HOLDER_SEQ: AtomicU64 = AtomicU64::new(0);

/// A process-unique holder id (no external uuid dependency).
fn gen_holder() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let seq = HOLDER_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("fdc-{nanos:x}-{seq:x}")
}

fn out(resp: &Value) -> &Value {
    &resp["result"]["output"]
}

impl FiduciaClient {
    // --- locks ---------------------------------------------------------------

    /// Try to take the union of `keys` right now (`wait:false`). `Ok(None)` if held.
    pub fn try_lock(&self, keys: &[&str], opts: LockOptions) -> Result<Option<LockHandle>, LockError> {
        self.acquire_lock(keys, false, opts)
    }

    /// Block until the union of `keys` is acquired, the budget elapses
    /// ([`LockError::Timeout`]), or the server errors (`wait:true`).
    pub fn lock(&self, keys: &[&str], opts: LockOptions) -> Result<LockHandle, LockError> {
        match self.acquire_lock(keys, true, opts.clone())? {
            Some(h) => Ok(h),
            None => Err(LockError::Timeout {
                keys: keys.iter().map(|k| k.to_string()).collect(),
                waited: opts.max_wait,
            }),
        }
    }

    /// Alias of [`lock`](Self::lock) — blocks until acquired (or errors).
    pub fn must_lock(&self, keys: &[&str], opts: LockOptions) -> Result<LockHandle, LockError> {
        self.lock(keys, opts)
    }

    /// Release a held lock grant (every member key) by its fencing token.
    pub fn release_lock(&self, handle: &LockHandle) -> Result<Value, Error> {
        self.request(
            "POST",
            "/v1/locks/release",
            Some(json!({ "holder": handle.holder, "fencing_token": handle.fencing_token })),
        )
    }

    /// Acquire the union of `keys`, run `f`, then always release.
    pub fn with_lock<T>(
        &self,
        keys: &[&str],
        opts: LockOptions,
        f: impl FnOnce(&LockHandle) -> T,
    ) -> Result<T, LockError> {
        let handle = self.lock(keys, opts)?;
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
        let holder = opts.holder.clone().unwrap_or_else(gen_holder);
        let first = self.request(
            "POST",
            "/v1/locks/acquire",
            Some(json!({ "keys": keys, "holder": holder, "ttl_ms": opts.ttl_ms, "wait": wait })),
        )?;
        let o = out(&first);
        if o["acquired"].as_bool().unwrap_or(false) {
            return Ok(Some(lock_handle(keys, &holder, o)));
        }
        if !wait {
            return Ok(None); // try_lock: held now → fail fast
        }

        // Queued (FIFO). Poll a member key until we're promoted to holder.
        let deadline = Instant::now() + opts.max_wait;
        let max_retries = opts.max_retries.unwrap_or(u32::MAX);
        let probe = keys.first().copied().unwrap_or("");
        for _ in 0..max_retries {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            sleep(opts.retry_interval.min(remaining));
            let got = self.request("GET", &format!("/v1/locks?key={}", enc(probe)), None)?;
            let lock = &got["lock"];
            if lock["holder"].as_str() == Some(holder.as_str()) {
                if let Some(token) = lock["fencing_token"].as_u64() {
                    return Ok(Some(LockHandle {
                        keys: keys.iter().map(|k| k.to_string()).collect(),
                        holder,
                        fencing_token: token,
                        lease_expires_ms: lock["lease_expires_ms"].as_u64(),
                    }));
                }
            }
        }
        Ok(None)
    }

    // --- counting semaphores -------------------------------------------------

    /// Take a permit right now (`wait:false`). `Ok(None)` if at capacity.
    pub fn try_semaphore(
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

    fn acquire_semaphore_inner(
        &self,
        key: &str,
        limit: u32,
        wait: bool,
        opts: LockOptions,
    ) -> Result<Option<SemaphoreHandle>, LockError> {
        let holder = opts.holder.clone().unwrap_or_else(gen_holder);
        let first = self.request(
            "POST",
            "/v1/semaphores/acquire",
            Some(json!({
                "key": key, "limit": limit, "holder": holder,
                "ttl_ms": opts.ttl_ms, "wait": wait,
            })),
        )?;
        let o = out(&first);
        if o["acquired"].as_bool().unwrap_or(false) {
            return Ok(Some(SemaphoreHandle {
                key: key.to_string(),
                holder,
                fencing_token: o["fencing_token"].as_u64().unwrap_or(0),
                lease_expires_ms: o["lease_expires_ms"].as_u64(),
            }));
        }
        if !wait {
            return Ok(None);
        }

        let deadline = Instant::now() + opts.max_wait;
        let max_retries = opts.max_retries.unwrap_or(u32::MAX);
        for _ in 0..max_retries {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            sleep(opts.retry_interval.min(remaining));
            let got = self.request("GET", &format!("/v1/semaphores?key={}", enc(key)), None)?;
            if let Some(holders) = got["semaphore"]["holders"].as_array() {
                if let Some(slot) = holders
                    .iter()
                    .find(|h| h["holder"].as_str() == Some(holder.as_str()))
                {
                    if let Some(token) = slot["fencing_token"].as_u64() {
                        return Ok(Some(SemaphoreHandle {
                            key: key.to_string(),
                            holder,
                            fencing_token: token,
                            lease_expires_ms: slot["lease_expires_ms"].as_u64(),
                        }));
                    }
                }
            }
        }
        Ok(None)
    }
}

fn lock_handle(keys: &[&str], holder: &str, output: &Value) -> LockHandle {
    LockHandle {
        keys: keys.iter().map(|k| k.to_string()).collect(),
        holder: holder.to_string(),
        fencing_token: output["fencing_token"].as_u64().unwrap_or(0),
        lease_expires_ms: output["lease_expires_ms"].as_u64(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_holders_are_unique() {
        let a = gen_holder();
        let b = gen_holder();
        assert_ne!(a, b);
        assert!(a.starts_with("fdc-"));
    }

    #[test]
    fn default_options_are_sane() {
        let o = LockOptions::default();
        assert_eq!(o.ttl_ms, 60_000);
        assert_eq!(o.max_wait, Duration::from_secs(30));
        assert!(o.holder.is_none());
    }

    #[test]
    fn try_lock_against_dead_server_is_a_client_error_not_a_panic() {
        // Nothing listening → transport error surfaces as LockError::Client,
        // exercising the acquire path end-to-end without a live server.
        let c = FiduciaClient::new("http://127.0.0.1:1");
        let mut opts = LockOptions::default();
        opts.max_wait = Duration::from_millis(50);
        match c.try_lock(&["k"], opts) {
            Err(LockError::Client(_)) => {}
            other => panic!("expected client error, got {other:?}"),
        }
    }
}
