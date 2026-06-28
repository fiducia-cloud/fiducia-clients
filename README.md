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

Clients are skeletons that track the live node endpoints (locks, semaphores,
multi-key locks, rate limiting, cron/scheduling, KV, elections, discovery) and
ship planned RW/watch shapes ahead of the server (marked *planned* in
`PROTOCOL.md`). They make HTTP calls and parse JSON; they do not yet add
retries, auth helpers, or watch/SSE streaming.

## Related

- [`fiducia-load-balance.rs`](https://github.com/fiducia-cloud/fiducia-load-balance.rs) — the endpoint clients hit.
- [`fiducia-node.rs`](https://github.com/fiducia-cloud/fiducia-node.rs) — the coordination engine.
- [`fiducia-cli.rs`](https://github.com/fiducia-cloud/fiducia-cli.rs) — `fiduciactl`-style operator/customer CLI, starting with closest-region selection.
