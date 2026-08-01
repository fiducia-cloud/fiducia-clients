//! Client conformance suite (async client).
//!
//! Each test is one item from the "integrating a client correctly" checklist in
//! `PROTOCOL.md`. They are the silent failure modes — code that looks correct,
//! returns no error, and only bites during an election or a slow tick. A client
//! that passes these has the behaviour `athleto-app-rs` had to learn the hard
//! way (fiducia-monorepo#7, #8, #9).
//!
//! The server is a raw `TcpListener` rather than a framework so the suite adds
//! no dependency and can be ported to any language's client.

#![cfg(feature = "async")]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use fiducia_client::{AsyncFiduciaClient, Error};
use serde_json::json;

/// A one-shot HTTP server that replies with `responses[n]` to the nth request
/// and records how many it saw. Returns `(base_url, request_counter)`.
fn serve(responses: Vec<(u16, String)>) -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let seen = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&seen);

    thread::spawn(move || {
        for (index, (status, body)) in responses.into_iter().enumerate() {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            counter.fetch_add(1, Ordering::SeqCst);
            // Read just enough to let the client finish writing; we never need
            // the request itself, only that it arrived.
            let mut buffer = [0u8; 2048];
            let _ = stream.read(&mut buffer);
            let reason = if *&status < 300 { "OK" } else { "Error" };
            let response = format!(
                "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\n\
                 content-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
            let _ = index;
        }
    });

    (format!("http://127.0.0.1:{port}"), seen)
}

fn ok(output: serde_json::Value) -> (u16, String) {
    (200, json!({ "committed": true, "result": { "output": output } }).to_string())
}

fn not_leader() -> (u16, String) {
    (
        503,
        json!({ "error": { "reason": "not_leader", "retryable": true } }).to_string(),
    )
}

/// Checklist: renew before expiry, and treat `renewed:false` as **lost
/// leadership** — stop the guarded work, do not merely log it.
#[tokio::test]
async fn lost_renewal_is_an_error_not_a_warning() {
    let (base, _) = serve(vec![ok(json!({ "renewed": false }))]);
    let client = AsyncFiduciaClient::new(&base);

    let result = client.renew("job", "worker-a", 7, 120_000).await;

    match result {
        Err(Error::Transport(message)) => {
            assert!(message.contains("lost fenced authority"), "{message}");
        }
        other => panic!("renewed:false must not look like success: {other:?}"),
    }
}

#[tokio::test]
async fn a_successful_renewal_returns_the_new_deadline() {
    let (base, _) = serve(vec![ok(
        json!({ "renewed": true, "lease_expires_ms": 1_700_000_000_000u64 }),
    )]);
    let client = AsyncFiduciaClient::new(&base);

    let expires = client.renew("job", "worker-a", 7, 120_000).await.expect("renew");
    assert_eq!(expires, Some(1_700_000_000_000));
}

/// Checklist: `committed: true` means the command reached the Raft log, not
/// that it succeeded. A release matching no grant is a committed no-op.
#[tokio::test]
async fn a_release_that_matched_no_grant_is_not_success() {
    let (base, _) = serve(vec![ok(json!({ "released": false }))]);
    let client = AsyncFiduciaClient::new(&base);

    let released = client.release("job", "worker-a", 7).await.expect("2xx");
    assert!(!released, "a committed no-op must not read as a successful release");
}

/// Checklist: retry `503 not_leader`. A routine election must not surface as an
/// outage — and it is safe without an idempotency key, because a marked
/// not_leader proves the command was rejected before application.
#[tokio::test]
async fn a_routine_election_is_retried_not_surfaced() {
    let (base, seen) = serve(vec![
        not_leader(),
        not_leader(),
        ok(json!({ "acquired": true, "fencing_token": 42 })),
    ]);
    let client = AsyncFiduciaClient::new(&base).with_retries(3, Duration::ZERO);

    let token = client.acquire("job", "worker-a", 120_000).await.expect("acquire");

    assert_eq!(token, Some(42));
    assert_eq!(seen.load(Ordering::SeqCst), 3, "both 503s should have been retried");
}

/// …but an *unmarked* 5xx is ambiguous: the mutation may have applied, so it
/// must not be retried without an idempotency key.
#[tokio::test]
async fn an_unmarked_server_error_is_not_retried() {
    let (base, seen) = serve(vec![
        (503, json!({ "error": "overloaded" }).to_string()),
        ok(json!({ "acquired": true, "fencing_token": 1 })),
    ]);
    let client = AsyncFiduciaClient::new(&base).with_retries(3, Duration::ZERO);

    let result = client.acquire("job", "worker-a", 120_000).await;

    assert!(matches!(result, Err(Error::Http { status: 503, .. })), "{result:?}");
    assert_eq!(seen.load(Ordering::SeqCst), 1, "an ambiguous 5xx must not be re-sent");
}

/// Checklist: contention is not failure. Someone else holding the lock is a
/// normal `Ok(None)`; not knowing who holds it is an `Err`.
#[tokio::test]
async fn contention_is_distinguishable_from_a_coordination_outage() {
    let (base, _) = serve(vec![ok(json!({ "acquired": false }))]);
    let contended = AsyncFiduciaClient::new(&base)
        .acquire("job", "worker-b", 120_000)
        .await;
    assert!(matches!(contended, Ok(None)), "{contended:?}");

    // Nothing listening: an outage, which the caller must handle differently.
    let outage = AsyncFiduciaClient::new("http://127.0.0.1:1")
        .acquire("job", "worker-b", 120_000)
        .await;
    assert!(matches!(outage, Err(Error::Transport(_))), "{outage:?}");
}

/// Checklist: never follow a server-named `Location` while holding a bearer
/// credential. The node does not emit redirects, but a compromised or
/// misconfigured hop could — the client must refuse rather than forward.
#[tokio::test]
async fn a_redirect_never_carries_the_credential_onward() {
    let (base, seen) = serve(vec![(
        307,
        json!({ "error": { "reason": "not_leader" } }).to_string(),
    )]);
    // Point Location at a host we would notice being contacted.
    let client = AsyncFiduciaClient::new(&base).with_retries(0, Duration::ZERO);

    let result = client.acquire("job", "worker-a", 120_000).await;

    assert!(matches!(result, Err(Error::Http { status: 307, .. })), "{result:?}");
    assert_eq!(seen.load(Ordering::SeqCst), 1, "the redirect must not be followed");
}

/// The credential guard fires before the socket does, so a misconfigured base
/// URL cannot leak a token even to a host that is listening.
#[tokio::test]
async fn a_credential_is_refused_before_any_connection_is_made() {
    let (base, seen) = serve(vec![ok(json!({ "allowed": true }))]);
    // A public hostname that resolves to our loopback listener: the guard must
    // key off the *configured* host, not where it happens to resolve.
    let public = base.replace("127.0.0.1", "api.fiducia.cloud");
    let client = AsyncFiduciaClient::bearer(&public, "fk_live_secret");

    let result = client.rate_limit_check("tenant", 1).await;

    match result {
        Err(Error::Transport(message)) => {
            assert!(message.contains("refusing to send"), "{message}");
            assert!(!message.contains("fk_live_secret"), "error leaked the key: {message}");
        }
        other => panic!("expected a pre-flight refusal, got {other:?}"),
    }
    assert_eq!(seen.load(Ordering::SeqCst), 0, "nothing should have been sent");
}
