# fiducia-clients

Official client libraries for [fiducia.cloud](https://fiducia.cloud) — the
Raft-replicated coordination service. **HTTP only** (no TCP). Every client is a
thin, dependency-light wrapper over one shared contract, so they all expose the
same operations with a language-idiomatic surface.

Unlike a lock-only client, these cover the **whole** API: locks, semaphores,
idempotency keys, reader-writer locks, rate limiting, cron/scheduling,
**config KV**, **leader election**, and **service discovery**.

## The contract

All clients implement [`PROTOCOL.md`](PROTOCOL.md) — the single source of truth
for endpoints and method names. Read it once and you know every client.

## Languages

First production tier: TypeScript, Go, Rust, and Python. The remaining languages
stay generated/thin so they can follow the same protocol without inventing a
second API shape.

Each lives under [`clients/`](clients/):

| Language | Dir | HTTP via |
|----------|-----|----------|
| TypeScript | [`clients/ts`](clients/ts) | `fetch` (stdlib) |
| Python | [`clients/python`](clients/python) | `urllib` (stdlib) |
| Go | [`clients/go`](clients/go) | `net/http` (stdlib) |
| Rust | [`clients/rust`](clients/rust) | `ureq` |
| Java | [`clients/java`](clients/java) | `java.net.http` (JDK 11+) |
| C# | [`clients/csharp`](clients/csharp) | `HttpClient` (.NET) |
| Ruby | [`clients/ruby`](clients/ruby) | `net/http` (stdlib) |
| PHP | [`clients/php`](clients/php) | `curl` (stdlib) |
| Shell | [`clients/shell`](clients/shell) | `curl` (+ `jq`) |
| PowerShell | [`clients/powershell`](clients/powershell) | `Invoke-RestMethod` |
| Dart | [`clients/dart`](clients/dart) | `dart:io` (stdlib) |
| Elixir | [`clients/elixir`](clients/elixir) | `:httpc` + `:json` (OTP 27+) |

## Shape (same everywhere)

```ts
const c = new FiduciaClient("https://api.fiducia.cloud");

// lock (mutex)
const maybeLock = await c.tryLock("orders/checkout", {
  holder: "worker-a",
  ttlMs: 30000,
});
if (maybeLock.committed) {
  await c.lockRelease("orders/checkout", {
    holder: "worker-a",
    fencingToken: maybeLock.result.output.fencing_token,
  });
}

const lock = await c.mustLock("orders/checkout", {
  holder: "worker-a",
  ttlMs: 30000,
  lockRequestTimeoutMs: 5000,
  maxRetries: 2,
});
await c.lockRelease("orders/checkout", {
  holder: "worker-a",
  fencingToken: lock.result.output.fencing_token,
});

// multi-key union lock
const combo = await c.lockMany({
  keys: ["orders/checkout", "inventory/sku-42"],
  holder: "worker-a",
  ttlMs: 30000,
});
await c.lockRelease("orders/checkout", {
  holder: "worker-a",
  fencingToken: combo.result.output.fencing_token,
});

// semaphore
const slot = await c.mustSemaphore("webhook-delivery", {
  holder: "worker-b",
  ttlMs: 30000,
  max: 12,
});
await c.semaphoreRelease("webhook-delivery", {
  holder: "worker-b",
  fencingToken: slot.result.output.fencing_token,
});

// idempotency
const claim = await c.idempotencyClaim("stripe-webhook/event_123", {
  owner: "worker-a",
  ttl: "24h",
  metadata: { source: "stripe" },
});
if (claim.result.output.status === "claimed") {
  await c.idempotencyComplete("stripe-webhook/event_123", {
    owner: "worker-a",
    fencingToken: claim.result.output.fencing_token,
    result: { status: "ok" },
  });
}

// rate limiting
await c.rateLimitCheck("tenant-a", "checkout", {
  algorithm: "token_bucket",
  limit: 100,
  windowMs: 60000,
});

// scheduling
await c.scheduleUpsert("nightly", {
  cron: "0 0 * * *",
  target: { kind: "webhook", url: "https://example.com/hook" },
});

// reader-writer
const r = await c.rwAcquireRead("report");      await c.rwEndRead("report", r.lock_id);

// config KV
await c.kvPut("flags/new-ui", "on", {
  ttlMs: 60000,
  idempotencyKey: "req_01J4Y3M8C9T9",
});
const v = await c.kvGet("flags/new-ui");

// leader election
const campaign = await c.electionCampaign("prod/invoice-reconciler/leader", "pod-a", 15000, {
  metadata: {
    service: "invoice-reconciler",
    region: "us-east-1",
    version: "2026.06.27",
    address: "10.2.4.18:8080",
  },
});

// service discovery
await c.serviceRegister("api", "i-1", "10.0.0.1:9000", 10000, {
  region: "us-east-1",
  version: "blue",
});
const live = await c.serviceInstances("api");
const sameRegion = await c.serviceInstances("api", { region: "us-east-1" });
const currentLeaders = await c.serviceInstances("api", { leader: "true" });
```

Across client languages, the try helpers force `wait:false` and the must/short
helpers force `wait:true` using language-idiomatic casing (`tryLock`,
`try_lock`, `TryLock`, etc.). Blocking lock and semaphore calls can be bounded
with each client's timeout, retry count, retry delay, and cancellation/context
controls where that runtime supports them. Mutating request controls also accept
customer retry idempotency keys: TypeScript `idempotencyKey`, Python
`idempotency_key`, Go `IdempotencyKey`, and Rust
`RequestControl.idempotency_key`.

For the hosted B2B flow, each service replica registers itself, campaigns for a
named role, renews before its lease expires, and stops leader-only work if renew
fails or returns `not_leader`. The winning replica gets a monotonic
`fencing_token`; pass that token to downstream databases, queues, or external
systems so stale leaders can be rejected after failover. Discovery metadata is
an exact-match string map, so leader-aware clients can filter on fields such as
`leader=true`, `region=us-east-1`, or `version=blue` while SSE watches track
election and service changes.

## CLI

The Python client doubles as a dependency-free CLI for local smoke checks and
operator scripts:

```sh
FIDUCIA_BASE_URL=https://api.fiducia.cloud \
  python3 clients/python/fiducia.py lock acquire orders/checkout --holder worker-a --ttl-ms 30000

python3 clients/python/fiducia.py kv put flags/new-ui on --prev-revision 0
python3 clients/python/fiducia.py idempotency claim stripe-webhook/event_123 --owner worker-a --ttl 24h
python3 clients/python/fiducia.py rate-limit check tenant-a checkout --algorithm token_bucket --limit 100 --window-ms 60000
python3 clients/python/fiducia.py cron upsert nightly --cron "0 0 * * *" --target-kind webhook --target-url https://example.com/hook
python3 clients/python/fiducia.py election campaign cron-main node-a --ttl-ms 15000 --metadata region=us-east-1 --metadata address=10.2.4.18:8080
python3 clients/python/fiducia.py service register api i-1 10.0.0.1:9000 --ttl-ms 10000 --metadata az=a
```

## Status

Clients track the live node endpoints for locks, semaphores, idempotency keys,
multi-key locks, rate limiting, cron/scheduling, KV, elections, and discovery.
TypeScript and Python include SSE watch helpers for KV key/prefix changes,
election leadership changes, and service discovery changes. Production-tier
clients also expose request timeout and bounded retry controls around blocking
acquisition calls.

## Related

- [`fiducia-load-balance.rs`](https://github.com/fiducia-cloud/fiducia-load-balance.rs) — the endpoint clients hit.
- [`fiducia-node.rs`](https://github.com/fiducia-cloud/fiducia-node.rs) — the coordination engine.
- [`fiducia-cli.rs`](https://github.com/fiducia-cloud/fiducia-cli.rs) — `fiduciactl`-style operator/customer CLI, starting with closest-region selection.
