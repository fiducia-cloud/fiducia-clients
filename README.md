# fiducia-clients

Official client libraries for [fiducia.cloud](https://fiducia.cloud) — the
Raft-replicated coordination service. **HTTP only** (no TCP). Every client is a
thin, dependency-light wrapper over one shared contract, so they all expose the
same operations with a language-idiomatic surface.

Unlike a lock-only client, these cover the **whole** API: locks, semaphores,
reader-writer locks, **config KV**, **leader election**, and **service
discovery**.

## The contract

All clients implement [`PROTOCOL.md`](PROTOCOL.md) — the single source of truth
for endpoints and method names. Read it once and you know every client.

## Languages

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

// lock (mutex) / semaphore
const lock = await c.lockAcquire("orders/checkout", { ttlMs: 30000 });
await c.lockRelease("orders/checkout", lock.lock_id);

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

## Status

Clients are skeletons that fully implement the live endpoints (KV, elections,
discovery) and ship the planned lock/RW endpoints ahead of the server (marked
*planned* in `PROTOCOL.md`). They make HTTP calls and parse JSON; they do not yet
add retries, auth, or watch/SSE streaming.

## Related

- [`fiducia-load-balance.rs`](https://github.com/fiducia-cloud/fiducia-load-balance.rs) — the endpoint clients hit.
- [`fiducia-node.rs`](https://github.com/fiducia-cloud/fiducia-node.rs) — the coordination engine.
