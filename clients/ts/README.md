# Fiducia (TypeScript)

Zero-runtime-dependency TypeScript client for fiducia.cloud built on the global
`fetch`. Implements the shared `PROTOCOL.md` contract.

- `fiducia.ts` — the production client, generated from
  `templates/typescript.ts.tmpl` plus `operations.json` (do not edit by hand).
- `locking.ts` — hand-written live-mutex-style lock/semaphore ergonomics on top
  of the generated client.
- `service-discovery.ts` — fail-closed reducer for the service-discovery SSE
  snapshot-plus-hint protocol.
- `sync-compatibility.ts` — compile-time proof that `syncSender()` and
  `syncPull()` satisfy `@fiducia/sync`'s transport callback types.
- `fiducia.test.ts` — offline unit tests (`node:test`).
- `package.json` / `publish.sh` — npm packaging manifest and publish entrypoint
  (see `clients/PUBLISHING.md`).
- `deno.json` — Deno-native exports and the import-map bridge to
  `@fiducia/interfaces/typescript`.

## Runtime support

The production source uses only standards-based TypeScript plus the Web Fetch
API. Zed therefore publishes the self-contained `clients/ts` directory through
four independent targets:

- Node.js 18+
- Deno
- Bun
- edge isolates such as Cloudflare Workers, Deno Deploy, and Vercel Edge

These are separate Zed runtime targets over one source root, not copied SDKs.
Keeping one implementation prevents operation and protocol drift. The required
client-matrix check rejects Node built-ins, CommonJS `require`, and `process`
globals in the production source before the edge target can be published.

There is no dedicated bearer-token constructor option yet. Authenticated callers
must inject a `fetch` wrapper that adds the required header.

## Reactive service discovery

Import the reducer from the packaged subpath and feed it parsed events from
`serviceWatch(service)`:

```ts
import {
  applyServiceDiscoveryEvent,
  createServiceDiscoveryReplica,
} from "@fiducia/client/service-discovery.ts";

let replica = createServiceDiscoveryReplica("invoice-reconciler");
for await (const event of client.serviceWatch("invoice-reconciler")) {
  const applied = applyServiceDiscoveryEvent(replica, event);
  replica = applied.state;
  if (replica.synchronized) {
    routeTo(replica.instances);
  }
}
```

The service registry in Fiducia's Raft state is authoritative. A bounded SSE
broadcast is an acceleration channel, not a durable event log. The reducer
therefore applies these rules:

- `snapshot` replaces the complete instance set and is the only event that marks
  the replica synchronized;
- `register`, `heartbeat`, and `deregister` advance the observed revision but do
  not independently rewrite the routing set;
- duplicate and stale revisions are ignored, while non-contiguous revisions are
  allowed because the shared shard also commits unrelated services and keys;
- lag recovery, reconnect, and TTL-reconciliation snapshots replace stale state;
- malformed, contradictory, or unavailable events preserve the last known set
  but mark it unsynchronized and require resynchronization.

Callers should route only while `synchronized` is true. The last known instances
remain available for diagnostics or an explicitly separate stale-read policy,
but are not represented as fresh authority after an unavailable or malformed
event.

The sync methods use `SyncQueuedWrite`, `SyncWriteAcknowledgement`, and
`SyncPullPage` from `@fiducia/interfaces/typescript`:

```ts
const send = client.syncSender({ pathPrefix: "/api/admin/sync" });
const pullFetch = (cursor: number, limit: number) =>
  client.syncPull("infra_operations", cursor, {
    pathPrefix: "/api/admin/sync",
    limit,
  });
```

Pass `send` to policy-driven `write()`/`flushQueue()` and `pullFetch` to
`startSync()`. The sender accepts `@fiducia/sync`'s replica-only
`write_policy`, strips it before HTTP IO, and sends only the canonical
`SyncQueuedWrite` envelope.
