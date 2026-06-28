# fiducia-clients

Official client libraries for [fiducia.cloud](https://fiducia.cloud) — the
Raft-replicated coordination service. **HTTP only** (no TCP). Every client is a
thin, dependency-light wrapper over one shared contract, so they all expose the
same operations with a language-idiomatic surface.

Unlike a lock-only client, these cover the **whole** API: locks, semaphores,
reader-writer locks, rate limiting, cron/scheduling, **config KV**, **leader
election**, and **service discovery**.

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
const lock = await c.lockAcquire("orders/checkout", {
  holder: "worker-a",
  ttlMs: 30000,
});
await c.lockRelease("orders/checkout", {
  holder: "worker-a",
  fencingToken: lock.result.fencing_token,
});

// multi-key union lock
const combo = await c.lockAcquireMany({
  keys: ["orders/checkout", "inventory/sku-42"],
  holder: "worker-a",
  ttlMs: 30000,
});
await c.lockReleaseMany(combo.result.lock_id);

// semaphore
const slot = await c.semaphoreAcquire("webhook-delivery", {
  holder: "worker-b",
  ttlMs: 30000,
  max: 12,
});
await c.semaphoreRelease("webhook-delivery", {
  holder: "worker-b",
  fencingToken: slot.result.fencing_token,
});

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
await c.kvPut("flags/new-ui", "on", { ttlMs: 60000 });
const v = await c.kvGet("flags/new-ui");

// leader election
await c.electionCampaign("cron", "node-a", 15000);

// service discovery
await c.serviceRegister("api", "i-1", "10.0.0.1:9000", 10000);
const live = await c.serviceInstances("api");
```

## Blocking vs. try locks (and semaphores)

Beyond the raw `lockAcquire`/`semaphoreAcquire` calls, every client ships the
two high-level shapes you usually want — modeled on the
[live-mutex](https://github.com/oresoftware/live-mutex) client:

- **`tryLock` (`wait:false`)** — returns immediately: you get the lock if it was
  free *right now*, otherwise a "not acquired" result (no waiting).
- **`lock` / `mustLock` (`wait:true`)** — **blocks** until the lock is acquired,
  the wait budget elapses (a timeout error), or the server errors. Retries are
  *client-side and fully tunable*: `ttl`, `maxWaitTime`, `retryInterval`,
  `maxRetries`.

The server never holds a request open: `wait:true` reserves a FIFO queue slot
and returns at once, then the client polls until it's been promoted to holder.
That's why retry cadence and budget live in the client, giving the caller full
control. Each acquisition returns a handle carrying the **fencing token**; call
`.unlock()` / `.release()` (or `release_lock`) to free it. Counting semaphores
get the same pair: `trySemaphore` / `acquireSemaphore`.

```ts
import { FiduciaLockClient } from "./clients/ts/locking";
const c = new FiduciaLockClient("https://api.fiducia.cloud");

// fail fast if it's held right now
const maybe = await c.tryLock("orders/checkout", { ttl: 30000 });
if (maybe) { try { /* critical section */ } finally { await maybe.unlock(); } }

// block (with retries) until acquired or the budget elapses
const lock = await c.lock("orders/checkout", { ttl: 30000, maxWaitTime: 10000, retryInterval: 250 });
try { /* critical section */ } finally { await lock.unlock(); }

// or scoped: acquire → run → always release
await c.withLock("orders/checkout", { ttl: 30000 }, async (lock) => { /* ... */ });
```

Method names per language (`tryLock` / `lock` / `mustLock`, plus the semaphore
pair) follow each language's casing — e.g. Rust `try_lock`/`lock`, Go
`TryLock`/`Lock`, Python `try_lock`/`lock`, Ruby `try_lock`/`lock`, Elixir
`try_lock/3`/`lock/3`, shell `fiducia_try_lock`/`fiducia_lock`. For TS/Python/Go
the helpers live in a `locking.*` companion alongside the generated client; for
the other languages they're built into the client.

## CLI

The Python client doubles as a dependency-free CLI for local smoke checks and
operator scripts:

```sh
FIDUCIA_BASE_URL=https://api.fiducia.cloud \
  python3 clients/python/fiducia.py lock acquire orders/checkout --holder worker-a --ttl-ms 30000

python3 clients/python/fiducia.py kv put flags/new-ui on --prev-revision 0
python3 clients/python/fiducia.py rate-limit check tenant-a checkout --algorithm token_bucket --limit 100 --window-ms 60000
python3 clients/python/fiducia.py cron upsert nightly --cron "0 0 * * *" --target-kind webhook --target-url https://example.com/hook
python3 clients/python/fiducia.py election campaign cron-main node-a --ttl-ms 15000
python3 clients/python/fiducia.py service register api i-1 10.0.0.1:9000 --ttl-ms 10000 --metadata az=a
```

## Status

Clients track the live node endpoints (locks, semaphores, multi-key locks, rate
limiting, cron/scheduling, KV, elections, discovery) and ship planned RW/watch
shapes ahead of the server (marked *planned* in `PROTOCOL.md`). All twelve now
include **blocking/try lock + semaphore acquisition with client-side retries**
(see above). Auth helpers and watch/SSE streaming are still to come.

## Related

- [`fiducia-load-balance.rs`](https://github.com/fiducia-cloud/fiducia-load-balance.rs) — the endpoint clients hit.
- [`fiducia-node.rs`](https://github.com/fiducia-cloud/fiducia-node.rs) — the coordination engine.
- [`fiducia-cli.rs`](https://github.com/fiducia-cloud/fiducia-cli.rs) — `fiduciactl`-style operator/customer CLI, starting with closest-region selection.
